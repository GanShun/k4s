# Cilium as the node CNI: evaluation

**Status: explored, not implemented (2026-10-05).** Checked against Cilium
v1.20.2 (the latest release at the time), our kernel 7.2.0 and the current
initramfs. Nothing here has been built or run; the numbers are measured, the
conclusions are not.

The roadmap says CNI is undecided and Cilium is the prod-parity choice. This is
what choosing it would cost, and the issues found while looking.

## What Cilium puts on a node

- **`cilium-agent`**, a privileged `hostNetwork: true` DaemonSet.
- **`cilium-operator`**, a Deployment that is also `hostNetwork: true` and
  privileged by default in v1.20.2 (`operator.hostNetwork: true`), which matters
  below.
- CRDs, and the agent installs **its own** CNI config into `/etc/cni/net.d` and
  its plugin into `/opt/cni/bin` at startup.

That last point is a good fit: unlike the loopback plugin, Cilium does not need
to be baked into the image. What it does need is host paths it can write, and
these are the host paths its DaemonSet mounts:

```
/lib/modules  /proc  /proc/sys/kernel  /proc/sys/net  /run/xtables.lock
/sys/fs/bpf   /var/run/netns  /etc/cni/net.d  /opt/cni/bin  /var/run/cilium
```

## Blocker 1: the kernel has no eBPF datapath — now measured

`configs/k4s-cni.config` is the fragment: Cilium's documented requirements plus
the gates that make them reachable. It builds and it boots. This is what it
costs.

| | bzImage | vmlinux | build time |
| --- | --- | --- | --- |
| the node kernel today | 3.04 MiB | 16 MiB | 100s |
| the fragment, without BTF | 3.40 MiB | 16.8 MiB | 105s |
| the fragment, **with** BTF | **4.31 MiB** | **180.8 MiB** | 137s |

Boot cost, measured as the time from QEMU start to the kernel handing off to
userspace (`Run /init as init process`), five runs each:

| kernel | best | typical |
| --- | --- | --- |
| the node kernel today | 1.60s | 1.75s |
| the fragment, without BTF | 1.60s | 1.78s |
| the fragment, with BTF | 1.81s | 1.84s |

So the node pays about **0.1s**, a few percent, and the initramfs next to it is
227 MiB: the kernel is not what makes a diskless node slow to boot. What the
fragment really costs is paid on the build host — pahole, and a debug-info build
that leaves 181 MiB of vmlinux behind — and none of that reaches the node.

### The list is not the list

Cilium's list cannot be appended to `tinyconfig` and left at that. Four of its
options silently do not take, and making them take means switching on whole
subsystems its documentation never mentions, because every distribution kernel
has them already:

| Cilium asks for | What is really needed |
| --- | --- |
| `NET_CLS_ACT`, `NET_SCH_INGRESS`, `NET_CLS_BPF` | `NET_SCHED`, a menuconfig that hides all three |
| `DEBUG_INFO_BTF` | a DWARF choice (`DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT`) with `DEBUG_INFO_NONE` off — `DEBUG_INFO` is not settable any more — plus pahole >= 1.22 on the build host, or Kconfig drops BTF without a word |
| `FIB_RULES` | `IP_MULTIPLE_TABLES`, which selects it; the symbol itself has no prompt |
| `BPF_EVENTS` | `KPROBE_EVENTS`, which lives inside `if FTRACE`, and `PERF_EVENTS` |
| `CRYPTO_SHA1` | `CRYPTO` |
| `IP_NF_FILTER`, `IP_NF_NAT` | `IP_NF_IPTABLES_LEGACY` and `NETFILTER_XTABLES_LEGACY` — `IP_NF_IPTABLES=y` alone gives an iptables with no tables in it |
| `NETFILTER_XT_TARGET_TPROXY` | `IP_NF_MANGLE`, since TPROXY lives in the mangle table |
| `NETFILTER_XT_TARGET_CT` | `IP_NF_RAW` |

That table is the actual finding: the price of Cilium's kernel support is not
the 15 options its documentation lists, it is those plus ten gates, and the
gates are the part that fails silently. Two of the symbols it names are not even
settable in a 7.2 kernel.

**This fragment is now part of the default node kernel.** `make kernel` applies
`configs/k4s-tiny.config` and `configs/k4s-cni.config` together, so one kernel
can run either CNI and there is no separate Cilium build to remember. It costs
about 1.5 MiB of bzImage and makes **pahole** a build-time prerequisite, since
`CONFIG_DEBUG_INFO_BTF` is in there. `make kernel` checks for it up front and
says what to install; `PAHOLE=/path/to/pahole make kernel` works if it is not on
`PATH`.

The numbers below were measured before that change, with the fragment applied by
hand into a separate `build/kernel-cni` so the node kernel was left alone. They
are kept because they are what the decision was made on:

```sh
export PATH=/tmp/dwarves-root/usr/bin:$PATH    # needed by olddefconfig too
make -C linux O=$PWD/build/kernel-cni tinyconfig
cat configs/k4s-tiny.config configs/k4s-cni.config >> build/kernel-cni/.config
make -C linux O=$PWD/build/kernel-cni olddefconfig
make -C linux O=$PWD/build/kernel-cni -j$(nproc) bzImage
```

## Blocker 2: `/lib/modules` does not exist in the image

The DaemonSet mounts `/lib/modules` unconditionally and — unlike `cni.confPath`
next to it — **with no `hostPathType`**:

```yaml
      - name: lib-modules
        hostPath:
          path: /lib/modules
```

The node has no modules (everything is built in) and no `/lib/modules`
directory, so that bind mount has no source and the agent pod cannot be created.
The fix is one `mkdir` in the image, but it is a hard blocker as things stand,
and it would bite any DaemonSet that mounts modules.

## Not a blocker: pulling two images on every boot

**Decided (2026-10-05): pulling on boot is fine.** The images are pinned by
digest and re-pulled like every other image the node uses, rather than being
baked into the initramfs. Recorded here only so the boot cost is not a surprise.
Measured from the registry for v1.20.2, amd64:

| Image | Compressed layers |
| --- | --- |
| `quay.io/cilium/cilium` | 245.9 MiB |
| `quay.io/cilium/operator` | 47.1 MiB |

That is ~293 MiB to pull and expand in RAM per boot, on top of whatever the
workload pulls.

## Blocker 4: the throwaway control plane cannot run a DaemonSet

`scripts/test-cluster.sh` runs etcd and kube-apiserver only, with the pods pinned
by `nodeName` because there is no scheduler and no controller-manager. Cilium is
a DaemonSet plus a Deployment, so it needs `kube-controller-manager`.

It also needs to authenticate to the apiserver. The agent and operator use
in-cluster config, i.e. a projected ServiceAccount token, but the test control
plane runs `--disable-admission-plugins=ServiceAccount`, and the token controller
that would populate that token also lives in kube-controller-manager. So
enabling the DaemonSet path is not enough on its own.

Two ways out: add kube-controller-manager to the harness (bigger, but closer to a
real cluster), or mount the kubeconfig that the harness already splices into the
image into the agent pod, which Cilium supports via its kubeconfig path. The
second is much less work and is enough to exercise the datapath.

## Smaller issues

- **No kube-proxy, and Cilium does not replace it by default.**
  `kubeProxyReplacement` defaults to `"false"`. Our node has no kube-proxy, so we
  would set it true — which is the right shape for a diskless node, and also what
  pulls in the largest block of extra kernel config above.
- **The baked conflist has to go.** `NetworkPluginMaxConfNum` is 1 and go-cni
  sorts conf files lexicographically, so Cilium's `05-cilium.conflist` would win
  over our `10-loopback.conflist` — but leaving a stale loopback conflist in
  `/etc/cni/net.d` is a silent trap, and the loopback plugin binary becomes dead
  weight. Both should be removed when a real CNI lands, and the `netns` pod check
  in `test-cluster.sh` inverted into the positive one.
- **Memory.** The QEMU guest has 1536 MiB today: images in RAM, BPF maps (Cilium
  preallocates) and the agent's RSS all land in the same budget. Expect to raise
  it, and to want a number before promising a boot time.

## What already fits (checked, so the list above is the whole list)

- **Kernel version**: 7.2.0 against Cilium's 5.10+ recommendation.
- **No bootstrap deadlock.** The agent is `hostNetwork`, and the operator is too
  by default, so both can start before any CNI exists. IPAM defaults to
  `cluster-pool`, which allocates per-node CIDRs through the `CiliumNode` CRD via
  the operator — so it does *not* need kube-controller-manager's
  `--allocate-node-cidrs`, which our control plane would not have anyway.
- **bpffs**: Cilium mounts `/sys/fs/bpf` itself when it is not already mounted,
  and it is privileged, so the node does not have to pre-mount it.
- **User namespaces**: not needed. `operator.hostUsers: true` is the default and
  is required with hostNetwork, so our missing userns support is never reached.
- **Seccomp**: kubelet applies `RuntimeDefault` to the agent container as well —
  `getSeccompProfile` has no privileged exemption
  (`kubernetes/pkg/kubelet/kuberuntime/helpers.go:296`), and our kubelet sets
  `seccompDefault: true` — so the filter our cgo-free runc installs will be live
  for Cilium's own pods. Checked against containerd's default profile
  (`contrib/seccomp/seccomp_default.go`), which lists `bpf`, `perf_event_open`,
  `ptrace`, `setns`, `unshare`, `mount`, `umount2`, `sethostname`, `init_module`
  and `finit_module`, gated on capabilities the privileged agent has.
  `kexec_load` is the one it does not list, and Cilium does not use it. This
  should work, but it is the single item here that most deserves an empirical
  re-check, because we are the ones enforcing it.
- **x32**: unreachable. Our seccomp compiler refuses x32 syscall numbers where
  libseccomp would filter them through its x32 table, but the kernel has
  `CONFIG_X86_X32_ABI` off, so no such syscall can be made.
- **State and reboots**: Cilium keeps cluster state in the apiserver (CRDs) and
  datapath state in kernel maps. A reboot loses the maps and the agent rebuilds
  them. That is compatible with strict RAM-only rather than fighting it.

## First attempt, 2026-10-05: what actually broke

Cilium was run against the node with the kernel above, and the harness grew a
`K4S_CNI=cilium` mode that renders Cilium's chart with `helm template` (the
release manifest is not in the repository), telling it the apiserver's address
via `k8sServiceHost` and giving it `10.244.0.0/16` to allocate from.

It got as far as: the operator running, the CRDs created, the agent's
initContainers all succeeding. Then the agent itself crash-looped. Three things
came out of it, two of which are the node's fault and neither of which is about
Cilium's datapath:

1. **`/` was not a shared mount.** containerd refused to create Cilium's
   `mount-bpf-fs` initContainer at all: *"path \"/sys/fs/bpf\" is mounted on
   \"/sys\" but it is not a shared mount"*. A container that mounts something
   and expects the host to see it needs the mount to propagate, and every
   distribution's init makes `/` shared. u-root's does not, so the node has to:
   `mount -t none -o shared,rec none /`. Two traps in that one line — no
   `remount`, because the kernel checks `MS_REMOUNT` before the propagation
   flags, and `-t none`, because without a type u-root's mount tries to open the
   source as a block device instead of calling `mount(2)`.

2. **kubelet's filesystem eviction thrashes on a RAM-only node.** Pulling
   Cilium's images fills containerd's RAM-backed content store, kubelet's
   eviction manager decides it must reclaim ephemeral storage, ranks the Cilium
   pods for eviction, cannot evict them because they are critical, and loops
   forever. The node never settles. There is no disk to reclaim on a diskless
   node, so filesystem eviction is off in `configs/node/kubelet.yaml` and only
   memory is watched.

3. **The empty logs were the node's fault, and they were not empty.** Every
   Cilium pod's log file existed and was empty, including the operator's, which
   was running happily and had certainly printed something. That looked like the
   node failing to capture container output. It is not: a pod that does nothing
   but write to stdout lands in `/var/log/pods/*k4s-log*/log/*.log` intact
   (`... stdout F K4S_LOG_OK`), so the runtime → shim → log path works. The
   Cilium logs were empty because those containers had written nothing. The
   agent's own log was `1.log`, zero bytes, which is the signature of a
   container that never ran — and it had not.

4. **The agent never ran: a failed `postStart` hook killed it.** The kubelet log
   says it outright:

   ```
   failed to "StartContainer" for "cilium-agent" with PostStartHookError:
   "Exec lifecycle hook ([bash -c set -o pipefail ...]) for Container
   "cilium-agent" ... failed to exec in container: failed to start e..."
   ```

   The chart's agent has a `postStart` hook whose entire body is:

   ```bash
   set -o errexit; set -o pipefail; set -o nounset
   if [[ "$(iptables-save | grep -E -c 'AWS-SNAT-CHAIN|AWS-CONNMARK-CHAIN')" != "0" ]]
   then echo 'Deleting iptables rules created by the AWS CNI VPC plugin'
        iptables-save | grep -E -v 'AWS-SNAT-CHAIN|AWS-CONNMARK-CHAIN' | iptables-restore
   fi
   ```

   Its only purpose is deleting leftovers from the **AWS VPC CNI plugin**, which
   this node has never run; on any non-AWS node it is a no-op. It fails here
   anyway, because it opens with `iptables-save | grep -c` under `set -o errexit`
   and this node has no iptables at all — the pipeline fails, `errexit` fires,
   the hook exits non-zero, and **a failed `postStart` hook makes the kubelet kill
   the container**. Hence exit 2 and an empty log while the binary itself runs
   fine by hand. The harness drops the hook when it renders the chart.

5. **The kernel has no XFRM, and `netlink.NewHandle` insists on it.** With the
   hook gone the agent ran, logged, did real work — envoy, endpoint manager,
   identity allocator — and then died with:

   ```
   level=error msg="Start hook failed" function="reconciler.newOps.func1 (.../route/reconciler/reconciler.go:76)"
   level=error msg="Failed to start hive" error="protocol not supported"
   level=fatal msg="unable to run agent: failed to start: protocol not supported"
   ```

   Line 76 is `safenetlink.NewHandle(nil)`, and that is where it dies, before it
   touches a route. `vishvananda/netlink` opens a socket for **every** family it
   supports and aborts the whole handle on the first failure:

   ```go
   var SupportedNlFamilies = []int{unix.NETLINK_ROUTE, unix.NETLINK_XFRM, unix.NETLINK_NETFILTER}
   ```

   This kernel has no XFRM subsystem at all (`tinyconfig` turns it off), so
   `socket(AF_NETLINK, SOCK_RAW, NETLINK_XFRM)` returns `EPROTONOSUPPORT` —
   literally *"protocol not supported"*. The fragment above had listed XFRM under
   "deliberately not included" on the reasoning that it is only for IPsec. It is
   not optional: **one library's default makes it a startup requirement for the
   agent.** The fix is `CONFIG_XFRM_USER=y`, which registers the family.

6. **The operator elected itself leader and then did nothing.** With
   `ipam.mode=cluster-pool` the operator is supposed to allocate pod CIDRs to
   `CiliumNode` objects. It logged "Leading the operator HA deployment", created
   its CRDs, and stopped there — no IPAM activity, no errors. The agent, waiting
   for its CIDR, sat at `required IPv4 PodCIDR not available` and never became
   ready, and the CiliumNode stayed at `{"pools":{}}`.

   The cluster-pool mode is not needed here. The controller-manager already runs
   with `--allocate-node-cidrs=true`, so the **k8s Node** has
   `spec.podCIDR: 10.244.0.0/24` — the same mechanism the flannel DaemonSet used.
   `ipam.mode=kubernetes` reads exactly that, and the CiliumNode immediately
   became `{"podCIDRs":["10.244.0.0/24"],"pools":{}}`. (Whether the operator's
   IPAM controller can be made to run is a separate question; it is not needed
   for this node.)

7. **The agent requires a BPF helper the kernel does not compile in.** With a
   CIDR it got further and stopped at:

   ```
   error="requirements failed: Require support for bpf_get_cgroup_classid() (Linux 5.7.0 or newer)"
   ```

   The helper exists only when `CONFIG_CGROUP_NET_CLASSID` is set, so a traffic
   class feature that sounds optional is a hard startup requirement. The
   fragment now sets it. (Note the message blames the kernel version; the kernel
   here is 7.2.0. The version is a proxy for the helper probe.)

8. **iptables: the binary is present, and the kernel refuses it.** The agent's
   iptables reconciler then failed with:

   ```
   cannot add custom chain CILIUM_INPUT: unable to add CILIUM_INPUT chain:
   (unable to run 'iptables -t filter -N CILIUM_INPUT'
    iptables command: exit status 4
    stderr="iptables v1.8.8 (nf_tables): TABLE_ADD failed (Operation not supported)")
   ```

   Read that carefully, because it answers the go-iptables question with evidence
   rather than argument. Cilium's **own image ships `iptables v1.8.8`**, so
   `exec.LookPath` finds a binary and `coreos/go-iptables` would happily exec it.
   The failure is `TABLE_ADD failed` — **the kernel** refusing to create the
   table. No userspace library, in Go or otherwise, can fix that.

   The specific mismatch is the backend: the image's iptables is the **nftables**
   one (`nf_tables`), while this fragment had priced only the **legacy** tables
   (`IP_NF_IPTABLES_LEGACY`, `NETFILTER_XTABLES_LEGACY`, ...). So `CONFIG_NF_TABLES`
   and `CONFIG_NFT_COMPAT` are added. The alternative — pointing Cilium at
   `iptables-legacy` — needs no kernel change, and is the cheaper experiment if
   the nft path disappoints.

9. **Still open: the BPF alignchecker is OOM-killed.**
   `Failed to compile bpf_alignchecker.o: signal: killed` — `signal: killed` is
   the OOM killer, so this is a memory or rlimit matter inside the agent
   container rather than a kernel feature. It has not been chased yet.

10. **The CRI was using flannel, not Cilium, and it was caching the choice.** With
    the conflist and BPF blockers cleared, pods still got no address, and the
    kubelet said why:

    ```
    failed to setup network for sandbox "...": plugin type="flannel" failed (add):
      failed to load flannel 'subnet.env' file:
      open /run/flannel/subnet.env: no such file or directory
    ```

    The CRI reads `/etc/cni/net.d` **once**, at startup, and uses what it cached.
    At that moment the only conflist on disk was flannel's -- Cilium writes its
    own only once its agent is ready, which is later -- so containerd cached the
    flannel plugin and never looked again. Leaving flannel's conflist in place to
    keep the directory non-empty (a reasonable-sounding fix, since a directory
    with *no* conflist is `ErrCNINotInitialized`) is what caused this.

    The fix is to put the conflist Cilium will write there before containerd
    starts: the harness splices `configs/node/05-cilium.conflist` into the node
    image and removes flannel's, so the directory contains exactly the right
    plugin at the moment the CRI reads it. The agent rewrites the same file
    identically when it becomes ready. With that, `make test-cluster` passes with
    Cilium as the node's CNI: the agent runs, the node is Ready, a pod that asks
    for its own network namespace gets an address, and the DaemonSet and
    Deployment checks pass.

### Read the node over ssh, not over the serial console

Every one of the failures above was made much harder to find than it needed to
be, and the reason was the diagnostics rather than the bug. The harness fed the
guest its script through the serial console, and three separate things follow
from that: the console drops characters when handed a lot at once (which was
corrupting the script and stopping the guest partway, silently), printing a log
takes minutes at 115200 baud, and a log has to be printed at exactly the right
moment to be caught at all.

u-root ships an `sshd`, so the node now runs it: the harness generates a
throwaway key per run, splices it in beside the kubeconfig, forwards a host port
to the guest, and reads files out of the node directly. That turned a
twenty-minute guess into a one-second `cat`, and the answer to blocker 10 was in
the first file it read.

What is *not* the problem, having checked: image pulls are fast (Cilium's image
came in 9 seconds), seccomp (the chart marks the agent Unconfined, and the
operator runs under `RuntimeDefault` without trouble), memory (6 GB was plenty),
and the agent binary itself, which runs correctly by hand.

### `coreos/go-iptables` is not an implementation

Worth settling, because Cilium really does depend on it (`coreos/go-iptables
v0.8.0` in v1.20.2's `go.mod`). It cannot help a node with no iptables: it is a
**wrapper that executes the `iptables` binary**, not iptables in Go.

```go
path, err := exec.LookPath(cmd)         // iptables.go:152
cmd := exec.Command(path, "--version")  // iptables.go:655
```

Its README is explicit — "go-iptables wraps invocation of iptables utility" — and
gives the reason: netfilter's in-kernel API has no good userspace interface, the
tables are replaced wholesale via `setsockopt`, and resolving a change to an
existing table in userspace is error-prone enough that netfilter's own
maintainers tell you to shell out. So it is a library, and what this node needs
is a **binary on `PATH`**. Using it here would mean writing a program around it
that still has nothing to call.

That leaves three honest options if iptables turns out to be needed, none of them
"use go-iptables":

* **Ship a static `iptables`.** The kernel side is already priced and built
  (`IP_NF_IPTABLES_LEGACY`, `NETFILTER_XTABLES_LEGACY`, `IP_NF_FILTER/NAT/MANGLE/RAW`,
  `NETFILTER_XT_TARGET_MASQUERADE` are all `=y` above). The userspace side is a C
  program, so the image — static, no libc — needs a static build of it. This is
  the conventional answer and the one Cilium assumes.
* **Keep the datapath in eBPF.** `kubeProxyReplacement` plus `bpf.masquerade`
  moves the service and masquerade paths into BPF, which is where Cilium wants to
  be anyway. iptables then remains needed only for a few host-side odds and ends,
  and the question becomes how many of those this node actually hits.
* **A Go shim named `iptables`** that translates to netlink. Technically
  possible (`mdlayher/netlink`, already an indirect Cilium dependency), but it
  means reimplementing the semantics the paragraph above calls error-prone, and
  a shim that silently no-ops a firewall rule is worse than one that fails.

Only the first two are worth doing; the choice between them depends on what the
agent still asks for once it starts.

## Suggested order, if we do this

0. ~~**Make a container actually enter the pod's network namespace.**~~
   **Done (2026-10-05).** The init process joins namespaces given by path
   itself, so a pod with a CNI address really runs in its own netns; flannel
   proved it and `make test-cluster` asserts the container's own view of its
   interface. See "what is not covered" in `docs/nsenter-and-runc.md`.
1. ~~**Decide whether the kernel may grow.**~~ **Priced (2026-10-05):** the
   fragment is `configs/k4s-cni.config`, and it costs 1.26 MiB of bzImage and
   about 0.1s of boot. The decision is now about the build host (pahole, a
   debug-info build) rather than the node.
2. `mkdir -p /lib/modules` in the image.
3. Make the harness able to run a DaemonSet: kube-controller-manager, or the
   kubeconfig-mount workaround.
4. Pin Cilium by image digest, and choose pull-per-boot vs bake-into-initramfs.
5. Only then run it, and flip the `netns` pod check to the positive one.

Worth pricing at the same time: **flannel**, which is already built into the
image but unused. A working pod network from flannel plus the `bridge`,
`host-local` and `portmap` plugins needs no eBPF, no BTF and no debug-info
kernel. The roadmap's "Cilium for prod parity eventually" reads differently once
the kernel cost is on the table, and knowing the cheap interim makes the choice a
choice.
