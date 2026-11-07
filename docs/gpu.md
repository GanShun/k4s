# GPU support: what a diskless LLM worker actually needs

M3's acceptance line is "a diskless GPU node runs a llama.cpp/vLLM pod and
survives a reboot". This document is the analysis behind that line: what the node
image has today, what a GPU workload needs that it does not have, the driver and
library options with what each costs, and the order in which the gaps can be
closed.

**Nothing in this document is measured on a GPU.** The development host has one
display adapter — a QEMU QXL paravirtual VGA device — and no NVIDIA hardware, so
no driver can be loaded here at all. Claims about driver behaviour are therefore
marked as one of:

- **verified** — read out of this repository or a source it builds;
- **cited** — from a vendor document, with the URL;
- **expected** — believed, not checked, with the command or observation that
  would settle it.

The kernel-config and repository facts below are *verified*, and they are the
part that decides the architecture. The hardware-behaviour part is *expected*,
and is deliberately not dressed up as measurement.

## 1. Two workloads, priced separately

They are not the same problem and should not be planned as one.

| | llama.cpp | vLLM |
| --- | --- | --- |
| compute floor | none stated; works on anything with a usable backend | **compute capability 7.5** (cited: `docs/getting_started/installation/gpu.cuda.inc.md`, branch `main`) |
| accelerator APIs | CUDA, Vulkan, HIP, SYCL, Metal | CUDA, ROCm, XPU |
| weights | GGUF, quantised (4–8 bits), memory-mapped | safetensors, FP16/FP8/INT4-AWQ, loaded into VRAM |
| process shape | one binary, one process | Python, PyTorch, NCCL, one process per GPU with tensor parallelism |
| host requirements | driver + devices; no CUDA toolkit at runtime | driver + devices + NCCL-visible IPC + large `/dev/shm` |
| can it run today with no GPU? | yes — `-ngl 0`, CPU only | no |

The vLLM floor of 7.5 is the single most useful number in this document. Compute
capability 7.5 is **Turing** — the T4, the RTX 20xx parts, and nothing older. The
NVIDIA open kernel modules are supported on "any Turing or later GPU" (cited:
`open-gpu-kernel-modules` `README.md`, branch `main`). Those two floors coincide,
which means the GPUs vLLM can use are exactly the GPUs whose driver source can be
built against a kernel we choose. That coincidence decides section 4.

Capacity is separate from capability. FP16 weights are `params × 2` bytes, so
8B ≈ 16.1 GB, 70B ≈ 141 GB, 405B at FP8 ≈ 405 GB. A 16 GB T4 cannot hold 8B FP16
plus KV cache; 8B in Q4_K_M (~4.9 GB) fits comfortably, so llama.cpp on a T4 is
the cheap demonstration and vLLM of the same model wants a 5-bit-or-lower
quantisation or a bigger card.

## 2. What the node has today

| fact | evidence |
| --- | --- |
| kernel is 4.3 MiB, initramfs 226.8 MiB | `build/kernel/arch/x86/boot/bzImage`, `initramfs.cpio` |
| kernel tracks **Linux `master`** | `Makefile:26` (`LINUX_BRANCH := master`); current checkout `v7.2` |
| `CONFIG_MODULES` is **not set** | `build/kernel/.config` |
| no `.ko` and no `/lib/modules` in the image | `cpio -it < initramfs.cpio` matches 0 entries |
| `/lib/modules` is a stub `mkdir`, for Cilium | `cmd/uinit/main.go:114-117` |
| no firmware loader | `CONFIG_FW_LOADER` not set |
| `/dev` is devtmpfs, mounted by u-root | `CONFIG_DEVTMPFS=y`, `CONFIG_DEVTMPFS_MOUNT=y`, `u-root/pkg/libinit/root_linux.go:112` |
| containerd has CDI on and treats turning it off as deprecated | `containerd/internal/cri/config/config.go:408-413,702-704` |
| the node is Cilium-capable but ships flannel by default | `DIT`, `configs/` |

## 3. The kernel gap, measured

### 3.1 `CONFIG_MODULES` is the whole story for the driver

A GPU driver is either built into the kernel or loaded as a module. NVIDIA's
driver cannot be built in: the proprietary half has no source, and the open half
is written as modules only. So with `CONFIG_MODULES` unset, **no NVIDIA driver of
any kind can be present on this node**, and that is decided before any question
about CUDA, images or device plugins is reached.

Flipping it is cheap. Measured by taking the shipped `.config`, setting
`CONFIG_MODULES=y`, and running `olddefconfig` exactly as `Makefile:85-87` does
(`PAHOLE=` supplied):

```
20 config lines change:

  CONFIG_MODULES=y                      CONFIG_MODPROBE_PATH="/sbin/modprobe"
  CONFIG_MODULES_TREE_LOOKUP=y          CONFIG_STRICT_MODULE_RWX=y
  CONFIG_ARCH_HAS_EXECMEM_ROX=y         CONFIG_DEBUG_INFO_BTF_MODULES=y
  + menu entries that appear and default to n:
    MODULE_SIG, MODVERSIONS, MODULE_COMPRESS, MODULE_UNLOAD,
    MODULE_FORCE_LOAD, MODULE_SRCVERSION_ALL, TRIM_UNUSED_KSYMS,
    MODULE_ALLOW_BTF_MISMATCH, MODULE_ALLOW_MISSING_NAMESPACE_IMPORTS
  + three test/probe symbols that stop being hidden
```

Two consequences worth stating because they are operational, not cosmetic:

- **`CONFIG_MODULE_SIG` and `CONFIG_MODVERSIONS` stay off.** Since we build the
  kernel and the module together, that is consistent — but it means there is no
  signature gate on modules, so *anything* in `/lib/modules` loads. The image is
  the trust boundary, which is the same argument the rest of the node uses.
- **`CONFIG_MODULE_UNLOAD` stays off.** A module cannot be removed. For the GPU
  that means a wedged driver — an Xid error, a stuck GSP — cannot be recovered by
  reloading it; the node reboots. On a RAM-only node that is nearly free, and it
  is worth taking deliberately rather than discovering later.

With those symbols set, a loadable module does build against this configuration.
Measured with a three-line canary module:

```
make -C linux O=/tmp/modout3 PAHOLE=... modules_prepare   # ok
make -C linux O=/tmp/modout3 M=/tmp/hello modules         # ok, hello.ko, 114 KiB
modinfo hello.ko: vermagic 7.2.0 SMP preempt
```

So the kernel half of "can we load a driver" is a ~20-line fragment away. Whether
*nvidia's* module builds against Linux `master` is a different question — see
§9 S3.

### 3.2 What the driver needs beyond modules

Each symbol below is either required to load, or required for a feature the
workload uses. Only the first row is required for the module to load at all.

| symbol | state | needed by |
| --- | --- | --- |
| `CONFIG_MODULES`, `CONFIG_KALLSYMS`, `CONFIG_KPROBES` | modules off; others on | loading any module |
| `CONFIG_PCI`, `CONFIG_PCI_MSI` | on | GPU presence, interrupts |
| `CONFIG_FW_LOADER` + firmware files | **off** | GSP firmware — the open modules require it (cited, see §5) |
| `CONFIG_MMU_NOTIFIER` | **off** | unified memory / UVM; normally selected by KVM, IOMMU or DRM, none of which are on |
| `CONFIG_ZONE_DEVICE`, `CONFIG_DEVICE_PRIVATE`, `CONFIG_HMM_MIRROR` | **off** | device-memory migration (`cudaMallocManaged`) |
| `CONFIG_DMA_SHARED_BUFFER` | **off** | dma-buf, PRIME, zero-copy sharing between devices |
| `CONFIG_NUMA` | **off** | GPU-to-node affinity; single-node behaviour without it |
| `CONFIG_HUGETLBFS` | **off** | not required by the driver; large-page allocation for KV cache |
| `CONFIG_TRANSPARENT_HUGEPAGE` | **off** | same, implicitly |
| `CONFIG_IOMMU_SUPPORT`, `CONFIG_VFIO` | **off** | only for passing a GPU *into* a VM — not needed on bare metal, needed on the test host (§9) |

The honest reading: modules plus the firmware loader are what a first bring-up
needs; the middle block is what "it runs, but managed memory misbehaves" looks
like if it is skipped. With D1 below, the middle block is not optional either:
HMM and GPUDirect Storage are exactly what `MMU_NOTIFIER`, `ZONE_DEVICE`,
`DEVICE_PRIVATE`, `HMM_MIRROR` and `DMA_SHARED_BUFFER` provide, and one of D1's
reasons was to keep them. Both are one fragment, so a `configs/k4s-gpu.config`
should carry the whole set rather than the minimum, and the fragment should be
opt-in (`K4S_GPU=1`, mirroring `K4S_CNI`) so the 4.3 MiB kernel stays the default
for nodes without accelerators.

### 3.3 The kernel is a moving branch, and the driver must move with it

`Makefile:26` tracks `master`, so the kernel revision changes whenever the image
is rebuilt. An out-of-tree driver is pinned to the exact kernel build it was
compiled against (vermagic), and to the exact kernel APIs it was written for.
Two consequences:

- The module must be **built as part of `make image`**, from the same kernel tree
  and the same compiler, not downloaded. That is compatible with how `DIT` builds
  the other components — but it makes the NVIDIA source a build dependency of the
  image, which it is not today.
- If upstream lands a kernel change that breaks the driver's source, `make image`
  breaks for GPU nodes. That is a real supply-chain coupling and the reason to
  build the GPU fragment against a *tested* kernel revision when the driver
  matters, rather than following `master` blindly.

## 4. Driver options

The option set is narrower than it first appears, because two constraints remove
most of it: the kernel is ours, and the weights have to arrive over the network.

### A. Proprietary kernel module (`.run`, distro packages)

The packaging invites a wrong conclusion, so it is worth stating plainly: **this
flavour builds against our kernel too.** NVIDIA's own README for the current
driver (615.78.08) describes `nvidia.ko` as "two pieces: the binary-only core,
and a kernel interface that must be compiled specifically for your kernel", and
`installdriver.html` says the interface layer "must be compiled specifically for
each kernel" and is then "linked with the closed-source portion". The `.run`
carries the interface source and a `conftest.sh` that probes the kernel, which is
why DKMS can rebuild the driver on any kernel change. Precompiled interfaces
exist as a convenience for stock distro kernels, not as a requirement.

So the constraint is not buildability; it is:

- the interface layer must support the kernel version (same 4.15+ range as the
  open modules), and must be built with the same toolchain as the kernel;
- the closed core is version-locked to the driver release, so both halves and
  the userspace (`libcuda.so.615.78.08`, `nvidia-smi`, ...) come from one
  release and cannot be mixed;
- pre-Turing GPUs need it, because the open modules start at Turing — and
  those GPUs are out of scope here, so this is the one place A would be
  mandatory and the project does not go there;
- and its licence, unlike MIT/GPL-2.0, is NVIDIA's own, so shipping the module
  inside a boot image is a question to read rather than assume.

It also has an advantage the open modules do not: GSP firmware is optional on
Turing and Ampere (`NVreg_EnableGpuFirmware=0`), where the open modules require
it. On Hopper and later both need it. That would have spared this image a firmware
blob in a 227 MiB initramfs and a `CONFIG_FW_LOADER`; choosing B means both are
required, which §5 prices.

It has a real cost too, and the driver README names it: these features "will only
work with the open kernel modules flavor" — NVIDIA Confidential Computing,
Magnum IO, **GPUDirect Storage**, **Heterogeneous Memory Management**, CPU
affinity for GPU fault handlers, and DMABUF support for CUDA allocations. GDS is
one of the weight-streaming options in §9 and HMM is what managed memory depends
on, so choosing A forecloses part of the M3 plan rather than merely changing
packaging.

### B. NVIDIA **open kernel modules** — build from source, bake into the image

- Supported: "any Turing or later GPU"; kernel 4.15 or newer (cited:
  `open-gpu-kernel-modules` `README.md`, branch `main`).
- Requires GSP firmware **and** userspace from a corresponding driver release:
  the same README says the modules "must be used with GSP firmware and user-space
  NVIDIA GPU driver components from a corresponding 615.78.08 driver release",
  installed with `--no-kernel-modules`. So the image needs the *driver userspace*
  too, not just the `.ko` files.
- Licence: dual MIT / GPL-2.0 for the kernel modules — redistributable, and GPL
  symbol use is unambiguous.
- Build: `make modules` against `KERNELDIR`, with the same toolchain that built
  the kernel (the README says so explicitly).
- Cost: the source tree is large and must be fetched at image build time; the
  resulting modules add to a 226.8 MiB initramfs and must be measured after the
  first successful build (`make modules_install DESTDIR=... && du -sh`).

**This is the chosen driver** (decision D1 below), and the reason is narrower than
"it is the only one that builds": A builds too. It is chosen because its licence
(MIT/GPL-2.0) makes baking it into an image unambiguous, its GPU floor matches
vLLM's, NVIDIA's own README says "we recommend the use of open kernel modules on
all GPUs" that support them, and it keeps GPUDirect Storage and HMM available for
the weight-streaming work in §9. The cost accepted in exchange is the mandatory
GSP firmware, which A can avoid on Turing and Ampere.

### C. Adopt a distribution kernel with distribution-built modules

Ubuntu and Debian ship `nvidia` modules prebuilt for their kernel ABIs. Taking
that path means the node kernel is no longer tinyconfig: 4.3 MiB becomes roughly
a distro kernel's ~13 MiB, the hardening posture and fragment set change, and the
kernel arrives as a distro artifact with its own update cadence.

Price it honestly: it buys *supportability* (a vendor-tested kernel/driver pair)
at the cost of the image's central property and of every kernel-config finding in
`docs/cis-level2-hardening.md`. It is the right answer only if the project decides
that a supported GPU stack outranks a 4.3 MiB kernel.

### D. nouveau + NVK (no CUDA)

Free, upstreamable, and no CUDA — so vLLM is impossible and llama.cpp works only
through its Vulkan backend. Note that Turing and later need NVIDIA's GSP firmware
even for nouveau, so this option still requires `CONFIG_FW_LOADER` and the
firmware blobs. It is a candidate for a CPU/GPU-hybrid demo node, not for the
target workload.

### E. SR-IOV / vGPU partitioning (H100 and later)

Partitioning one physical GPU into several for several pods. Requires the
licensed vGPU host driver, which is proprietary, not buildable against our kernel,
and licensed per-GPU. Defer until a specific multi-tenant requirement exists.

### Summary

| option | works with our kernel | ships legally | vLLM | llama.cpp | verdict |
| --- | --- | --- | --- | --- | --- |
| A proprietary module | **yes** | NVIDIA licence, conditional | yes | yes | builds fine, not chosen (D1) |
| **B open modules, baked** | **yes** | **yes** | **yes** | **yes** | **chosen (D1)** |
| C distro kernel + modules | yes (different kernel) | yes | yes | yes | not needed for either |
| D nouveau / NVK | yes | yes | **no** | Vulkan only | demo only |
| E SR-IOV / vGPU | no (licensed host driver) | licensed | yes | yes | defer |

## 5. Firmware, and why it is not optional

The open modules require GSP firmware (cited above). GSP is the GPU's own
firmware processor; on Turing it is an option the proprietary driver can avoid,
but the open modules cannot. So the image needs, per driver release:

- `nvidia/<version>/gsp_*.bin` under `/lib/firmware`, matching the driver exactly;
- `CONFIG_FW_LOADER` in the kernel (off today);
- no udev — the kernel's firmware loader reads the file directly, so a path in the
  initramfs is enough. `CONFIG_EXTRA_FIRMWARE` could compile it into the kernel
  instead, at the price of a larger `bzImage`; a file in the initramfs is simpler
  and can be swapped without relinking the kernel.

Firmware is the classic "works on my machine until someone reboots" dependency:
a missing blob shows up as a driver that loads and then fails to initialise, with
the reason in `dmesg` and nowhere else. It belongs in the same fragment and the
same image-build step as the modules.

## 6. Device nodes: already solved, with a caveat

A common worry is that a node without udev cannot create `/dev/nvidiactl`,
`/dev/nvidia0`, `/dev/nvidia-uvm` or `/dev/nvidia-caps/*`. **This image does not
need udev for that.** `CONFIG_DEVTMPFS_MOUNT=y` plus u-root mounting devtmpfs at
`/dev` (`u-root/pkg/libinit/root_linux.go:112`) means the kernel creates the nodes
as the modules register their devices — the same mechanism that gives the node
its `/dev/console` today.

The caveat is permissions and paths: devtmpfs gives root-owned nodes with the
major/minor the driver chose, which is what the container toolkit expects, but
`/dev/nvidia-uvm` appears only after `nvidia-uvm` is loaded, and nothing in this
image loads modules today. `uinit` will need a small "load these, then wait for
their nodes" step — a `modprobe`-equivalent plus a bounded poll on
`/dev/nvidiactl`, not a `sleep`.

## 7. Userspace: who provides what

The layering is the part that most often surprises people, because "install the
driver" means three different things at three different layers.

| layer | what | comes from | coupling |
| --- | --- | --- | --- |
| kernel | `nvidia.ko`, `nvidia-modeset.ko`, `nvidia-uvm.ko`, `nvidia-drm.ko`, `nvidia-peermem.ko` (optional) | **image**, built with the kernel | exact kernel build (vermagic) |
| firmware | `gsp_*.bin` | **image**, from the driver release | exact driver version |
| driver userspace | `libcuda.so.*`, `libnvidia-ptxjitcompiler.so.*`, `libnvidia-ml.so.*` (NVML), `nvidia-smi`, `nvidia-persistenced` | **image** (host), injected into containers | exact driver version |
| container integration | `nvidia-container-cli` (legacy runtime hook) and/or `nvidia-ctk` (CDI generator) | **image** | toolkit version |
| CUDA userland | `libcudart`, cuBLAS, cuDNN, NCCL, PyTorch | **container image** | must be compatible with the host driver's CUDA major/minor |
| device advertisement | `k8s-device-plugin` | DaemonSet pod, or baked into `/bbin` | NVML from the host driver |

Two rules follow, and both matter for a diskless node:

1. **Container CUDA does not carry a driver.** `libcuda.so` must be the host's,
   injected at container start. This is exactly what the toolkit or a CDI spec
   does, and why an image that works on a workstation fails on a node with a
   different driver.
2. **Minor-version compatibility has limits.** A container built for a newer CUDA
   minor than the host driver supports will fail at `cuInit`, not at build time.
   The authority for the driver↔CUDA matrix is NVIDIA's compatibility page
   (<https://docs.nvidia.com/deploy/cuda-compatibility/>); this document does not
   restate its numbers, because they change with every release and a stale copy
   is worse than a link.

## 8. Runtime injection: CDI, the plugin, and MIG

### CDI is already available

containerd treats CDI as on: `EnableCDI` exists, and setting it to false triggers
a deprecation warning (`containerd/internal/cri/config/config.go:408-413,
702-704`). The CRI docs configure `cdi_spec_dirs = ["/etc/cdi", "/var/run/cdi"]`.
So the modern path needs no containerd configuration change — only a spec to read.

The toolkit generates that spec. Since v1.12 it can emit CDI; since v1.18 a
**systemd service** `nvidia-cdi-refresh` writes `/var/run/cdi/nvidia.yaml` and
refreshes it when the driver changes (cited:
<https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/cdi-support.html>).
**There is no systemd on this node**, so `uinit` must run the generator itself
after the modules are loaded:

```
nvidia-ctk cdi generate --output=/var/run/cdi/nvidia.yaml
```

That is one command and one ordering constraint (after modules, before kubelet
admits GPU pods) — small, but it is the piece that silently does not exist on a
node built from an initramfs.

### The device plugin

`k8s-device-plugin` advertises `nvidia.com/gpu`; it reads NVML and needs the
host's devices and driver libraries. Relevant knobs (cited: its `README.md`):

- `migStrategy`: `none` (default), `single`, `mixed`;
- sharing via the `nvidia.com/gpu.sharing-strategy` resource: `none`, `mps`,
  `time-slicing`.

### MIG versus time-slicing, for a node that forgets everything

This is a diskless-specific question, and it argues for the simpler option:

- **Time-slicing** is a device-plugin configuration. It changes how many
  `nvidia.com/gpu` slots are advertised and serialises contexts inside the driver.
  It creates **no persistent state on the GPU**, so a reboot changes nothing.
- **MIG** partitions the GPU into instances. The mode and the instance layout are
  GPU state that must be created and is expected not to survive a reboot —
  *expected*, not verified here: the check is to configure an instance, reboot,
  and compare `nvidia-smi mig -lgip` output, and it needs hardware. If it does not
  survive, `uinit` must re-apply it on every boot, and the layout becomes part of
  the node's definition, like the CNI conflist.

Recommendation: **time-slicing first**, because it is stateless and therefore
consistent with the rest of the node's design; MIG only when a workload needs
memory isolation or a hard partition, and only after the reboot behaviour is
measured.

### The GPU Operator is the wrong shape

It is a full operator whose driver DaemonSet builds and loads a containerised
driver on the host, which assumes a writable host filesystem and a persistent
module set. An immutable, diskless node is not that. Its device plugin, by
contrast, is ordinary and can run as a DaemonSet or from `/bbin`.

## 9. Weights and boot time: the arithmetic that decides feasibility

Strict RAM-only means every boot re-streams the image *and* the weights. The
budget is therefore:

```
RAM  ≈ 2 × image_GiB (compressed blobs + unpacked snapshots in the tmpfs store)
     +  weights_GiB
     +  KV cache (grows with context × batch)
     +  CUDA/torch host-side allocations
     +  /dev/shm for tensor-parallel NCCL
```

Two consequences that are easy to miss:

- **The content store doubles the image.** A 15 GiB vLLM image costs roughly
  30 GiB of RAM before a single weight is loaded. That is the arithmetic the
  Cilium run already taught at 6144 MiB; here it is an order of magnitude bigger.
- **`/dev/shm` shares the same RAM.** Tensor parallelism passes activations
  through shared memory; on a RAM-only node it competes directly with the weights.

Boot time is then dominated by network throughput:

```
t ≈ (2 × image_GiB + weights_GiB) / (link_Gbps / 8 / 1024)   seconds, ideal
```

At 100 GbE (12.5 GB/s ideal) a 15 GiB image and 8B FP16 weights is ~5 s of wire
time; at 10 GbE it is ~50 s; a registry that serves at 200 MB/s makes it minutes
regardless of the link. The point is not the number — it is that **the number is
measurable and must be measured on the target link before M3 is committed**, which
is what `docs/roadmap.md`'s open risk already says.

Options, in the order the locked decision allows them:

1. **Trusted site cache server** — the roadmap's sanctioned answer: a separate
   host holds the image layers and the weights, nodes stream from it. Not a cache
   *on the node*, so the decision holds.
2. **Keep nodes up.** "Diskless" constrains what a node owns, not how often it
   reboots. The thundering-herd risk is a reboot-policy question.
3. **Range-request streaming of weights** (mmap over a ranged HTTP/FUSE source):
   llama.cpp's mmap makes this natural; vLLM's loader wants the whole file, so
   this helps one workload and not the other.
4. **RDMA / GPUDirect Storage** into VRAM: real, but needs an IOMMU, `nvidia-peermem`
   and a capable NIC. Out of scope until the simple path is measured.

## 10. What can be proven without a GPU, in order

Each step is falsifiable and none needs NVIDIA hardware except the last.

**S1 — modules work in this image.** Deliverable: `configs/k4s-gpu.config` with
`MODULES`, `FW_LOADER` and the feature block from §3.2; a canary module loaded by
`uinit`; `/sys/module/hello` present; `boot: ok` still green. Half of this is
already measured (§3.1: the module builds and carries the right vermagic).

**S2 — the pod plumbing end to end, with no driver.** Run llama.cpp CPU-only
(`-ngl 0`) as a pod, pulling its image on boot and serving one prompt. This proves
image pull, tmpfs budget, model fetch and the service path — everything except
the GPU. It is also the cheapest way to measure the weight-streaming arithmetic
in §9 on real hardware.

**S3 — the driver builds against *our* kernel.** No GPU required, only the source
and the kernel tree:

```
# open flavour
git clone --depth 1 https://github.com/NVIDIA/open-gpu-kernel-modules
make -C open-gpu-kernel-modules modules KERNELDIR=/path/to/kernel/build

# proprietary flavour: the documented out-of-tree invocation, which is exactly
# the shape this repository builds in
sh NVIDIA-Linux-x86_64-<version>.run --extract-only
./NVIDIA-Linux-x86_64-<version>/nvidia-installer -s --no-questions \
  --no-kernel-module-source-check \
  --kernel-source-path=linux --kernel-output-path=build/kernel
```

`--kernel-source-path` and `--kernel-output-path` exist because the interface
layer is compiled against whatever kernel you point it at, including an
out-of-tree build (`installdriver.html`). Success means the kernel/config side is
sound; failure names the API or symbol that is missing. This is the step that turns §3.2 from a list into a fact, and it
is cheap enough to run in CI for the GPU fragment.

**S4 — injection without hardware.** Prove that a GPU-shaped container receives
the driver libraries and devices it needs, using a fake device and a hand-written
CDI spec. This settles the questions this document cannot: whether
`nvidia-ctk cdi generate` needs real `/dev/nvidia*` nodes, and whether the plugin
registers when NVML is present but no GPU is. Cheap, and it removes the risk that
the first hardware bring-up is also the first injection test.

**S5 — hardware: the bring-up checklist.** On a real Turing-or-later node:

1. `dmesg | grep -i nvidia` — GSP firmware loaded, no `Xid`;
2. `nvidia-smi` — driver version, GPU present, MIG mode as intended;
3. `/dev/nvidia-uvm` exists after load;
4. `nvidia-ctk cdi generate` produces a spec with all devices;
5. a `nvidia.com/gpu: 1` pod gets `CUDA_VISIBLE_DEVICES` and `cuInit` succeeds;
6. llama.cpp serves a token on GPU; vLLM serves one on GPU;
7. reboot and repeat 1–6 — that is M3's acceptance line.

## 11. Untested ledger

Recorded so none of it is mistaken for measurement later:

- Whether `open-gpu-kernel-modules` `main` builds against Linux `master` at the
  current revision (S3).
- Whether the proprietary flavour's interface layer compiles against this
  configuration. NVIDIA documents that it is compiled per kernel; it has not been
  compiled here, so the claim is *cited*, not *verified*.
- Whether `nvidia-uvm` loads without `CONFIG_MMU_NOTIFIER`, and what CUDA loses
  if it does (§3.2).
- MIG layout persistence across reboot (§8).
- Whether `nvidia-ctk cdi generate` requires real device nodes (§10 S4).
- Module, firmware and driver-userspace sizes; and the resulting initramfs growth
  (measure after S3).
- Image and weight sizes for the chosen vLLM and llama.cpp images (measure with
  `skopeo inspect`; do not quote).
- Boot time on the target link (§9).
- Driver behaviour under `CONFIG_MODULE_UNLOAD=n`: a wedged GPU means reboot.

## 12. Decisions

### Decided by the owner

- **D1 — the driver is the open kernel modules (option B).** Built from source
  against our kernel at image-build time, with the matching userspace and GSP
  firmware. Rationale: redistributable under MIT/GPL-2.0, NVIDIA recommends them,
  and they keep GPUDirect Storage and HMM, which §9's weight streaming may want.
  The proprietary flavour stays documented in §4 because it builds fine and is the
  answer for anyone with pre-Turing hardware; it is not this project's path.
- **D2 — Turing or later only.** No pre-Turing support, so the one case where the
  proprietary modules would be mandatory does not arise, and the GPU floor is the
  same as vLLM's own.

### Still open

3. **GPU fragment opt-in** (`K4S_GPU=1`) so non-GPU nodes keep the 4.3 MiB kernel.
4. **Time-slicing before MIG**, and MIG only with a measured reboot story.
5. **The weight path**: site cache server as the sanctioned answer, or a measured
   decision to keep nodes up instead.
6. **Kernel revision discipline for GPU builds**: follow `master`, or pin the
   kernel for images that carry a driver (`docs/roadmap.md`'s Secure Boot risk is
   the same question from another side).
