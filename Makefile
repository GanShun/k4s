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
# A longterm branch, not master and not the current stable. `master` is a moving
# feature branch: a Kconfig change landed there between one clone and another and
# silently dropped CONFIG_PROC_SYSCTL from the generated config, so the kernel one
# machine built was not the kernel CI built.
#
# The current stable line (7.3.3 when this was written), moved deliberately when we
# want to. Not master, which is a moving feature branch; not a longterm for now,
# because the node tracks what Cilium and the eBPF datapath are developed against.
# A stable branch carries backported fixes and no features, so the kernel cannot
# change shape under a build -- when it does need to change, that is a commit here.
LINUX_BRANCH := linux-7.3.y
# The stable tree is where that branch lives; torvalds/linux has no linux-X.Y.y
# branches at all.
LINUX_REMOTE := https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git
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

.PHONY: all linux image kernel run test test-cluster test-cluster-cni test-runc test-all \
         check-pahole check-fragments FORCE \
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
# Runs every time; the recipe above only rewrites the stamp when the version
# differs, so a stable toolchain never invalidates the config.
FORCE:

# Whether DEBUG_INFO_BTF can be enabled depends on pahole, and olddefconfig drops
# the symbol silently when it cannot. A .config generated before pahole existed is
# then wrong *and* newer than the fragments, so make would never rebuild it -- which
# is how the image ended up booting a kernel with no BTF. Recording the version as a
# dependency regenerates the config once, and only once, when pahole appears or
# changes.
$(BUILD)/pahole.version: FORCE | $(BUILD) check-pahole
	@v=$$($(PAHOLE) --version 2>/dev/null | head -1); \
	if [ "$$v" != "$$(cat $@ 2>/dev/null)" ]; then echo "$$v" > $@; fi

$(BUILD)/.config: $(FRAGMENT) $(CNI_FRAGMENT) $(BUILD)/pahole.version | $(BUILD) check-pahole
	$(MAKE) -C $(LINUX) O=$(ABS_BUILD) PAHOLE=$(PAHOLE) tinyconfig
	cat $(FRAGMENT) $(CNI_FRAGMENT) >> $(BUILD)/.config
	$(MAKE) -C $(LINUX) O=$(ABS_BUILD) PAHOLE=$(PAHOLE) olddefconfig
	$(MAKE) check-fragments

# A fragment symbol that olddefconfig cannot satisfy is dropped, not reported:
# tinyconfig turns a dependency off, which *hides* the option, and the config comes
# out without it. That is how CONFIG_DEBUG_INFO_BTF went missing -- the kernel in the
# image had no BTF, so every eBPF program Cilium tried to load failed CO-RE
# relocation with "no BTF found", and nothing said so. It is the same class as
# TMPFS, VIRTIO and BLK_CGROUP, which this file already calls load-bearing by hand.
#
# So every `CONFIG_X=y` a fragment asks for must be in the resulting .config, or the
# build stops and names them. Only =y lines are checked: `# CONFIG_X is not set` is
# a deliberate negative and `CONFIG_X="..."` may legitimately take another value.
check-fragments:
	@[ -f $(BUILD)/.config ] || { \
		echo "  no .config yet; the recipe that generates it checks the fragments"; \
		exit 0; \
	}; \
	missing=$$( \
		for f in $(FRAGMENT) $(CNI_FRAGMENT); do \
			grep -E '^CONFIG_[A-Z0-9_]+=y$$' $$f; \
		done | sort -u | while read -r want; do \
			grep -qxF "$$want" $(BUILD)/.config || echo "$$want"; \
		done); \
	if [ -n "$$missing" ]; then \
		echo "these fragment symbols are not in $(BUILD)/.config:" >&2; \
		printf '  %s\n' $$missing >&2; \
		echo "three causes, in order of how often they are it:" >&2; \
		echo "  * linux/ is not on $(LINUX_BRANCH): a checkout from another branch" >&2; \
		echo "    cannot satisfy a symbol that only exists on this one. move it," >&2; \
		echo "    or delete it and let 'make linux' clone the right branch;" >&2; \
		echo "  * a dependency is off, which hides the option instead of failing" >&2; \
		echo "    it -- check the fragment above the symbol;" >&2; \
		echo "  * this config is stale: generated when a dependency (pahole," >&2; \
		echo "    usually) was missing, and newer than the fragments so make will" >&2; \
		echo "    not redo it. delete $(BUILD)/.config and run 'make kernel'." >&2; \
		exit 1; \
	fi

# A fresh checkout has no kernel, and the first `make kernel` fails with a
# kconfig error from inside the kernel's own build that does not say "clone me".
# Every other component is cloned by DIT, so clone this one too and make it a
# prerequisite of kernel -- a checkout plus `make test-all` should be the whole
# story. Depth 1, because a full Linux history is gigabytes and nothing here
# needs it.
linux:
	@scripts/clone-linux.sh $(LINUX_BRANCH) $(LINUX) $(LINUX_REMOTE)

kernel: linux $(KERNEL)
	@$(MAKE) --no-print-directory check-fragments

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

# runc's own suite, in the guest. It needs root and CAP_SYS_ADMIN, which CI
# cannot give it (runc issue #4) and this node has; the suite is cross-compiled
# and the fixture injected, so this is the only route to a real result for runc
# #1 and #3.
#
# K4S_RUNC_TESTS is a Go -test.run regex, e.g. K4S_RUNC_TESTS='TestExecIn$|TestPIDHost'.
# $(value ...) is not decoration: a plain $(K4S_RUNC_TESTS) is expanded by make, so
# the $ in "$|" -- the order-only-prerequisites automatic variable -- disappears
# and the selector silently matches nothing. A selector containing a single quote
# still breaks the guest script; not worth handling for a test filter.
K4S_RUNC_TESTS ?= .
test-runc: kernel $(IMAGE)
	scripts/test-runc.sh $(KERNEL) $(IMAGE) '$(value K4S_RUNC_TESTS)'

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
