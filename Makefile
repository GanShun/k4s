# k4s build system: kernel + u-root initramfs, and a QEMU smoke test.
#
#   make image    build the u-root initramfs (runs ./DIT)
#   make kernel   configure and build linux/ into build/kernel/bzImage
#   make run      boot the image interactively under QEMU
#   make test     boot headless and run the capability check
#   make clean    remove build products (keeps the kernel checkout)
#
# The kernel starts from `tinyconfig` and adds configs/k4s-tiny.config. The
# kernel is checked out at linux/ (gitignored, cloned separately).

NPROC      := $(shell nproc)
LINUX      := linux
BUILD      := build/kernel
ABS_BUILD  := $(abspath $(BUILD))
KERNEL     := $(BUILD)/arch/x86/boot/bzImage
FRAGMENT   := configs/k4s-tiny.config
IMAGE      := initramfs.cpio

QEMU       := qemu-system-x86_64
# KVM when the user can reach /dev/kvm, otherwise fall back to TCG (slow).
QEMU_ACCEL := $(shell [ -w /dev/kvm ] && echo "-enable-kvm -cpu host")
QEMU_ARGS  := -M q35 -m 1024 -smp 2 $(QEMU_ACCEL) \
              -kernel $(KERNEL) -initrd $(IMAGE) \
              -append "console=ttyS0,115200 panic=-1" -no-reboot

.PHONY: all image kernel run test clean distclean

all: image

image:
	./DIT

# run/test depend on the file so they do not rebuild the image every time;
# `make image` always rebuilds it.
$(IMAGE): DIT
	./DIT

$(BUILD):
	mkdir -p $(BUILD)

# tinyconfig is the smallest base; $(FRAGMENT) adds what the image needs.
$(BUILD)/.config: $(FRAGMENT) | $(BUILD)
	$(MAKE) -C $(LINUX) O=$(ABS_BUILD) tinyconfig
	cat $(FRAGMENT) >> $(BUILD)/.config
	$(MAKE) -C $(LINUX) O=$(ABS_BUILD) olddefconfig

kernel: $(KERNEL)

$(KERNEL): $(BUILD)/.config
	$(MAKE) -C $(LINUX) O=$(ABS_BUILD) -j$(NPROC) bzImage

run: kernel $(IMAGE)
	$(QEMU) $(QEMU_ARGS) -nographic

test: kernel $(IMAGE)
	scripts/test-boot.sh $(KERNEL) $(IMAGE)

clean:
	-$(MAKE) -C $(LINUX) O=$(ABS_BUILD) clean
	rm -f $(IMAGE)

distclean: clean
	rm -rf build
