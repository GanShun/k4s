#!/bin/bash
#
# Boot the k4s image under QEMU and run scripts/guest-check.sh inside it over ssh.
#
# The check script used to be piped into the serial console, because u-root's gosh
# treats a non-tty stdin as a script. That is the wrong instrument, for the reason
# docs/testing.md already gives about the cluster harness: the console drops
# characters under load, it echoes what it is fed back into its own log, and the
# echo of the script is indistinguishable from the script having run. It reported
# three green verdicts for a guest that never executed anything.
#
# So this does what test-cluster.sh does: sshd comes up in the node's first
# seconds, the harness uses a throwaway key it splices into the image, and the
# evidence is the remote command's own stdout. Nothing is fed to the console, and
# the console is kept only so that a boot that fails to come up says where.
#
# Usage: test-boot.sh <kernel> <initramfs> [guest-script]
#
# Env: K4S_BOOT_TIMEOUT  seconds to wait for the guest (default 180)
#      K4S_BOOT_SSH_PORT host port forwarded to the node's sshd (default 2223)
#
# Needs ssh, ssh-keygen and cpio on the host. cpio is what splices the key in.

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
# Not K4S_SSH_PORT: the cluster harness owns that name and its default, and the two
# harnesses would otherwise collide if anyone ever ran them concurrently.
K4S_BOOT_SSH_PORT=${K4S_BOOT_SSH_PORT:-2223}

LOG=$(mktemp -t k4s-boot.XXXXXX.log)
WORK=$(mktemp -d -t k4s-boot.XXXXXX)
trap 'rm -rf "$WORK"; echo "guest log: $LOG"' EXIT

ACCEL=()
if [ -w /dev/kvm ]; then
	ACCEL=(-enable-kvm -cpu host)
else
	echo "note: /dev/kvm not writable; falling back to TCG (slow)" >&2
fi

# A throwaway key pair, never committed and valid only for this VM on a loopback
# port. The node image itself carries no key.
log_ssh_dir=$WORK/root/etc/ssh
mkdir -p "$log_ssh_dir"
ssh-keygen -q -t rsa -b 2048 -N '' -f "$WORK/host_rsa"
ssh-keygen -q -t rsa -b 2048 -N '' -f "$WORK/client"
cp "$WORK/client.pub" "$log_ssh_dir/authorized_keys"
cp "$WORK/host_rsa" "$log_ssh_dir/host_rsa"

# Splice them in by appending a small cpio to the image rather than repacking it:
# the kernel unpacks an initramfs in order and a later entry replaces an earlier
# one, so this is both cheaper and harder to get wrong than rewriting 228 MB.
#
# The image is otherwise the one `make image` produced -- the same image the
# cluster test and a real node would boot -- so what is under test here is the
# node's own bring-up in cmd/uinit and not a harness-shaped variant of it.
(cd "$WORK/root" && find . | cpio -o -H newc -R 0:0 2>/dev/null) > "$WORK/override.cpio"
cat "$IMAGE" "$WORK/override.cpio" > "$WORK/initramfs.cpio"

echo "booting $KERNEL with $IMAGE (timeout ${K4S_BOOT_TIMEOUT}s)"

# tsc=unstable is not optional on this host: the guest's TSC is skewed under KVM,
# the kernel marks it unstable partway through the boot, and the console wedges at
# that moment. It is a property of the test VM, not of the node, so it belongs
# here and not in configs/ or in uinit.
#
# -serial file: rather than -nographic, so the console is a diagnostic record and
# nothing depends on the guest's stdin. tsc=unstable above is what makes the boot
# itself reliable; this is what makes a failure readable.
rc=0
timeout "$K4S_BOOT_TIMEOUT" qemu-system-x86_64 \
	-M q35 -m 1024 -smp 2 "${ACCEL[@]}" \
	-netdev user,id=n0,hostfwd=tcp:127.0.0.1:$K4S_BOOT_SSH_PORT-:2022 \
	-device virtio-net-pci,netdev=n0 \
	-kernel "$KERNEL" -initrd "$WORK/initramfs.cpio" \
	-append "console=ttyS0,115200 panic=-1 cgroup_no_v1=all tsc=unstable" \
	-serial "file:$LOG" -display none -no-reboot &
qpid=$!

# sshd is uinit's, and it starts in the node's first seconds, so waiting for it is
# also waiting for uinit to have run. Poll rather than sleep a budget: a boot that
# is ready in six seconds should not cost two minutes.
#
# A connect to a guest whose sshd has not started yet succeeds -- QEMU's user-mode
# networking accepts the connection before anything is listening -- and then ssh
# waits for a banner that never comes. ConnectTimeout, not a longer sleep, is what
# handles that.
#
# The timeout is an argument, not a constant: the readiness probe wants seconds,
# and the check below runs a container and wants the whole boot budget. Hard-coding
# it here is what made raising K4S_BOOT_TIMEOUT silently useless.
ssh_do() {
	timeout "$1" ssh -o LogLevel=ERROR -o StrictHostKeyChecking=no \
		-o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
		-i "$WORK/client" -p "$K4S_BOOT_SSH_PORT" root@127.0.0.1 "${@:2}"
}

deadline=$((SECONDS + K4S_BOOT_TIMEOUT))
until ssh_do 8 true >/dev/null 2>&1; do
	if [ "$SECONDS" -ge "$deadline" ] || ! kill -0 "$qpid" 2>/dev/null; then
		[ "$rc" = 0 ] && rc=124
		break
	fi
	sleep 1
done

# The script runs as the remote command's stdin, with gosh on the other end of
# it. sshd runs its shell as `<shell> -c <command>`, and gosh's shell is
# /bin/sh, so the command is `/bin/sh`: the outer gosh runs the inner one, which
# with no command of its own reads stdin as a script. `sh -s` looked right and is
# not -- gosh has no -s, so it errored out and printed bb's applet list.
#
# Its own budget, not the probe's: this mounts filesystems, runs `ctr version` and
# runs a container, and on TCG without /dev/kvm that is not an 8-second exercise.
ssh_do "$K4S_BOOT_TIMEOUT" '/bin/sh' < "$CHECK" > "$WORK/out" 2>&1 || rc=$?

kill "$qpid" 2>/dev/null || true
wait "$qpid" 2>/dev/null || true

echo "--- guest output (tail) ---"
tail -40 "$WORK/out"
if [ -s "$WORK/out" ]; then
	echo "--- console (tail) ---"
	tail -15 "$LOG"
fi
echo "---------------------------"

if ! grep -qx 'K4S_CHECK_START' "$WORK/out" || ! grep -qx 'K4S_CHECK_END' "$WORK/out"; then
	echo "boot: FAILED (the check did not run to completion; ssh rc=$rc, log $LOG)" >&2
	echo "last console lines:" >&2
	tail -20 "$LOG" >&2
	exit 1
fi
echo "boot: ok"

if grep -qE '^K4S_CHECK:.*: fail' "$WORK/out"; then
	echo "capabilities: FAILED" >&2
	grep -aE '^K4S_CHECK:.*: fail' "$WORK/out" >&2
	exit 1
fi
echo "capabilities: ok"

# The container's own output is the proof it actually ran.
if ! grep -qx 'K4S_CONTAINER_OK' "$WORK/out"; then
	echo "container: FAILED (marker not seen)" >&2
	exit 1
fi
echo "container: ok"
