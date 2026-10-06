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
Cilium's chart with `helm template` and applies that instead. One kernel runs
either: `make kernel` applies both fragments, so the two cluster tests differ only
in what they install on the node.

**`make test-all`** runs all three, in order of increasing cost. From a fresh
checkout that is the whole story — `make linux` clones the pinned kernel checkout
and `DIT` fetches everything else. Roughly: 2 minutes for `make test`, 75 seconds
for two flannel boots, 210 seconds for two Cilium boots, whose agent has to
install itself before the node can become Ready at all.

One caveat, recorded because it is real rather than because it is understood. The
Cilium leg has been seen to fail at the end of its second boot with exit 255 and
no message at all. A `K4S_XTRACE` trace found the mechanism: `guest_get` used
`out=$(timeout 8 ssh ...); rc=$?`, and under `set -e` a failing ssh exits the
shell on the assignment, so `rc=$?` never ran — the code written to *handle* a
failure was defeated by the option that makes failures fatal. The `ERR` trap did
not fire because Bash does not inherit one into shell functions without `set -E`,
so the diagnostic was invisible at the one place it was needed. Both are fixed.

The trigger underneath is a genuine ssh failure — `Connection timed out during
banner exchange`, rc 255, about once per Cilium leg, at `run_cilium`'s first read.
It has **not** been reproduced deliberately. Three attempts, 121 probes with zero
failures: guest CPU saturated by a real `ctr` pull of the Cilium image (loadavg
2.34 on 2 vCPUs), host CPU saturated, and both together. ssh latency roughly
doubles under load — 0.14 s to 0.28 s — but never approaches the 5 s banner
timeout, and console round-trips are unaffected throughout, so the guest kernel
stays responsive and the added latency is in QEMU's network path.

That leaves the emulated network path as the suspect and load as the wrong
variable. The one thing those probes never exercise is Cilium's own datapath
installation — BPF attachment, routes, interface changes — which needs a real
cluster to reproduce. Until someone does, the handling is the retry that
`run_cilium` already has: the failure is now reported and absorbed instead of
killing the run, and it is counted rather than hidden.

## How a cluster test runs

Three things are involved, and it is worth being clear about which does what,
because the split is deliberate.

| | What it is | What it does |
| --- | --- | --- |
| `scripts/test-cluster.sh` (1017 lines, 30 functions) | the harness, on the host | builds the control plane, generates PKI, boots both VMs, applies manifests with `kubectl`, waits for results, reads diagnostics |
| `cmd/uinit/main.go` (~380) | **both bring-ups, in the image** | the node's: network, sshd, mounts, cgroups, containerd, kubelet. The control plane's: network, etcd, apiserver, controller-manager, scheduler. Chosen by `/etc/k4s/role` |

### The VMs bring themselves up

The last row is not a test script. It is both guests' bring-up, compiled into the
image as a **bb applet** at `/bbin/uinit`, and u-root's init runs it:
`libinit.RunCommands` walks `/inito`, `/bbin/uinit`, `/bin/uinit`,
`/buildbin/uinit`, `/bin/defaultsh`, `/bin/sh`, running each that exists and
waiting for it to exit. So `uinit` starts the daemons in their own sessions and
returns, and init falls through to a shell afterwards.

Which bring-up it runs is read from `/etc/k4s/role`, because the two roles have to
be one package: u-root builds bb with `GO111MODULE=off` in a synthetic GOPATH and
links only the packages named on its command line, so an applet cannot import a
sibling package. They were two commands sharing one until that build refused them.
The node image carries `node` and the control plane image carries `control-plane`.

**The node is fed nothing.** The harness boots the VM and waits; everything else
is the node's own doing. The console is still captured, with `-serial file:`
rather than `-nographic`, so nothing depends on the guest's stdin at all.

This replaced a bring-up script piped into the guest's shell one line at a time,
and that protocol cost more time than anything else in this project. `gosh` is not
bash: every line had to be a complete command, short enough that the console did
not corrupt it, with no backslash continuations — and **`A && B &` was accepted
and then silently did nothing at all**, which is how kubelet came to never start,
the only clue being that `/tmp/kubelet.log` did not exist. Putting the script in
the image instead did not help, because `gosh` reads a *file* one line at a time
too: a 157-character line lost its redirect and its trailing `&`, and background
jobs started without `nohup` died with the shell. The two faults concealed each
other for a long time.

A Go program has none of those problems, because the kernel runs it rather than a
shell parsing it. There is no line length, no continuation rule, no quoting, and
no `&` to be silently dropped.

**Neither VM is fed.** The control plane used to be, and `feed_guest` existed only
for it: it printed readiness markers for the harness to grep out of its console.
It now has its own role in `cmd/uinit`, which polls etcd and the apiserver before
saying it is done, and the harness's gate is the apiserver answering on the
forwarded port. The console is diagnostic-only everywhere.

One consequence of the node not being fed is that the guest does not decide when
it is finished. The harness stops the VM itself, so the guest cannot power off
while the harness is still applying pods — which used to race every check.

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
enough to be worth listing together. They live in `cmd/uinit/main.go` and
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

**A second copy of a daemon can destroy the first, and then fail.** `make test`'s
capability check used to bring the image up itself. Once `uinit` did that first,
the check was starting a *second* containerd — and containerd removes its socket
path before it listens, so the second instance deleted the running one's socket
and then failed to bind. `ctr version` could not connect at all, and the check
reported `ctr: fail` for a containerd that had been healthy the whole time. The
check now assumes nothing has started it and checks the node that brought itself
up, which is the better test anyway: it exercises the same bring-up the cluster
test uses, rather than a second one that existed only there.

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
`/etc/cni/net.d` contains Cilium's conflist before returning. Pre-placing the
conflist in the image also "worked", and was wrong — Cilium writes its own and
containerd picks it up, exactly as on any other node. That was confirmed by
removing the pre-seed and watching the test pass.

The check itself was wrong twice, which is worth recording because it looked
right and failed in a way that pointed at Cilium rather than at the check. It
required flannel's conflist to be *gone*, and matched it with a plain substring
grep. But Cilium runs with `--cni-exclusive` and that **renames** the other
conflists to `<name>.cilium_bak` rather than deleting them — so the substring
matched the backup, the condition could never be satisfied, and the run reported
"the agent is up but never wrote its CNI config" while the config sat right there.
The requirement was also unnecessary: go-cni sorts the directory
lexicographically, so `05-cilium` wins over `10-flannel` whether or not the
latter is present. It now matches Cilium's own conflist as a whole line.

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

Observations, not decisions. Most of these have since been done; they are left
here because the reasoning is what the changes were made on.

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

**The harness is ~1000 lines across 30 functions, and only some of it is the
test.** Roughly: ~50 lines build the control-plane binaries from pinned source,
~82 generate the throwaway PKI, ~150 boot and manage VMs, ~100 are Cilium, and
the rest is applying manifests and checking markers. The VM management in
particular is generic (`cp_up`, `boot`, `stop_guest`, `kill_qemu_for`,
`splice_image`, the two `build_*_image` functions), and it is
the obvious thing to factor out — or to replace, if the harness is rewritten.

**The control plane is rebuilt and re-PKI'd on every run.** That is ~185 lines
and real time per run, and it is incidental to what the test is about. Caching
the built binaries is easy; the PKI has to be regenerated per run only because
the VMs are throwaway.

**`scripts/cluster-check.sh` had drifted** — a duplicated `--- markers ---`
section, a stale header comment about fixed sleeps, and a `--- cni logs ---`
section that `cat`s whole logs to the serial console, the exact thing that was
too slow. Done: it was tidied, one markers block, no console log-catting, and
poll loops instead of fixed sleeps — and then deleted, because the node no longer
needs a script fed to it at all.

**The bring-up shape was dictated by gosh.** Done: both bring-ups are `cmd/uinit`,
a Go program in the image, so gosh's parsing rules do not apply to either guest any
more. The two faults that made the earlier file-in-the-image attempt fail cannot
happen in a compiled program — there is no line length, no continuation rule, and
no `&` to be silently dropped.

For the record, the one that cost real time: **gosh accepts `A && B &` and then
does nothing with it.** kubelet was started that way, so it silently never ran,
wrote no log, and the node never registered — and the absence of the log was the
clue, since a shell creates a redirect target before it execs, so a missing
`/tmp/kubelet.log` meant the line had never executed at all.
