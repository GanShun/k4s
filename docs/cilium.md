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

## Blocker 1: the kernel has no eBPF datapath

This is the real one. Cilium's own `system_requirements` for v1.20.2 lists the
following as *base* requirements, and this is our kernel (7.2.0) against them:

| Required | Ours |
| --- | --- |
| `CONFIG_BPF`, `CONFIG_BPF_SYSCALL`, `CONFIG_BPF_JIT` | yes |
| `CONFIG_CGROUPS`, `CONFIG_CGROUP_BPF` | yes |
| `CONFIG_PERF_EVENTS` | yes |
| **`CONFIG_NET_CLS_BPF`** | **missing** |
| **`CONFIG_NET_SCH_INGRESS`** | **missing** |
| **`CONFIG_NET_CLS_ACT`** | **missing** |
| **`CONFIG_DEBUG_INFO_BTF`** | **missing** |
| `CONFIG_BPF_EVENTS` | missing |
| `CONFIG_CRYPTO_SHA1` | missing |
| `CONFIG_SCHEDSTATS` | missing |

Cilium attaches its datapath with `tc` and BPF, so without `NET_CLS_BPF`,
`NET_SCH_INGRESS` and `NET_CLS_ACT` it cannot attach a single program. Worse,
our kernel has **`CONFIG_NET_SCHED` off**, and that is a `menuconfig`: the three
options above live inside it (`net/sched/Kconfig:6`, with `NET_CLS_ACT` at 702,
`NET_SCH_INGRESS` at 347), so they are not merely unset, they are invisible until
`NET_SCHED` is turned on. This is the same trap as `SHMEM`, `BLOCK` and
`VIRTIO_MENU` in `configs/k4s-tiny.config`: a menu option silently hiding the
things that depend on it.

`CONFIG_DEBUG_INFO_BTF` is the second problem. It is a base requirement in
v1.20.2, it needs `pahole` >= 1.22 on the build host (**not installed here**),
and it generates BTF "from DWARF debug info" (`lib/Kconfig.debug:398`), so it
also wants `CONFIG_DEBUG_INFO`, which `tinyconfig` turns off on purpose. That
means a debug-info kernel build, not just one more line in the fragment.

Beyond the base list, the features we would actually want each bring more:

| Feature | Extra kernel config | Ours |
| --- | --- | --- |
| Tunneling (VXLAN is Cilium's default) | `VXLAN`, `GENEVE`, `FIB_RULES` | all missing |
| Masquerading, default mode (iptables) | `NETFILTER_XT_SET`, `IP_SET`, `IP_SET_HASH_IP`, `NETFILTER_XT_MATCH_COMMENT` | all missing |
| kube-proxy replacement | `NETFILTER_XT_TARGET_MARK`, `..._MATCH_MARK`, `..._MATCH_SOCKET`, `..._TARGET_CT`, `..._TARGET_TPROXY`, `NET_SCH_FQ`, `XFRM_USER`, `CRYPTO_AES/CBC/GCM/HMAC/SEQIV/AEAD/SHA256` | all missing |
| IPsec | `XFRM`, `XFRM_OFFLOAD`, `XFRM_STATISTICS` | all missing |
| Netkit device mode | `NETKIT` | missing |

So this is not a one-line change; it is a decision about what the node's kernel
is. Today the bzImage is **3.0 MiB** and the initramfs is **212.6 MiB**. The
honest next step is to price it: add the options as a separate fragment
(`configs/k4s-cni.config`), build, and measure bzImage size and boot time before
committing to anything.

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

## Suggested order, if we do this

0. ~~**Make a container actually enter the pod's network namespace.**~~
   **Done (2026-10-05).** The init process joins namespaces given by path
   itself, so a pod with a CNI address really runs in its own netns; flannel
   proved it and `make test-cluster` asserts the container's own view of its
   interface. See "what is not covered" in `docs/nsenter-and-runc.md`.
1. **Decide whether the kernel may grow**, and price it with a separate fragment
   before anything else. Everything below is cheap; this is the decision.
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
