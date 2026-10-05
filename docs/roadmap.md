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

- No disk is mounted anywhere, ever.
- Stable identity: DMI/SMBIOS UUID or TPM EK becomes the node name; DHCP
  option 12 as fallback.
- Join: TLS bootstrap with short-TTL node certs, a one-time or attested
  bootstrap credential, and reaping of stale `Node` objects.
- Networking: CNI is undecided. Cilium for prod parity eventually; the first
  bring-up only needs registration and a pod. The node works today with nothing
  but the loopback plugin, but only for `hostNetwork` pods — see the networking
  baseline under M1.
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

**Status: done (2026-10-04).** `make test-cluster` stands up a throwaway control
plane on the host (etcd and kube-apiserver built from the pinned sources), issues
a kubelet kubeconfig, splices it into a copy of the initramfs, boots the node,
waits for it to register, applies `configs/node/smoke-pod.yaml`, and checks the
container wrote its marker to a hostPath. It then boots the *same image* again
and checks the node rejoins and the pod returns.

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

### Networking baseline: what a node with no CNI can and cannot do (2026-10-05)

CNI is undecided, so it is worth being exact about what the node does today. The
image ships only the loopback plugin and one trivial conflist: there is no pod
network. `make test-cluster` now asserts both halves of that.

- **The node is a working worker.** It registers, becomes `Ready`, runs a
  `hostNetwork: true` pod, and comes back after a reboot.
- **A pod that asks for its own network namespace cannot start.** containerd
  refuses to create the sandbox and the pod stays in `ContainerCreating`:

  ```
  FailedCreatePodSandBox: Failed to create pod sandbox: rpc error: code = Unknown
  desc = failed to setup network for sandbox "...": failed to find network info
  for sandbox "..."
  ```

That is not a bug to fix, it is where the boundary is, and the test states it
(`configs/node/netns-pod.yaml`). When a real CNI lands that pod starts, the check
fails, and it has to be inverted into the positive one.

The mechanics, worth knowing before choosing a CNI:

- A `hostNetwork: true` sandbox skips CNI entirely: containerd calls
  `setupPodNetwork` only under `if !hostNetwork(config)`.
- A pod with its own netns is accepted only if the CNI result carries an address
  on `eth0`. containerd looks for `result.Interfaces["eth0"].IPConfigs` and
  otherwise returns `failed to find network info for sandbox`. A loopback plugin
  assigns nothing, so it cannot satisfy this, however many times it is listed.
- The conflist is **mandatory** all the same, which is the least obvious part.
  With containerd's defaults (`use_internal_loopback = false`) the CRI loads
  `cni.WithLoNetwork` — a synthetic loopback network it builds in memory — plus
  the conf dir, and requires two networks (`networkAttachCount = 2`). The
  synthetic one is one, so exactly one conflist on disk makes up the difference.
  With `use_internal_loopback = true` the synthetic one is dropped and the
  requirement drops to one, so a conflist is *still* required. There is no
  setting under which the CRI reports `NetworkReady` with an empty
  `/etc/cni/net.d`.
- The shipped conflist is `cniVersion 1.0.0`, and the CNI `STATUS` verb is only
  called for 1.1.0 and later, so nothing executes the plugin until a pod asks
  for a network. The file is counted, not run.

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
