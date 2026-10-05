# k4s: Diskless Worker Nodes — Design and Roadmap

Status: early. The repository today builds a u-root initramfs containing
`containerd`, `runc`, `flannel`, `coredns` and `etcdctl`. There is **no kubelet,
no control plane, no kernel and no bootstrap path** yet. This document is the
plan for getting to a working node and then to diskless GPU servers for LLM
inference.

## Target

Diskless Kubernetes worker nodes, geographically separated from the control
plane, running in an untrusted environment, persisting no state. Eventual
target: diskless GPU servers for LLM inference.

## Decisions (locked)

| Area | Decision |
| --- | --- |
| Threat model | Hardware is trusted while in service. On physical intrusion: cut power and assume nothing is recoverable. Diskless means no data at rest. Memory encryption (SEV/TDX) is deferred. |
| State | **Strict RAM-only.** No local medium, no local cache on the node. All images and (later) model weights arrive over the network into RAM on every boot. |
| Dev/test | QEMU plus a throwaway test cluster. Nothing touches prod until reboot-and-rejoin is boring. |
| Real boot medium | iPXE chainload. |
| Control plane | External and central. etcd quorum stays in one low-latency site. Workers are what is remote. |

### What "strict RAM-only" implies

This is the most expensive decision and it drives everything else. It is
recorded here so it is not re-litigated accidentally.

- **Boot is a network event.** Every reboot re-pulls every container image.
  A site-wide power event becomes a thundering herd against the registry.
- **LLM weights are re-streamed every boot.** Hundreds of GB per node per boot
  is the dominant cost of the GPU target. Quantify GiB/link-speed before
  committing; if it is infeasible, the answer is a *trusted site cache server*
  (a separate host that the node does not own), not a cache on the node.
- **RAM budget = weights + KV cache + CUDA userspace + image layers + tmpfs
  scratch.** Nodes must be sized for the whole set.
- **`imagefs`/`nodefs` live on tmpfs.** kubelet eviction thresholds must be set
  deliberately, and overlay-on-tmpfs doubles memory for writable layers.
- **Logs on tmpfs** are lost on reboot unless shipped off-box with buffering.

## Node architecture

```
UEFI PXE
  -> iPXE (HTTPS script, embedded CA, signed image)
    -> kernel + initramfs (verified)
      -> u-root init
        -> tmpfs mounts for /, /var/lib/containerd, /var/lib/kubelet, /var/log
          -> containerd (CRI)
            -> kubelet
              -> TLS bootstrap, join cluster
```

For testing, the cluster it joins is a second QEMU VM of the same shape: an
initramfs with etcd, kube-apiserver, kube-controller-manager and kube-scheduler
(see `scripts/controlplane-boot.sh`). It exists so that what the node joins is a
real control plane — with pod CIDR allocation, the DaemonSet and Deployment
controllers, a scheduler and service account tokens — rather than the etcd and
apiserver only pair the test started with on the host.

- No disk is mounted anywhere, ever.
- Stable identity: DMI/SMBIOS UUID or TPM EK becomes the node name; DHCP
  option 12 as fallback.
- Join: TLS bootstrap with short-TTL node certs, a one-time or attested
  bootstrap credential, and reaping of stale `Node` objects.
- Networking: CNI is undecided. Cilium for prod parity eventually, and it has
  been evaluated against this node — the cost is mostly kernel: `docs/cilium.md`.
  The node runs flannel today, so a pod with its own network namespace gets a
  real address; see the networking section under M1.
- Kill path (M2): watchdog plus an out-of-band power switch, per the intrusic
  threat model.

## Milestones

### M0 — Reproducible, bootable image with a QEMU loop

- Rewrite `DIT`: HTTPS instead of `git@github.com:`, pinned SHAs per component,
  a single pinned Go toolchain, and fix the `google.golang.org/genproto`
  duplication (unify on the split `.../googleapis/rpc` module) that the repo's
  issue #2 documents.
- `make image` and `make run` (`qemu-system-x86_64 -kernel -initrd`), plus an
  iPXE chain test against a local HTTP server.
- Acceptance: `make run` boots a u-root shell; a rebuild from a clean checkout
  produces the same image.

### M1 — kubelet spike and the first real node (done)

- Spike: prove a `CGO_ENABLED=0` static `kubelet` for `linux/amd64` (below).
- containerd CRI config; tmpfs for `/var/lib/containerd` and `--root-dir`;
  swap off; kubelet flags for ephemeral root.
- Join a throwaway test cluster and run a pod.
- Acceptance: reboot the QEMU VM, it rejoins, the workload returns.

**Status: done (2026-10-04).** `make test-cluster` stands up a throwaway
**control plane VM** (etcd, kube-apiserver, kube-controller-manager and
kube-scheduler, all built from the pinned sources and carrying a per-run PKI),
issues a kubelet kubeconfig, splices it into a copy of the initramfs, boots the
node, waits for it to register, applies `configs/node/smoke-pod.yaml`, and checks
the container wrote its marker to a hostPath. It then boots the *same image*
again and checks the node rejoins and the pod returns.

The control plane is a VM rather than host processes because the node should join
something shaped like a real cluster, and because the controller-manager is what
makes DaemonSets and Deployments possible at all — the test applies one of each
and asserts both become ready, on both boots. ServiceAccount admission is on
there too, so a pod can get a token and talk to the apiserver, which is what a
CNI's own control plane (Cilium's agent and operator) needs.

Five things the node image needed, each found by a distinct failure:

| Missing | Symptom |
| --- | --- |
| `/etc/passwd`, `/etc/group` | kubelet will not start at all: its user-namespace manager opens `/etc/passwd` (`create user namespace manager: ... no such file or directory`) |
| `/etc/hosts` | containerd cannot start the sandbox (`failed to generate sandbox hosts file ... open /etc/hosts`) |
| a CNI conflist | the node never leaves `NotReady` (`NetworkReady=false ... cni plugin not initialized`), so kubelet never runs a pod |
| `CONFIG_CFS_BANDWIDTH` | there is no `cpu.max` in a cgroup v2 leaf, so `runc create` fails on the pod container |
| cgroup2 `subtree_control` | the same `cpu.max` failure: u-root's init mounts cgroup2 but enables no controllers |

**Seccomp is enforced.** kubelet asks for `RuntimeDefault` on the pod sandbox
unconditionally, and runc can only compile a profile with cgo plus libseccomp,
so this was a real gap rather than a nicety: a cgo-free runc could not run a pod
at all. The runc fork now compiles profiles in Go (see
`docs/nsenter-and-runc.md`), and the smoke pod asserts that the container reports
`Seccomp: 2`.

Still open from M1: the smoke pod is `hostNetwork: true` because CNI is
undecided, and the pod is pinned with `nodeName` because the throwaway control
plane has no scheduler.

### Networking: from no CNI to flannel, and the bug in between (2026-10-05)

The image ships a real CNI: the flannel meta-plugin and its bridge and
host-local delegates, all pinned, with the network config baked at
`/etc/kube-flannel/net-conf.json` (host-gw, because this kernel has no VXLAN).
flanneld itself runs as a **DaemonSet** (`configs/node/flannel-ds.yaml`), the way
it is deployed for real, out of the node's own `/bbin` rather than from flannel's
container image: this image builds flanneld from the pure-Go fork, and pulling
the upstream image would replace that with a glibc build of the same program.

A pod that asks for its own network namespace gets an address from
`10.244.0.0/16`, and `make test-cluster` asserts that from both ends: the
apiserver's view of `.status.podIP`, and the container's own view of `eth0`. It
asserts it again after a reboot.

Five things were needed, each found by a distinct failure:

| Missing | Symptom |
| --- | --- |
| `CONFIG_BRIDGE_NETFILTER` | flanneld exits at startup: it stats `/proc/sys/net/bridge/bridge-nf-call-iptables` and refuses to run without br_netfilter |
| `NODE_NAME` in the pod | flanneld wants `POD_NAME`/`POD_NAMESPACE` or `NODE_NAME`, and exits rather than retrying; the DaemonSet passes `spec.nodeName` through the downward API |
| a controller-manager | flannel will not register a node with no `spec.podCIDR`, which only kube-controller-manager assigns; the control plane VM runs one with `--allocate-node-cidrs` |
| `"ipMasq": false` in the conflist | the flannel plugin sets `ipMasq = !FLANNEL_IPMASQ` in its delegate, so `--ip-masq=false` made the bridge plugin do the masquerading and need an `iptables` binary the image does not have |
| the apiserver's real address | in-cluster configuration points at the `kubernetes` service's ClusterIP, and reaching a ClusterIP needs service routing -- kube-proxy, or a CNI that replaces it. This node has neither, so flanneld could never reach the apiserver. `KUBERNETES_SERVICE_HOST`/`PORT` are set explicitly in the DaemonSet, which is the same escape hatch Cilium exposes as `k8sServiceHost`, for the same reason |

That last one is worth remembering when Cilium is tried: its agent and operator
have exactly the same problem, and `k8sServiceHost`/`k8sServicePort` are how it
is solved there. It also means the first CNI on a node cannot assume service
routing exists.

The last is worth remembering as a trap: flannel's flag is inverted on the way to
the CNI plugin, so the daemon's `--ip-masq=false` does not mean "no
masquerading", it means "the bridge plugin should masquerade". Masquerade and
port mappings are off for now, because the image has no `iptables` binary and the
kernel has no filter or NAT table; pods reach each other on the node and not the
outside world.

And it found a bug that was not flannel's. The sandbox had `10.244.0.2` and the
container reported the host's `10.0.2.15` on `eth0`: containerd gives every pod
container its sandbox's network, IPC and UTS namespaces **by path**, and the
cgo-free runc skipped anything with a path, so every pod ran in the host's
namespaces while the CRI believed otherwise. The fork now joins them in the init
process (`docs/nsenter-and-runc.md`), and the check that caught it is the one
that now passes.

Before any of that, the baseline was measured with nothing but the loopback
plugin: the node was a working worker, but a pod that asked for its own network
namespace could not start at all (`failed to find network info for sandbox`),
because a loopback result carries no address on `eth0`. That was the boundary
this work moved, and it is also why the conflist was load-bearing even then: the
CRI will not report `NetworkReady` with an empty `/etc/cni/net.d`, because it
synthesises a loopback network of its own and requires two.

### M2 — Ephemeral hygiene and the kill switch

- tmpfs and eviction policy, log shipping, watchdog/EPO integration, and the
  node-compromise credential-rotation runbook.

### M3 — GPU

- Ship a kernel with matching NVIDIA modules, firmware and
  `libnvidia-container` in the boot image. The GPU Operator's host-install
  model is incompatible with an immutable node.
- The device plugin is Go and fits the gobusybox image.
- Weights streamed over the network into RAM/VRAM; measure boot time.
- Acceptance: a diskless GPU node runs a llama.cpp/vLLM pod and survives a
  reboot.

## kubelet spike

Prove the largest unknown before writing node plumbing: can upstream kubelet be
built statically without cgo?

```
cd kubernetes   # tag v1.35.8
time CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
  go build -mod=vendor -o /tmp/kubelet ./cmd/kubelet
```

### Results (2026-10-04)

**It works, unchanged. No cgo, no `go-ceph`, no build tags.**

```
file    ELF 64-bit LSB executable, x86-64, statically linked
ldd     not a dynamic executable
go -m   k8s.io/kubernetes v1.35.8
        build CGO_ENABLED=0, GOOS=linux, GOARCH=amd64
size    118941145 bytes unstripped
        82706776 bytes stripped
```

Three findings that matter beyond the binary:

1. **Kubernetes is workspace-vendored (`## workspace` in `vendor/modules.txt`).**
   Build it with k8s's own `go.work` present, **not** `GOWORK=off`: the vendored
   `k8s.io/*` packages come from `./staging/src/k8s.io/*`, and `-mod=vendor`
   with the workspace disabled fails with `is replaced in go.mod, but not
   marked as replaced in vendor/modules.txt`. Any gobusybox integration has to
   carry the whole k8s staging workspace, not a single module.
2. **82.7 MiB stripped is the floor for kubelet alone.** The README's "fit in a
   flash part" budget (<20 MiB for all of u-root) and a kubelet-bearing image
   are different targets. Netboot into server RAM is fine; small-flash
   appliances should use a different node profile.
3. **The version string is unset.** The default build reports
   `v0.0.0-master+$Format:%H$`. Release builds must pass `-ldflags` to stamp
   `k8s.io/component-base/version`, or version skew checks will misfire.

Risks that did *not* materialize: cgo volume plugins (`rbd`/`go-ceph`) and
cloud-provider packages. They are inert with `CGO_ENABLED=0` today.

Separately, the checked-in `go.work` at the repo root lists modules that `DIT`
clones, so **any `go` command in the repo fails until `DIT` has run** (e.g.
`cannot load module ../coredns ... no such file`). M0 should scope that file or
make it generate-able so it never exists in a broken state.

## Open risks

- **Weight streaming under strict RAM-only** — the biggest risk to the GPU
  target. Needs a measured answer before M3.
- iPXE HTTPS trust model and image signature verification.
- CNI choice and behaviour across a WAN.
- Node identity and bootstrap-credential lifecycle (no shared token in an
  image).
- Kernel/module signing for Secure Boot with NVIDIA modules.
- Scale: nodes per site, link speed, reboot-storm tolerance.
