# CLAUDE.md

This file provides guidance to Claude Code when working in this repository.

## Overview

`k4s` builds a **diskless Kubernetes worker-node image**: a Linux kernel plus a
u-root initramfs that carries `containerd`, `runc`, `flannel`, `coredns`,
`etcdctl` and `kubelet`. There is no disk and no persistent state — the image is
the node, and everything is re-fetched into RAM on every boot. The eventual
target is diskless GPU servers for LLM inference.

Component pins are upstream (u-root, containerd, coredns, etcd, flannel,
kubernetes) built at exact commits. Two components are deliberately **not**
stock: a fork of `u-root/runc` (pure-Go namespaces *and* pure-Go seccomp) and
standalone builds of `runc` and `containerd-shim-runc-v2`. Read
`docs/roadmap.md` for the milestone plan and `docs/nsenter-and-runc.md` for the
runc story.

## Commands

```
make image     # build initramfs.cpio (runs ./DIT)
make kernel    # configure + build linux/ into build/kernel/bzImage
make run       # boot the image interactively under QEMU
make test      # boot headless and run scripts/guest-check.sh
make test-cluster  # M1: throwaway control plane + kubelet joins + pod runs
make clean     # remove build products (keeps the kernel checkout)
```

`make test` prints three verdict lines — `boot: ok`, `capabilities: ok`,
`container: ok` — and a `guest log:` path. `K4S_BOOT_TIMEOUT` (seconds, default
180) caps the guest run.

`make test-cluster` is the M1 join test and takes a few minutes: it builds the
control-plane binaries, generates throwaway PKI, boots the node twice (join,
then reboot-and-rejoin) and prints `node: ok`, `pod: ok`, `cluster: ok`.
`K4S_BOOTS` (default 2) sets the number of boots. It leaves the control plane
running, and regenerates etcd on every run.

Two prerequisites are **not** built by `make`:

- `linux/` is a separate kernel checkout (gitignored). Clone it before
  `make kernel`; `make kernel` uses it out-of-tree and never modifies it.
- `DIT` is the only thing that clones the component sources, and `go.work`
  lists those modules. **A bare `go` command in the repo fails until `DIT` has
  run** (`cannot load module ../coredns ... no such file`). Run `./DIT` first.

`/dev/kvm` decides the QEMU accelerator: KVM when writable, otherwise TCG
(the scripts say so, and TCG is slow — raise `K4S_BOOT_TIMEOUT`).

## Commits

**Sign off every commit** (`git commit -s`), with the `Signed-off-by:` trailer
matching the commit's author. Both upstream projects use the DCO, and the runc
fork is configured to require it (`web_commit_signoff_required: true`), so a
commit whose trailer is missing, or does not match the author, has to be
rewritten before it can land.

The trailer is taken from git config, so set that once (globally, or per
checkout) and `-s` will produce the right one. Confirm it before committing:

```
git config user.name && git config user.email
```

Git has **no config that adds a commit sign-off automatically** —
`format.signOff` only affects `format-patch`, not `git commit` — so pass `-s`
explicitly:

```
git commit -s -m "..."             # every commit
git commit --amend --no-edit -s    # add it to the commit just made
```

`-s` does not duplicate a trailer that is already there. To add sign-offs to
existing commits (our earlier history was retrofitted this way), rewrite only
our own range so upstream commits keep their SHAs, and let the filter read the
identity from git config rather than hardcoding it:

```
FILTER_BRANCH_SQUELCH_WARNING=1 git filter-branch -f \
  --msg-filter 'cat; printf "\nSigned-off-by: %s <%s>\n" "$(git config user.name)" "$(git config user.email)"' \
  -- origin/main..boot-qemu
git for-each-ref --format='%(refname)' refs/original | xargs -r -n1 git update-ref -d
```

## Repo layout

| Path | What |
| --- | --- |
| `DIT` | The build: pinned clone → tidy → standalone binaries → assemble |
| `Makefile` | `image`/`kernel`/`run`/`test`/`test-cluster` wrappers |
| `configs/k4s-tiny.config` | Kernel fragment appended over `tinyconfig` |
| `configs/node/` | Node config baked into the image: kubelet config, passwd/group/hosts, CNI conflist, smoke pod |
| `scripts/test-boot.sh` | QEMU boot + assert the guest checks |
| `scripts/guest-check.sh` | The capability check, piped into the guest's gosh |
| `scripts/test-cluster.sh` | M1 join test: throwaway control plane + two guest boots |
| `scripts/cluster-check.sh` | The guest half of that test, piped into gosh |
| `docs/roadmap.md` | Milestones M0–M3 and the decisions log |
| `docs/nsenter-and-runc.md` | Why runc normally needs cgo, and the fork |
| `go.work` | Committed and load-bearing; see below |

Gitignored build inputs (cloned by `DIT`) include `u-root/`, `containerd/`,
`coredns/`, `etcd/`, `flannel/`, `kubernetes/`, `runc/`, `linux/`, `build/` and
`initramfs.cpio`.

## DIT: the build

`DIT` (`set -euxo pipefail`) does four things.

**1. Clone pinned.** Every component is fetched over **HTTPS at an exact SHA** —
public repos, no SSH keys, reproducible graph — with one exception: `runc` is
built from the local checkout (see its row in the table). `clone_pinned` is idempotent: an
existing checkout is reused and re-fetched, so a rerun after a failure does not
die on "destination path already exists". To move a component, edit its
`*_REF` deliberately.

| Component | Ref |
| --- | --- |
| u-root | `25f9f897fcf2d5431b43daccc970215713547268` |
| containerd | `ed061a08de19ce99d223c60dfdbdf6054dd94290` |
| coredns | `145029c847d3f4c4d36918f8658631f40616745f` |
| etcd | `0bd70ca863d9f36c2776ef7f38cd35f12cca8d4a` |
| flannel | `0567dde14a09315931e55c3cb77d43f53e0e1db3` (`purego`) |
| kubernetes | `1c2e10a409eb1b03f2f28f401ce935312e20d9fb` (v1.35.8) |
| cni-plugins | `257ef09a103e8b8fe91a0fefe8680c01f84b520b` (loopback only) |
| runc | **not pinned** — the local `runc/` checkout is built as it stands, and `RUNC_REF` = `7215222c` only creates it when it is missing. A fork with a Go namespace path and a Go seccomp compiler |

**2. Tidy.** `go mod tidy` in each module, then a u-root build.

**3. Standalone binaries.** Most components are folded into a single
gobusybox `bb` (dispatched by `argv[0]`). Three cannot be, because they re-exec
`/proc/self/exe` (or `os.Executable()`), which under the multiplexer resolves to
the `bb` binary itself and loses the applet name:

- `containerd-shim-runc-v2` — re-execs to spawn its daemon
- `runc` — `exec.Command(exePath, "init")` for the container init
- `kubelet` — one large binary, not an applet

All three are built `CGO_ENABLED=0` and added with `-files`. `runc` comes from
the fork (see below); `kubelet` is built with `-mod=vendor` and an ldflags
version stamp (`k8s.io/component-base/version.gitVersion=v1.35.8`).

**4. Assemble.** `./u-root/u-root` with `u-root/cmds/core/*`,
`./containerd/cmd/containerd`, `./containerd/cmd/ctr`, `./flannel`,
`./coredns`, `./etcd/etcdctl`, plus the three `-files`.

### go.work is committed and load-bearing

`go.work` lists the cloned modules (`./containerd`, `./flannel`, `./runc`,
`./u-root`, `./coredns`, `./etcd/etcdctl`) and carries a
dependency pin the build relies on. **Do not regenerate it and do not add
`go work init`.** It is also why the repo has no broken-intermediate state that
tries to regenerate it: the workspace is authoritative.

Note `kubernetes/` has its **own** `go.work` (it is workspace-vendored, `##
workspace` in `vendor/modules.txt`). Build kubelet with that workspace present
and `-mod=vendor` on — **not** `GOWORK=off`, which fails with *"is replaced in
go.mod, but not marked as replaced in vendor/modules.txt"*. Go picks the
nearest `go.work`, so `(cd kubernetes && go build ...)` correctly uses k8s's.

## Kernel

`make kernel` configures `tinyconfig` + `configs/k4s-tiny.config`, then
`olddefconfig`, into `build/kernel/bzImage` (~2.8 MiB). Out-of-tree; the
`linux/` checkout is untouched.

Fragment entries that are load-bearing and non-obvious:

- `CONFIG_SHMEM`/`CONFIG_BLOCK`/`CONFIG_VIRTIO_MENU` — `tinyconfig` turns these
  off, which *hides* `TMPFS`, `VIRTIO` and `BLK_CGROUP` and silently drops them.
- `CONFIG_FILE_LOCKING` — without it containerd's bolt metadata plugin fails
  with `ENOSYS` and never creates its gRPC socket.
- `CONFIG_ACPI` — needed for `poweroff` in the test (QEMU `-no-reboot`).
- `CONFIG_CGROUP_SCHED`, `FAIR_GROUP_SCHED`, `CFS_BANDWIDTH`, `MEMCG`,
  `BLK_CGROUP`, `CGROUP_PIDS/DEVICE/FREEZER` — runc's cgroup setup;
  `CFS_BANDWIDTH` is what creates `cpu.max`, without which every pod container
  fails to start.

## Test harness

`scripts/test-boot.sh <kernel> <initramfs> [guest-script]` boots QEMU with
`-nographic` and pipes `scripts/guest-check.sh` into the guest's stdin. u-root's
`gosh` treats a non-tty stdin as a script, so **every line of `guest-check.sh`
must be a complete command** — no multi-line `if`/`for` blocks, and keep lines
short enough not to wrap on the serial console.

The QEMU cmdline is
`console=ttyS0,115200 panic=-1 cgroup_no_v1=all`. The last flag is not
optional: u-root's init mounts cgroup **v1** controllers, which binds `cpu`,
`pids` and `io` to v1 and leaves cgroup v2 with only `cpuset` and `memory`; runc
then fails with `openat2 .../cpu.weight: no such file or directory`.

The harness strips ANSI escapes and `gosh` `$ ` prompt lines before grepping,
because the guest echoes the script and a literal `fail` also appears in the
echoed source. Success is: an end marker, no `K4S_CHECK: ...: fail`, and the
container's own `K4S_CONTAINER_OK` output.

## Key decisions

- **Strict RAM-only.** No local medium and no on-node cache, ever. Every boot
  re-pulls every image and (later) every model weight. See the "strict RAM-only"
  section of `docs/roadmap.md` — it is the most expensive decision and drives
  the eviction policy, log shipping and GPU design.
- **HTTPS + exact SHAs**, never SSH or branch tips. The original `DIT` used
  `git@github.com:` and `--depth 1` on moving branches, so the dependency graph
  changed run to run. **`runc` is the exception**: it is the one component with a
  fork that this project develops, so `DIT` builds `runc/` as it stands and the
  pin only creates that checkout when there is not one. `DIT` prints the
  revision and branch it built. Everything else stays strictly pinned.
- **`go.work` committed**, not generated.
- **`runc` is a fork that builds cgo-free.** Upstream's `purego` branch only
  *deletes* the cgo namespace constructor, so its `CGO_ENABLED=0` runc cannot
  create namespaces (`can't get final child's PID from pipe: EOF`). The fork
  does both cgo-only jobs in Go: it creates the namespaces with Go's `clone(2)`
  support (`SysProcAttr.Cloneflags`) on the parent side, and it compiles seccomp
  profiles to BPF instead of calling libseccomp. Rootful containers work; user
  namespaces do not. Details in `docs/nsenter-and-runc.md`.
- **Standalone, not `bb`**, for anything that re-execs `/proc/self/exe`.

## Known limitations

- **Seccomp is enforced, and the rules are a search tree.** The fork compiles
  the profile in Go and installs it, so a `RuntimeDefault` pod really runs under
  `SECCOMP_MODE_FILTER` (the M1 test asserts it). A syscall costs O(log rules)
  comparisons; `TestSectionIsATree` measures that, because a chain would still be
  correct. Architectures x/sys/unix has no table for (x32, the mips n32 ABIs,
  31-bit s390) are refused rather than filtered. See `docs/nsenter-and-runc.md`.
- **Rootless / user namespaces**: not supported. `CLONE_NEWUSER` plus the other
  namespaces in one `clone` returns `EPERM`; nsexec's staged unshare is the
  missing piece. The node runs containers as root, so this does not block it.
- **`runc exec` / setns path, checkpoint-restore, mount-source remapping**:
  untested.
- **gobusybox applet flag scoping**: deferred. A per-applet `flag.CommandLine`
  swap at runtime breaks `coredns`, which registers flags from its `coremain`
  library. The correct isolation is separate processes — which is exactly what
  was done for runc — not a shared-process flag swap.
- kubelet is ~83 MiB stripped, which is a different size class from u-root's
  small-flash budget. Fine for netboot into server RAM.

## Status

Branch `boot-qemu`. M0 (bootable image + QEMU loop) and **M1 (kubelet joins a
throwaway cluster, runs a pod under a seccomp filter, and returns after a
reboot)** are done: `make test` passes the capability check and runs a
container, and `make test-cluster` joins, runs the smoke pod (asserting the
container reports `Seccomp: 2`), reboots, rejoins and runs it again. The image
uses a cgo-free runc fork that does both cgo-only jobs — namespaces and seccomp
— in Go. `docs/roadmap.md` has the M1 findings; M2 (ephemeral hygiene, kill
switch) and M3 (GPU) are next.
