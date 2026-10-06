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
initramfs with etcd, kube-apiserver, kube-controller-manager and kube-scheduler,
brought up by the control-plane role of `cmd/uinit`. It exists so that what the
node joins is a
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

The smoke pod is still `hostNetwork: true`, but no longer because CNI is
undecided: the CNI is chosen, and `netns-pod.yaml` is the pod that covers it. It
stays hostNetwork because it is the runtime test rather than the network test.
The pods are still pinned with `nodeName`, which is now a leftover rather than a
constraint — the control plane VM has a scheduler, and the DaemonSet and the
Deployment exercise scheduling separately.

M1 also runs an **off-the-shelf** image, which is a different kind of evidence
from the busybox pods. Stock `nginx:1.31-alpine`, pulled from docker.io, with its
own entrypoint and its own default config and no k4s code in it. The busybox pods
show that the runtime starts something; nginx shows that a real distribution's
userspace survives this kernel and this runtime, and that the node can serve a
workload someone else built. M3 asks the same question of a vLLM image, so it is
worth having answered early. See `docs/testing.md`.

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

### Control plane bring-up: kubeadm, deferred (2026-10-06)

The test cluster's control plane is hand-rolled: four binaries built from pinned
source, baked into a 296 MiB initramfs, with their flags in `cmd/uinit` and their
PKI written by `scripts/test-cluster.sh`. The alternative is **kubeadm**, and the
intended direction is to move to it. A familiar `kubeadm`/`kubelet` interface is
worth more in production than anything the hand-rolled version buys.

It is deferred rather than rejected, and the reason is worth recording because it
is a *test-time* argument that will not survive contact with production. What
kubeadm costs here:

- the control plane becomes static pods, so kube-apiserver, kube-controller-manager,
  kube-scheduler, etcd and pause arrive as **images pulled from a registry on every
  run** (~400–500 MiB). Today the 282 MiB of binaries are compiled once from pinned
  source and baked in, and the control plane needs no registry at all.
- the control plane VM is `-m 1024`, and a RAM-only image store is a tmpfs, which
  defaults to *half* of RAM. It would need roughly 4 GiB.

Neither matters on a large production machine, and neither is a reason to keep the
hand-rolled control plane forever. It is a reason not to change it while the tests
are the only consumer.

The kernel is **not** an obstacle, which is worth knowing before someone looks:
kubeadm's preflight wants `overlay`, `br_netfilter` and iptables, and this image
has `CONFIG_OVERLAY_FS=y`, `CONFIG_BRIDGE_NETFILTER=y` and `CONFIG_NF_TABLES=y`.
kubeadm is also already in the pinned `kubernetes/` checkout, so building it adds
no new dependency.

A middle path, if only the PKI is wanted: `kubeadm init phase certs all` and
`kubeadm init phase kubeconfig all` at build time replace `gen_pki`'s 82 lines of
openssl with two subcommands, and cost nothing at runtime. It is a like-for-like
swap rather than an obvious win, since `gen_pki` already works and is cached
across runs.

### Node credentials: a bootstrap token, not a baked kubeconfig (2026-10-06)

Three credentials are in play, and only one of them is hard.

- The **cluster CA certificate** is public. It belongs in the shared image.
- The **kubelet client certificate** is the working credential. It should be
  issued *by* the cluster, never shipped.
- The **bootstrap credential** — proof that a machine may join — is the only thing
  that must be per-node, or at least per-cohort, and short-lived.

Today the node gets none of this right: `gen_pki` pre-issues a `kubelet.crt` and
`kubelet.key`, the harness splices them into a copy of the initramfs, and the node
boots holding a long-lived cluster credential. That works for a two-node test and
is the wrong shape for a fleet.

**Rejected: per-worker initramfs.** This is what the test does now, generalised. A
fleet of thousands means thousands of ~230 MB artifacts to build, store and serve,
all of them rebuilt on every credential rotation or kernel bump, each carrying a
cluster credential in the boot medium — which on a netboot fleet is usually the
least protected part of the infrastructure. The softer variant is worth keeping in
mind: one shared image carrying a low-privilege *bootstrap token* instead of a
client certificate, which is expirable, revocable, and can cover a cohort. That is
most of the way to the answer below.

**Rejected: ssh-drop after boot.** It moves the bootstrap problem rather than
solving it. Authenticating *into* each node needs either host-key trust on first
contact (unsafe at fleet scale) or a fleet-wide ssh CA in the image that can write
to every node — recreating the fleet-wide credential this design is trying to
avoid. It also inverts a pull into a push: no orchestrator, no fleet, and boot
time becomes push latency. Fine as a test mechanism, wrong as the production one.

**Chosen: TLS bootstrapping, with the token delivered by the boot protocol.** The
shared image carries the CA certificate (public), the apiserver address, and the
mechanism. kubelet starts with `--bootstrap-kubeconfig`, submits a CSR, the
controller-manager's approver checks the token's group and auto-approves, and
kubelet writes its own certificate to RAM and renews it from then on. Nothing
per-node is baked into an image and nothing is pushed into a running guest.

That reduces the problem to one question: how does the token reach a netbooted
node? The structural answer is that the boot protocol already carries per-node
identity — the DHCP/PXE server knows the MAC. Three shapes, in increasing order of
infrastructure:

1. **Per-MAC iPXE or kernel cmdline.** The boot server serves a per-node script
   carrying a short-lived token; uinit reads the cmdline and fetches from a URL.
   No new services. The exposure is console-readable, which a short-lived,
   low-privilege token tolerates.
2. **A metadata service.** The node fetches a config URL, identifying itself by
   MAC. This is the cloud-init/Ignition shape; Ignition is the closest prior art,
   designed for disposable netbooted machines that need per-machine config. Costs
   one small service to run and keep available.
3. **Attestation (TPM EK / Secure Boot).** The node proves its identity
   cryptographically and there is no shared secret to deliver. This is the
   direction if the boot network itself is not trusted. It replaces only the token
   fetch — everything downstream is identical — so it can be deferred without
   changing the node's flow later.

**Disklessness makes this cheaper, not harder.** Strict RAM-only already means
every boot re-fetches everything and nothing survives a reboot. A credential is
just another thing to re-fetch, so **every reboot is a credential rotation for
free** — no expiry bookkeeping, no rotation job, no stale certificate on a disk.
The cost that normally argues against short-lived certificates, "the node has to
re-bootstrap on every boot", is a cost this design has already paid. Short-lived
plus re-bootstrap is *simpler* here than the diskful equivalent, not harder.

**The boot channel is the trust root, and that is true of every option above.** If
the kernel and initramfs arrive over unauthenticated TFTP or plain HTTP, a token
fetched over that same channel is equally unauthenticated — the secret is moved,
not protected. Short of attestation, the mitigations are serving the image and the
config over HTTPS with a pinned certificate, or keeping netboot on a private L2
segment.

What changes, concretely:

- DIT bakes the public anchor into the shared image: cluster CA certificate and
  apiserver address. No secrets.
- `uinit` gains one step before kubelet: obtain the token, write
  `/run/kubelet-bootstrap.kubeconfig` on tmpfs, and start kubelet with
  `--bootstrap-kubeconfig` and `--kubeconfig=/run/kubelet.kubeconfig`.
- The apiserver gets a bootstrap token; the controller-manager's approver and
  signer are on by default. RBAC needs `system:bootstrappers` bound to
  `system:node-bootstrapper` and the nodeclient auto-approval role.
- The harness stops splicing a kubeconfig and mints a token instead, shrinking the
  splice to one short string — a test-side simplification as much as a production
  one.
- Node naming must be stable across reboots — DMI/SMBIOS UUID, TPM EK, or the boot
  config — or Node objects and CSRs accumulate.

First step, small, and against the cluster that already exists: have `gen_pki`
mint a bootstrap token and bind those two roles, point kubelet at
`--bootstrap-kubeconfig`, and watch the node appear through a CSR instead of
through a spliced certificate. That exercises the whole path without touching the
image.

Sizing note before committing: every boot is a CSR and possibly a Node object.
Stable names plus the existing `csrcleaner` handle it, but the volume is worth
measuring at fleet scale.

### M2 — Ephemeral hygiene and the kill switch

- tmpfs and eviction policy, log shipping, watchdog/EPO integration, and the
  node-compromise credential-rotation runbook. The rotation runbook is much
  smaller once the node holds nothing longer-lived than a boot.
- Node credentials: TLS bootstrap with a token from the boot protocol, replacing
  the spliced kubeconfig — see the section above.

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
- Node identity and the bootstrap-credential lifecycle. The direction is settled
  above — TLS bootstrap, a token from the boot protocol, no secret in an image —
  but which of the three delivery shapes is not, and that depends on how far the
  netboot channel is trusted.
- Kernel/module signing for Secure Boot with NVIDIA modules.
- Scale: nodes per site, link speed, reboot-storm tolerance.
