# k4s build system: kernel + u-root initramfs, and the QEMU tests.
#
#   make image          build the u-root initramfs (runs ./DIT)
#   make kernel         configure and build linux/ into build/kernel/bzImage
#   make run            boot the image interactively under QEMU
#   make test           boot headless and run the capability check
#   make test-cluster   M1 join test with flannel (the default CNI)
#   make test-cluster-cni  M1 join test with Cilium
#   make test-all       all three, one after another
#   make clean          remove build products (keeps the kernel checkout)
#
# The kernel starts from `tinyconfig` and adds configs/k4s-tiny.config, then
# configs/k4s-cni.config on top. The second one is what Cilium needs -- XFRM,
# nftables, CGROUP_NET_CLASSID and BTF among them -- and it is included always so
# that one kernel can run either CNI. It costs about 1.5 MiB of bzImage and a
# build-time dependency on pahole (see check-pahole).
#
# The kernel is checked out at linux/ (gitignored). `make linux` clones it; see
# that target for why it is not left as a manual prerequisite.

NPROC      := $(shell nproc)
LINUX      := linux
# Pinned like every other component: HTTPS at an exact revision, resolved from a
# tag that the clone then verifies, so a moved tag fails loudly instead of
# silently building something else.
LINUX_TAG  := v7.2
LINUX_REF  := 8d3ae59288f1e7d58d76558a6ee96d533bc5019f
BUILD      := build/kernel
ABS_BUILD  := $(abspath $(BUILD))
KERNEL     := $(BUILD)/arch/x86/boot/bzImage
FRAGMENT   := configs/k4s-tiny.config
CNI_FRAGMENT := configs/k4s-cni.config
IMAGE      := initramfs.cpio

QEMU       := qemu-system-x86_64
# pahole is needed for CONFIG_DEBUG_INFO_BTF. The kernel's own Makefile honours
# this variable, so point it at a binary that is not on PATH with
# PAHOLE=/path/to/pahole make kernel. On Debian and Ubuntu the package is `pahole`;
# `dwarves` is only a metapackage that pulls it in.
PAHOLE     ?= pahole
# KVM when the user can reach /dev/kvm, otherwise fall back to TCG (slow).
QEMU_ACCEL := $(shell [ -w /dev/kvm ] && echo "-enable-kvm -cpu host")
QEMU_ARGS  := -M q35 -m 1024 -smp 2 $(QEMU_ACCEL) \
              -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
              -kernel $(KERNEL) -initrd $(IMAGE) \
              -append "console=ttyS0,115200 panic=-1 cgroup_no_v1=all" -no-reboot

.PHONY: all linux image kernel run test test-cluster test-cluster-cni test-all \
        check-pahole clean distclean

all: image

image:
	./DIT

# run/test depend on the file so they do not rebuild the image every time;
# `make image` always rebuilds it.
$(IMAGE): DIT
	./DIT

$(BUILD):
	mkdir -p $(BUILD)

# BTF generation needs pahole. CONFIG_DEBUG_INFO_BTF makes the kernel build run it
# over vmlinux, and without it the build fails in the middle of compiling with an
# unhelpful error, so check up front.
check-pahole:
	@command -v $(PAHOLE) >/dev/null 2>&1 || { \
		echo "pahole not found, and CONFIG_DEBUG_INFO_BTF needs it." >&2; \
		echo "  Debian/Ubuntu: apt-get install pahole (dwarves is only a metapackage)" >&2; \
		echo "  or build it from https://github.com/acmel/dwarves" >&2; \
		echo "  or point at one that is not on PATH: PAHOLE=/path/to/pahole make kernel" >&2; \
		exit 1; \
	}

# tinyconfig is the smallest base; the fragments add what the image needs.
# olddefconfig needs pahole too, not just the build: DEBUG_INFO_BTF's value is
# resolved while the config is being settled.
#
# check-pahole is an **order-only** prerequisite. It is phony, so as an ordinary
# prerequisite it made .config permanently out of date and re-ran tinyconfig,
# olddefconfig and the bzImage relink on every single make -- including every
# `make test`. Order-only still builds it, and still before the recipe, but it no
# longer counts towards whether .config is up to date.
$(BUILD)/.config: $(FRAGMENT) $(CNI_FRAGMENT) | $(BUILD) check-pahole
	$(MAKE) -C $(LINUX) O=$(ABS_BUILD) PAHOLE=$(PAHOLE) tinyconfig
	cat $(FRAGMENT) $(CNI_FRAGMENT) >> $(BUILD)/.config
	$(MAKE) -C $(LINUX) O=$(ABS_BUILD) PAHOLE=$(PAHOLE) olddefconfig

# A fresh checkout has no kernel, and the first `make kernel` fails with a
# kconfig error from inside the kernel's own build that does not say "clone me".
# Every other component is cloned by DIT, so clone this one too and make it a
# prerequisite of kernel -- a checkout plus `make test-all` should be the whole
# story. Depth 1, because a full Linux history is gigabytes and nothing here
# needs it.
linux:
	@scripts/clone-linux.sh $(LINUX_TAG) $(LINUX_REF) $(LINUX)

kernel: linux $(KERNEL)

$(KERNEL): $(BUILD)/.config
	$(MAKE) -C $(LINUX) O=$(ABS_BUILD) PAHOLE=$(PAHOLE) -j$(NPROC) bzImage

run: kernel $(IMAGE)
	$(QEMU) $(QEMU_ARGS) -nographic

test: kernel $(IMAGE)
	scripts/test-boot.sh $(KERNEL) $(IMAGE)

# M1 join test: a throwaway control plane in one VM, kubelet in the guest.
# flannel is the default CNI; test-cluster-cni runs the same test with Cilium.
test-cluster: kernel $(IMAGE)
	scripts/test-cluster.sh $(KERNEL) $(IMAGE)

# Cilium needs helm (HELM=... to point at one that is not on PATH) to render its
# chart, and it needs more RAM than flannel does. The node is strictly RAM-only,
# so containerd's content store is a tmpfs -- and a tmpfs defaults to half of
# RAM. At the default 1536 MiB that is ~768 MiB, and Cilium's images do not fit:
# the pull dies with "no space left on device" in the middle of extracting, which
# surfaces as an agent that never becomes ready. Flannel's images are small
# enough to fit, so only this target needs the room.
test-cluster-cni: kernel $(IMAGE)
	K4S_CNI=cilium K4S_NODE_MEM=6144 scripts/test-cluster.sh $(KERNEL) $(IMAGE)

# One after another, which is also the order of increasing cost. Each is
# self-contained: its own control plane VM, its own node boot.
test-all: test test-cluster test-cluster-cni

clean:
	-$(MAKE) -C $(LINUX) O=$(ABS_BUILD) clean
	rm -f $(IMAGE)

distclean: clean
	rm -rf build
