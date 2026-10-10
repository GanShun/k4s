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
`docs/roadmap.md` for the milestone plan, `docs/nsenter-and-runc.md` for the
runc story, and `docs/cilium.md` for what choosing Cilium as the CNI would cost.

## Commands

```
make image     # build initramfs.cpio (runs ./DIT)
make linux     # clone the pinned kernel checkout into linux/ (needs no root)
make kernel    # configure + build linux/ into build/kernel/bzImage
make run       # boot the image interactively under QEMU
make test      # boot headless and run scripts/guest-check.sh
make test-cluster      # M1: control plane VM + kubelet joins + pods run (flannel)
make test-cluster-cni  # the same test with Cilium as the CNI
make test-all  # all three, one after another
make clean     # remove build products (keeps the kernel checkout)
```

`make kernel` adds both `configs/k4s-tiny.config` and `configs/k4s-cni.config`, so
one kernel can run either CNI. The second fragment — and only it, since it is what
sets `CONFIG_DEBUG_INFO_BTF` — needs **pahole** at configure and build time; if it
is not on `PATH`, point at it with `PAHOLE=/path/to/pahole make kernel`. On Debian
and Ubuntu the package is `pahole` — `dwarves` is only a metapackage that pulls it
in — and `apt-get download pahole` plus `dpkg-deb -x` gets it without root.

`make test` prints three verdict lines — `boot: ok`, `capabilities: ok`,
`container: ok` — and a `guest log:` path. `K4S_BOOT_TIMEOUT` (seconds, default
180) caps the guest run.

`make test-cluster` is the M1 join test: it builds the control-plane binaries,
generates throwaway PKI, boots a **control plane VM** (etcd, apiserver,
controller-manager, scheduler) and then the node twice (join, then
reboot-and-rejoin). It prints `node: ok`, `flannel: ok` or `cilium: ok`,
`pod: ok`, `seccomp: ok`, `netns pod: ok`, `log pod: ok`, `nginx: ok`,
`hook: ok`, `daemonset: ok`, `deployment: ok`, `workloads: ok`, `cluster: ok`.
`K4S_BOOTS` (default 2) sets the number of boots. Both VMs are killed on exit.

Every run is self-contained: it stops any control plane VM left by an earlier run
and boots its own, so no run can pass or fail on another run's objects. That is
also why it is quick — around 75 seconds for two boots with flannel, and around
210 with Cilium, whose agent has to install itself first.

`make test-cluster-cni` needs **helm** to render Cilium's chart (`HELM=...` to
point at one that is not on `PATH`) and **python3**, which `build_cilium` uses to
strip the chart's `postStart` hook. It also sets `K4S_NODE_MEM=6144`, which it
must: see the knobs table below.

The control plane is a VM rather than host processes because a node should join
something shaped like a real cluster: the controller-manager assigns pod CIDRs,
runs DaemonSets and Deployments and issues service account tokens. The host
reaches its apiserver through a QEMU port forward on `127.0.0.1:6443`; the node
reaches it at `10.0.2.2:6443`, which is the host from inside the node's
user-mode network. Both are on the same certificate.

One prerequisite is **not** built by `make`:

- `DIT` is the only thing that clones the component sources, and `go.work`
  lists those modules. **A bare `go` command in the repo fails until `DIT` has
  run** (`cannot load module ../coredns ... no such file`). Run `./DIT` first.

The kernel is not a prerequisite any more: `linux/` is a gitignored clone, and
`make linux` fetches it pinned (Linux 7.2, `8d3ae592…`) and verifies the tag
still points where it should. `make kernel` depends on it, so a fresh checkout
plus `make test-all` is the whole story. `make kernel` uses the checkout
out-of-tree and never modifies it.

Knobs the harnesses honour, all optional:

| Variable | Default | What it does |
| --- | --- | --- |
| `K4S_CNI` | `flannel` | `cilium` picks the Cilium leg |
| `K4S_NODE_MEM` | `1536` | node RAM in MiB; Cilium needs `6144` |
| `K4S_BOOTS` | `2` | boots per cluster run |
| `K4S_BOOT_TIMEOUT` | `180` | seconds `make test` allows the guest, boot **and** check |
| `K4S_SSH_PORT` | `2222` | host port forwarded to the **cluster** node's sshd |
| `K4S_BOOT_SSH_PORT` | `2223` | the same for `make test` (separate, so the two can run at once) |
| `K4S_XTRACE` | unset | trace the cluster harness to a file |
| `K4S_CILIUM_VERSION` | `1.20.2` | Cilium chart version |

`K4S_NODE_MEM` is not a tuning knob. The node is RAM-only, so containerd's
content store is a tmpfs and a tmpfs is half of RAM; Cilium's images need more
than the default leaves them, and the failure surfaces as an agent that never
becomes ready rather than as anything mentioning space.

`K4S_XTRACE=1` sends the harness's stderr and a `set -x` trace to
`/tmp/k4s-trace.log` (`K4S_XTRACE_FILE` to move it). A trace is the only reliable
way to find a failure that arrives as a bare exit status: the harness's `ERR`
trap does not fire for an explicit exit or a signal, and it has both.

`/dev/kvm` decides the QEMU accelerator: KVM when writable, otherwise TCG
(the scripts say so, and TCG is slow — raise `K4S_BOOT_TIMEOUT`; the capability
check gets that whole budget, not a fixed 8 seconds, because it runs a container).

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
| `Makefile` | `image`/`kernel`/`run`/`test`/`test-cluster`/`test-cluster-cni`/`test-all` wrappers |
| `configs/k4s-tiny.config` | Kernel fragment appended over `tinyconfig` |
| `configs/k4s-cni.config` | Second kernel fragment, also always applied: what Cilium needs |
| `configs/node/` | The node's own definition, baked into the image by `DIT`: kubelet config, `role`, passwd/group/hosts, CNI conflists |
| `examples/` | Workloads applied to a cluster afterwards — smoke/netns/log/hook pods, DaemonSet, Deployment, nginx. Not baked in |
| `scripts/test-boot.sh` | QEMU boot + assert the guest checks |
| `scripts/guest-check.sh` | The capability check, piped into the guest's gosh |
| `scripts/test-cluster.sh` | M1 join test: a control plane VM + two node boots |
| `cmd/uinit/` | Both bring-ups, in the image as a bb applet: the node's and the control plane's, chosen by `/etc/k4s/role` |
| `cmd/runc-ns/` | The `runc exec` staging helper, in the image as a bb applet at `/bbin/runc-ns`: it joins a PID namespace, which `runc exec` cannot do by itself. See `docs/runc-exec.md` |
| `scripts/clone-linux.sh` | Clones the pinned kernel checkout for `make linux` |
| `docs/roadmap.md` | Milestones M0–M3 and the decisions log |
| `docs/testing.md` | What the two tests are, how a cluster test runs, and what the
harness cost to get working |
| `docs/nsenter-and-runc.md` | Why runc normally needs cgo, and the fork |
| `docs/runc-exec.md` | Why `runc exec` failed, and how `cmd/runc-ns` fixes it |
| `docs/cilium.md` | Evaluating Cilium as the CNI: what the node lacks, and why the cost is mostly kernel |
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
| flannel-cni-plugin | `b380f201008e9bed159703846cf10d3c50b4f9ce` (v1.9.1-flannel3) |
| runc | **not pinned** — the local `runc/` checkout is built as it stands, and `RUNC_REF` = `d8fe9e94fe4b6bdced1cf1d2f3ea325a896322ea` only creates it when it is missing. A fork with a Go namespace path and a Go seccomp compiler |

**2. Tidy.** `go mod tidy` in each module, then a u-root build.

**3. Standalone binaries.** Most components are folded into a single
gobusybox `bb` (dispatched by `argv[0]`). Three cannot be, because they re-exec
`/proc/self/exe` (or `os.Executable()`), which under the multiplexer resolves to
the `bb` binary itself and loses the applet name:

- `containerd-shim-runc-v2` — re-execs to spawn its daemon
- `runc` — `exec.Command(exePath, "init")` for the container init
- `kubelet` — one large binary, not an applet

`uinit` is deliberately **not** in that list. It is a bb applet, because it does
not re-exec itself and it is a `go.work` member, so it costs one copy of the Go
runtime instead of two.

All three are built `CGO_ENABLED=0` and added with `-files`. `runc` comes from
the fork (see below); `kubelet` is built with `-mod=vendor` and an ldflags
version stamp (`k8s.io/component-base/version.gitVersion=v1.35.8`).

**4. Assemble.** `./u-root/u-root` with `u-root/cmds/core/*`,
`./containerd/cmd/containerd`, `./containerd/cmd/ctr`, `./flannel`,
`./coredns`, `./etcd/etcdctl`, `./cmd/uinit` and `./cmd/runc-ns`, plus the
`-files` inputs (seventeen of them: the node config, the CA bundle, uinit's role
and the bundled CNI plugins).

### go.work is committed and load-bearing

`go.work` lists the cloned modules (`./containerd`, `./flannel`, `./runc`,
`./u-root`, `./coredns`, `./etcd/etcdctl`) and this repository's two commands
(`./cmd/uinit`, `./cmd/runc-ns`), and carries a
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

Two tests, and **neither feeds its guest anything or reads evidence off the
console**. Reaching that took three attempts, and the reason is recorded below.

`scripts/test-boot.sh <kernel> <initramfs> [guest-script]` (behind `make test`)
boots QEMU with `-serial file:` and `-display none`, so the console is a
diagnostic record and nothing depends on the guest's stdin. It then polls — never
sleeps a budget — for the node's sshd, which `uinit` starts in the node's first
seconds, and runs `scripts/guest-check.sh` as a remote command whose own stdout is
the evidence. The image under test is the one `make image` produced, with a
throwaway key appended as a second cpio archive (the kernel unpacks an initramfs
in order and a later entry replaces an earlier one) and nothing else changed.

`make test-cluster` brings its guests up the same way. Both run `/bbin/uinit`, the
bb applet built from `cmd/uinit`, which reads `/etc/k4s/role` and runs either the
node's bring-up (network, sshd, mounts, cgroups, containerd, kubelet) or the
control plane's (network, etcd, apiserver, controller-manager, scheduler), and
both are read over ssh.

Readiness is a real signal rather than a marker: the control plane is ready when
its apiserver answers on the forwarded port, which is what `wait_apiserver` polls.

That is the shape this always wanted. It replaced a bring-up script piped into
the node's shell one line at a time, and that protocol cost more time than
anything else in this project: a line had to be short or the console corrupted
it, no line could be a continuation, and **`A && B &` was accepted and then
silently did nothing at all** — which is how kubelet came to never start, the only
clue being that `/tmp/kubelet.log` did not exist. Putting the script in the image
instead was not enough either, because `gosh` reads a *file* one line at a time
too: a 157-character line lost its redirect and its trailing `&`. A Go program
has none of those problems, because the kernel runs it rather than a shell
parsing it.

The last version of the console feed was worse than slow: it *lied*. The check
script was piped into the tty, the tty echoed it, and the verdicts were grepped
out of the log that contained both — so a guest that never executed anything
reported `boot: ok`, `capabilities: ok`, `container: ok` on the source text of its
own markers. The lesson is not "parse the log more carefully". It is that the
console echoes, buffers and drops characters, so nothing may be *fed* to it or
*read* from it, and both instruments were replaced rather than patched.

The QEMU cmdline is
`console=ttyS0,115200 panic=-1 cgroup_no_v1=all tsc=unstable`. `cgroup_no_v1` is
not optional: u-root's init mounts cgroup **v1** controllers, which binds `cpu`,
`pids` and `io` to v1 and leaves cgroup v2 with only `cpuset` and `memory`; runc
then fails with `openat2 .../cpu.weight: no such file or directory`.

`tsc=unstable` is not optional here either, though for a different reason: the
guest's TSC is skewed under KVM, the kernel marks it unstable partway through the
boot, and the console wedges at that moment. Four consecutive runs failed that way
before it was added. It is a property of the test VM, not of the node, which is
why it lives in the harness and not in `configs/`.

the check's lines complete commands (gosh reads its stdin a line at a time; the
width rule went with the console). The prerequisite tools are **ssh**, **ssh-keygen** and
**cpio** — cpio is what splices the throwaway key into the image.

Success for `make test` is the guest's own output: `K4S_CHECK_START`, no
`K4S_CHECK: ...: fail`, and `K4S_CONTAINER_OK` on a line of its own.

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

- **The pod network is flannel, as a DaemonSet.** flanneld runs in a
  `kube-system` DaemonSet out of the node's own `/bbin`; the CNI plugin, the
  delegates and the conflist are baked into the image. Masquerade and port
  mappings are off: no `iptables` binary and no filter or NAT table in the
  kernel, so pods reach each other on the node and not the outside world.
- **A pod cannot reach the apiserver through its ClusterIP.** There is no
  kube-proxy and no service routing, so anything in a pod that talks to the
  apiserver must be given its address — `KUBERNETES_SERVICE_HOST`/`PORT` for
  flannel, `k8sServiceHost` for Cilium. See the networking section of
  `docs/roadmap.md`; `docs/cilium.md` prices what Cilium would need.
- **Seccomp is enforced, and the rules are a search tree.** The fork compiles
  the profile in Go and installs it, so a `RuntimeDefault` pod really runs under
  `SECCOMP_MODE_FILTER` (the M1 test asserts it). A syscall costs O(log rules)
  comparisons; `TestSectionIsATree` measures that, because a chain would still be
  correct. Architectures x/sys/unix has no table for (x32, the mips n32 ABIs,
  31-bit s390) are refused rather than filtered. See `docs/nsenter-and-runc.md`.
- **Joining a namespace by path works, with one exception.** The init process
  joins them itself, which is normally the C constructor's job; that covers the
  network, IPC and UTS namespaces a CRI pod container is given by path, and
  `make test-cluster` asserts the container's own view of its interface. A mount
  namespace additionally needs `unshare(CLONE_FS)` first, because the Go runtime
  shares one `fs_struct` across its threads and `mntns_install` refuses a shared
  one. A user
  namespace cannot be joined from a Go process at all. A PID namespace needs a
  fork (`setns` only arms `pid_ns_for_children`), which is what `cmd/runc-ns`
  does for `runc exec`; a container init gets its own by `clone(2)` instead.
  See `docs/nsenter-and-runc.md` and `docs/runc-exec.md`.
- **Rootless / user namespaces**: not supported. `CLONE_NEWUSER` plus the other
  namespaces in one `clone` returns `EPERM`; nsexec's staged unshare is the
  missing piece. The node runs containers as root, so this does not block it.
- **`runc exec` works, so container lifecycle hooks work.** `postStart` and
  `preStop` are `exec`s, so this is what gives kubelet its hooks. It used to fail
  with `error executing setns process: exit status 255`, which was three pieces of
  leftover cgo staging rather than the PID-namespace refusal it looked like: the
  netlink bootstrap message copied onto the init pipe, `setCloneFlags` applied to
  an exec child, and `execSetns` waiting for a stage-0 process a `!cgo` build
  never creates. The PID namespace is joined by `cmd/runc-ns`, a small Go helper
  built into the image as a bb applet: it `setns`es, then starts `runc init` on
  the same locked thread so the new process really is created in the container's
  PID namespace, and reports the host pid back. `examples/hook-pod.yaml` is the
  regression test. Cilium's agent hooks are still stripped by the harness — the
  exec is no longer the reason, but nothing has re-tested what that hook needs
  beyond it. Checkpoint-restore and mount-source remapping remain untested.
- **gobusybox applet flag scoping**: deferred. A per-applet `flag.CommandLine`
  swap at runtime breaks `coredns`, which registers flags from its `coremain`
  library. The correct isolation is separate processes — which is exactly what
  was done for runc — not a shared-process flag swap.
- kubelet is ~83 MiB stripped, which is a different size class from u-root's
  small-flash budget. Fine for netboot into server RAM. It is the one binary built
  with `-s -w`, against the general "don't strip while debugging" preference:
  kubelet is where stripping buys the most and costs the most debuggability, and
  both directions of that were considered. Don't change it without deciding again.

## Status

Branch `boot-qemu`. M0 (bootable image + QEMU loop) and **M1 (kubelet joins a
throwaway cluster, runs a pod under a seccomp filter, and returns after a
reboot)** are done: `make test` passes the capability check and runs a
container, and `make test-cluster` joins, runs the smoke pod (asserting the
container reports `Seccomp: 2`), reboots, rejoins and runs it again. The image
uses a cgo-free runc fork that does both cgo-only jobs — namespaces and seccomp
— in Go, and `runc exec` works, so container lifecycle hooks do: the PID
namespace an exec needs is joined by `cmd/runc-ns`, and
`examples/hook-pod.yaml` asserts that a `postStart` hook runs inside the
container's own PID namespace. `docs/roadmap.md` has the M1 findings; M2
(ephemeral hygiene, kill switch) and M3 (GPU) are next.
