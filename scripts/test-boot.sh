#!/bin/bash
#
# Boot the k4s image under QEMU and run scripts/guest-check.sh inside it.
#
# The image's default shell is u-root's gosh, which treats a non-tty stdin as
# a script. QEMU's -nographic wires the guest serial console to our stdin, so
# piping the check script in is enough to drive it non-interactively.
#
# Usage: test-boot.sh <kernel> <initramfs> [guest-script]
#
# Env: K4S_BOOT_TIMEOUT  seconds to wait for the guest (default 180)

set -euo pipefail

KERNEL=${1:?usage: test-boot.sh <kernel> <initramfs> [guest-script]}
IMAGE=${2:?usage: test-boot.sh <kernel> <initramfs> [guest-script]}
CHECK=${3:-$(dirname "$0")/guest-check.sh}

K4S_BOOT_TIMEOUT=${K4S_BOOT_TIMEOUT:-180}
LOG=$(mktemp -t k4s-boot.XXXXXX.log)
trap 'echo "guest log: $LOG"' EXIT

ACCEL=()
if [ -w /dev/kvm ]; then
	ACCEL=(-enable-kvm -cpu host)
else
	echo "note: /dev/kvm not writable; falling back to TCG (slow)" >&2
fi

echo "booting $KERNEL with $IMAGE (timeout ${K4S_BOOT_TIMEOUT}s)"

# timeout kills QEMU; the guest is expected to power itself off first.
set +e
timeout "$K4S_BOOT_TIMEOUT" qemu-system-x86_64 \
	-M q35 -m 1024 -smp 2 "${ACCEL[@]}" \
	-kernel "$KERNEL" -initrd "$IMAGE" \
	-append "console=ttyS0,115200 panic=-1" \
	-nographic -no-reboot \
	< "$CHECK" > "$LOG" 2>&1
rc=$?
set -e

echo "--- guest output (tail) ---"
tail -40 "$LOG"
echo "---------------------------"

if ! grep -q "K4S_CHECK_END" "$LOG"; then
	echo "boot: FAILED (no end marker; qemu rc=$rc, log $LOG)" >&2
	exit 1
fi
echo "boot: ok"

if grep -q "K4S_CHECK:.*: fail" "$LOG"; then
	echo "capabilities: FAILED" >&2
	exit 1
fi
echo "capabilities: ok"
