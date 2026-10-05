# The test suite: what it is, how it works, and what it cost to get here

This is the state of the tests as they stand, including the parts that were
expensive to learn and are easy to undo by accident. `docs/roadmap.md` has the
milestones; `docs/cilium.md` has the Cilium evaluation in full.

## The two tests

**`make test`** — the capability check. Boots the image headless under QEMU and
pipes `scripts/guest-check.sh` into the guest's shell. It asserts three things:
the image boots, the kernel has the capabilities the node needs, and a container
runs. It prints `boot: ok`, `capabilities: ok`, `container: ok`.

**`make test-cluster`** — the M1 join test. Boots a throwaway Kubernetes control
plane in one VM, then the node image in another, and asserts that kubelet joins,
the CNI comes up, a pod that asks for its own network namespace gets an address,
a DaemonSet and a Deployment are placed and run, the container really is under a
seccomp filter, and all of it survives a **reboot**. That last part is the whole
point of a diskless node: it must come back from nothing.

Both are `K4S_CNI`-parameterised. `flannel` is the default; `cilium` renders
Cilium's chart with `helm template` and applies that instead. Cilium needs a
different kernel (see below), which is the one rough edge in the story.

## How a cluster test runs

Three things are involved, and it is worth being clear about which does what,
because the split is deliberate.

| | What it is | What it does |
| --- | --- | --- |
| `scripts/test-cluster.sh` (~900 lines) | the harness, on the host | builds the control plane, generates PKI, boots both VMs, applies manifests with `kubectl`, waits for results, reads diagnostics |
| `scripts/controlplane-boot.sh` (73) | the control plane VM's own script | starts etcd, kube-apiserver, kube-controller-manager, kube-scheduler |
| `configs/node/uinit.sh` (88) | the node's own bring-up, **in the image** | network, mounts, cgroups, containerd, kubelet — and nothing else |

### The node brings itself up

The last row is not a test script. It is installed by `DIT` as `/bin/uinit`, and
u-root's init runs it: `libinit.RunCommands` walks `/inito`, `/bbin/uinit`,
`/bin/uinit`, `/buildbin/uinit`, `/bin/defaultsh`, `/bin/sh`, running each that
exists and waiting for it to exit. So `uinit.sh` starts the daemons in the
background and returns, and init falls through to a shell afterwards.

That is worth stating plainly because it used to be the opposite: the harness
piped the node's bring-up into the guest's shell over the serial console. Every
failure in the "Lessons" section below traces back to that, and the fix was to
stop feeding a console at all — a file in the image cannot be corrupted in
transit, and a file read over ssh does not care when it is read.

The guest script is gone entirely (`scripts/cluster-check.sh`). Nothing about the
node's bring-up is test-only any more, which is where it belongs: a diskless node
that cannot mount its own cgroups is not a diskless node.

One consequence worth knowing: u-root's init waits for `uinit` and then starts a
shell, so the shell that started the daemons **exits** a second later. Processes
in that session can get SIGHUP when it does, which would take containerd and
kubelet down with it — the symptom being a node that boots, prints
`containerd: ok`, and then never registers, with empty logs. They are started
under `nohup` to guard against that.

That guard is defensive rather than confirmed. A clean boot of this image showed
sshd and containerd both alive over ssh for 80 seconds, but the image already had
`nohup` in it, so the test does not distinguish; and Go programs ignore SIGHUP by
default, which argues it was never the cause. The node-not-registering failures
that prompted it are now attributed to something much more mundane — several
harnesses running at once and killing each other's control planes.

### How the pods are deployed

**Declaratively, from the host, with `kubectl`. The guest does not deploy pods
and contains no pod startup logic at all.**

The workloads are plain YAML in `configs/node/`: `smoke-pod.yaml`,
`netns-pod.yaml`, `ds-pod.yaml`, `deploy-pod.yaml`, `log-pod.yaml`,
`flannel-ds.yaml`. The harness applies each one with `kubectl` against the
control plane VM's apiserver (`reapply`, which deletes first so a stale status
can never drive a check), and the controllers do the rest — the scheduler places
the Deployment, the controller-manager runs the DaemonSet.

The node's bring-up ends at "kubelet is running". Everything after that is
Kubernetes doing its job, which is the point: if the test deployed pods by
handing commands to the guest, it would be testing the harness rather than the
node.

The node does not print the results anywhere. Each pod writes its result to a
`hostPath` (`/var/log/k4s-*/result`), so the evidence is on the node's filesystem
rather than in the pod's log, and it survives the pod exiting. The harness reads
those files over ssh at the end (`collect`) and checks them on the host.

### How the results are read

Over **ssh into the guest**, not over the serial console. The harness generates a
throwaway key per run, splices it and u-root's `sshd` host key into the node
image, forwards a host port to the guest, and reads the marker files and logs
directly (`collect`, `diag`).

This is not a convenience. It replaced scraping the console, which was the single
biggest source of wasted time in this project, and the reasons are in "Lessons"
below.

## What the node image needed

Every one of these was discovered by a failure, and several are non-obvious
enough to be worth listing together. They live in `scripts/cluster-check.sh` and
`configs/node/`.

| Requirement | What breaks without it |
| --- | --- |
| `/` must be a **shared** mount | containerd refuses to create any container that mounts something and expects the host to see it: `path "/sys/fs/bpf" is mounted on "/sys" but it is not a shared mount` |
| cgroup v2 **subtree_control** for cpu, cpuset, memory, pids, io | u-root mounts cgroup2 but enables no controllers, so runc cannot create the pod cgroup: `.../cpu.max: no such file or directory` |
| tmpfs on `/var/lib/containerd`, `/var/lib/kubelet`, `/var/log/pods` | there is no disk; the node is strictly RAM-only |
| kubelet **filesystem eviction off** | with images filling a RAM-backed content store, the eviction manager decides it must reclaim ephemeral storage, ranks critical pods for eviction, cannot evict them, and loops forever |
| `/lib/modules` to exist | Cilium's DaemonSet mounts it unconditionally and this image has no modules, so the path has to exist even though it is empty |
| the CNI conflist must be the right one when the CRI loads it | see the race below |

## Lessons: the diagnostics were the hard part

Every bug in this list was found quickly once it was visible. The expensive part
was making it visible, and these mistakes were all mine.

**The serial console cannot carry bulk data, and it corrupts what you send it.**
The harness fed the guest its whole script in one write; the guest's UART drops
characters under that load, which mangled the script and made the guest stop
partway through with no error. Every "empty log" and "missing file" observed
during that period was a guest that had simply stopped executing. It is now fed
one line at a time with a small delay.

**A log has to be printed at exactly the right moment to be caught, and printing
one takes minutes.** At 115200 baud, `cat`ing a Cilium agent log is thousands of
lines of dead time, and anything queued behind it never appears. Reading the same
file over ssh takes a second and does not care when it is read.

**A timeout on the wrong thing is no timeout at all.** `ssh -o ConnectTimeout=5`
bounds the TCP connect, and QEMU's user-mode port forward **accepts the
connection immediately** whether or not anything is listening inside the guest.
So connecting to a node whose sshd has not started yet succeeds, and ssh then
waits forever for a banner that is never coming. That hung a whole run for
fifteen minutes producing no output whatsoever, inside `wait_ssh`, which is
called the instant the node boots. Every ssh call is now wrapped in `timeout`,
and a timeout prints a line instead of returning empty.

**A guest that decides when it is finished races every check you make.** The
guest used to power itself off when its script ended, while the harness was still
applying pods and waiting for them. The files read afterwards were empty and the
VM was gone. The guest no longer shuts down; the harness collects what it needs
and then stops the VM.

**Runs must be self-contained.** Reusing a control plane VM between runs was a
speed hack that made runs depend on each other: that VM's etcd keeps the previous
run's Node, pods, DaemonSets and CiliumNodes, so a run could pass or fail on
another run's objects. A stale pod status makes a check fire instantly and for
the wrong reason; a stale Node object makes `node: ok (registered)` meaningless.
Every run now stops leftovers and boots its own control plane — which turned out
to be *faster* as well as correct, because there is nothing stale to wait out.

**Two harnesses at once do not fail loudly, they fail confusingly.** Each run's
`cp_down` kills any control plane VM it finds, so a second harness silently
destroys the first one's control plane and its node never registers — which looks
like a node bug, not a concurrency bug. A single-instance check exists, and it
was defeated by cleaning up with `rm -f build/controlplane/*.pid`: the lock lived
in that directory and the glob took it with it. Twelve harnesses ended up running
at once, all killing each other's VMs, and hours went into a node that never
registered. The lock now lives outside the directory that gets globbed.

**A probe that occupies a shared resource changes what you are measuring.** The
harness reaches the node over an ssh port forward on 2222. While debugging by
hand I booted the node image myself with the same forward, and left it running.
The next harness run's node VM could not bind that port, so the harness's ssh
went to *my* VM instead -- and `diag` read a filesystem from a different boot,
showing files that were hours old. That produced several rounds of confident and
entirely wrong conclusions, including a whole theory about kubelet never
starting. The timestamps in `/tmp` were what gave it away: a file I had created
by hand at 16:06, on a node that had supposedly booted at 16:2x.

The harness now refuses to start if either port is already bound, and names the
reason. It is a two-line guard, and it would have saved hours.

The general lesson, and the one that cost the most: **do not diagnose through an
instrument you have reason to distrust.** The conflist bug below was misdiagnosed
while the console corruption was still live, and the wrong explanation survived
for a long time afterwards. The same applies to reading evidence: `guest_get`
used `ssh -q` with the exit status swallowed, so a dropped connection produced
exactly the same empty output as an empty file, and a stale file left by an
earlier run was read as proof that ssh was working. It is `LogLevel=ERROR` now.

## The conflist race, precisely

Worth writing down because the mechanism is subtle and the wrong explanation is
attractive.

containerd's CRI loads `/etc/cni/net.d` at init and its fsnotify syncer
deliberately ignores `Create` events:

```go
// Only reload config when receiving write/rename/remove events
if event.Has(fsnotify.Chmod) || event.Has(fsnotify.Create) { continue }
```

So a conflist that *appears* after containerd started is only picked up via the
write/rename/remove path. Cilium's agent reports ready before its `cni-config`
cell has written that file, so a pod applied in that window gets whatever was
loaded at init: flannel's plugin (`failed to load flannel 'subnet.env'`), or
nothing at all.

The fix is a check, not a workaround: `run_cilium` waits until the node's
`/etc/cni/net.d` contains Cilium's conflist and no longer contains flannel's
before returning. Pre-placing the conflist in the image also "worked", and was
wrong — Cilium writes its own and containerd picks it up, exactly as on any other
node. That was confirmed by removing the pre-seed and watching the test pass.

## Cilium's real cost on this node

Recorded in full in `docs/cilium.md`; the short version is three kernel options
and one config change, none of which is a userspace problem:

* `CONFIG_XFRM_USER` — `vishvananda/netlink`'s `NewHandle` opens sockets for
  `NETLINK_ROUTE`, `NETLINK_XFRM` and `NETLINK_NETFILTER` and aborts the whole
  handle on the first failure. XFRM reads as IPsec-only; a library default makes
  it a startup requirement.
* `CONFIG_CGROUP_NET_CLASSID` — `bpf_get_cgroup_classid()` is required outright.
* `CONFIG_NF_TABLES` + `CONFIG_NFT_COMPAT` — Cilium's image ships `iptables-nft`
  and the kernel had only the legacy tables.
* `ipam.mode=kubernetes` — the operator never ran its cluster-pool allocator,
  while the controller-manager already allocates `spec.podCIDR`.

Also worth remembering: the chart's agent carries a `postStart` hook that deletes
leftovers from the AWS VPC CNI plugin. It needs `iptables-save`, which this node
does not have, and a failed `postStart` hook makes the kubelet kill the
container — which is why the agent died with exit 2 and an empty log while the
binary ran fine by hand. The harness drops the hook when it renders the chart.

`coreos/go-iptables` cannot help with any of this: it is a wrapper that `exec`s
the `iptables` binary, Cilium's image already ships one, and the failure was
`TABLE_ADD failed` — the kernel refusing.

## What could be simpler

Observations, not decisions. The first, second and fourth of these have since
been done; they are left here because the reasoning is what the changes were
made on.

**The Makefile did not know about Cilium.** The Cilium kernel was built by hand
into `build/kernel-cni` (the recipe is in `docs/cilium.md`) and the Cilium test
was run by invoking the script with `K4S_CNI=cilium`, so a clean checkout could
not run "both tests" without reading a doc. Done: `make kernel` now applies both
fragments, and there are `test-cluster-cni` and `test-all` targets.

**The harness has no overall bound, and that is why hangs are expensive.** Every
individual wait is bounded, but nothing bounds the run as a whole, and a
surprising number of the bugs in this list turned a broken check into fifteen
minutes of silence: a silent 45-attempt ssh loop, a call whose timeout covered
the wrong phase, a lock that was not there. A single watchdog at the top that
prints the current phase and exits would turn every one of those into a fast,
informative failure. It is the one structural thing still worth adding.

**The harness is ~900 lines across 32 functions, and only some of it is the
test.** Roughly: ~50 lines build the control-plane binaries from pinned source,
~82 generate the throwaway PKI, ~150 boot and manage VMs, ~100 are Cilium, and
the rest is applying manifests and checking markers. The VM management in
particular is generic (`cp_up`, `boot`, `feed_guest`, `stop_guest`,
`kill_qemu_for`, `splice_image`, the two `build_*_image` functions), and it is
the obvious thing to factor out — or to replace, if the harness is rewritten.

**The control plane is rebuilt and re-PKI'd on every run.** That is ~185 lines
and real time per run, and it is incidental to what the test is about. Caching
the built binaries is easy; the PKI has to be regenerated per run only because
the VMs are throwaway.

**`scripts/cluster-check.sh` had drifted** — a duplicated `--- markers ---`
section, a stale header comment about fixed sleeps, and a `--- cni logs ---`
section that `cat`s whole logs to the serial console, the exact thing that was
too slow. Done: the file is gone, superseded by `configs/node/uinit.sh`.

**The node's bring-up shape is dictated by gosh.** `uinit.sh` is a file in the
image, so it cannot be corrupted in transit the way a console-fed script could —
but gosh still reads it one line at a time, and its parsing is not bash's. Every
line must be a complete command, with no multi-line blocks and no backslash
continuations. The one that cost real time: **gosh accepts `A && B &` and then
does nothing with it.** kubelet was started that way, so it silently never ran,
wrote no log, and the node never registered — and the absence of the log was the
clue, since a shell creates a redirect target before it execs, so a missing
`/tmp/kubelet.log` meant the line had never executed at all. A plain
`nohup cmd ... &` on its own line works, which is why containerd and sshd were
fine and only kubelet was missing.
