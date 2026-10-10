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

set -Eeuo pipefail

# Same reason as the cluster harness: under `set -e` a failing command aborts with
# its own status and no explanation, and an ERR trap is not inherited by shell
# functions without -E. This script is short, but the two behave alike so that
# neither is the one you have to remember.
trap 'echo "test-boot.sh: failed at line $LINENO (exit $?)" >&2' ERR

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

# timeout kills QEMU; the guest is expected to power itself off first. The `||`
# rather than a `set +e` around it: bash fires an ERR trap for a plain failing
# command even when errexit is off, so `set +e` still produced a spurious "failed
# at line 40" on every run, including ones that passed.
rc=0
timeout "$K4S_BOOT_TIMEOUT" qemu-system-x86_64 \
	-M q35 -m 1024 -smp 2 "${ACCEL[@]}" \
	-netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
	-kernel "$KERNEL" -initrd "$IMAGE" \
	-append "console=ttyS0,115200 panic=-1 cgroup_no_v1=all" \
	-nographic -no-reboot \
	< "$CHECK" > "$LOG" 2>&1 || rc=$?

echo "--- guest output (tail) ---"
tail -40 "$LOG"
echo "---------------------------"

# The guest echoes the script as it is fed, so the *source text* of every marker
# is in the log whether or not anything ran. That made this whole check a false
# pass: a guest that hung before init fell through to a shell went down as
# "boot: ok, capabilities: ok, container: ok".
#
# Two guards. Every marker is matched as a whole line, because the echo has them
# mid-line (`echo "K4S_CHECK_END"`, `ctr run ... K4S_CONTAINER_OK`) and only real
# output is a bare line. And `uinit: done` gates the lot, since the fed script
# cannot run until uinit exits and that string appears nowhere in it.
CLEAN=$(mktemp -t k4s-clean.XXXXXX)
sed 's/\x1b\[[0-9;]*[A-Za-z]//g' "$LOG" | grep -v '^\$ ' > "$CLEAN" || true

if ! grep -q 'uinit: done' "$CLEAN"; then
	echo "boot: FAILED (the node never finished bringing itself up; qemu rc=$rc, log $LOG)" >&2
	grep -a '^uinit:' "$CLEAN" | tail -20 >&2
	exit 1
fi

if ! grep -qx "K4S_CHECK_END" "$CLEAN"; then
	echo "boot: FAILED (no end marker; qemu rc=$rc, log $LOG)" >&2
	exit 1
fi
echo "boot: ok"

if grep -qE '^K4S_CHECK:.*: fail' "$CLEAN"; then
	echo "capabilities: FAILED" >&2
	exit 1
fi
echo "capabilities: ok"

# The container's own output is the proof it actually ran.
if ! grep -qx "K4S_CONTAINER_OK" "$CLEAN"; then
	echo "container: FAILED (marker not seen)" >&2
	exit 1
fi
echo "container: ok"
rm -f "$CLEAN"
