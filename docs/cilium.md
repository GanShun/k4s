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

To reproduce the numbers above, with pahole from the Ubuntu package unpacked
into `/tmp/dwarves-root` (no root needed) and a separate build directory so the
node kernel is left alone:

```
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

3. **Container logs are empty.** Every Cilium pod's log file exists and is
   empty, including the operator's, which is running happily and certainly
   printed something. That is not a Cilium problem either: it means the node is
   not capturing container output, which is worth chasing on its own. It is also
   why the agent's crash is still unexplained — there is nothing to read. (A
   guess worth testing: the shim's log fifo.)

What is *not* the problem, having checked: image pulls are fast (Cilium's image
came in 9 seconds), seccomp (the chart marks the agent Unconfined, and the
operator runs under `RuntimeDefault` without trouble), the kernel fragment (no
feature complaints), and memory (6 GB was plenty).

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
