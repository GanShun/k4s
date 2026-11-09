#!/bin/bash
#
# Shared QEMU-and-ssh scaffolding for the two boot tests.
#
# test-boot.sh (capability check) and test-runc.sh (runc's own root-only suite)
# differ only in what they run once the guest is up; everything before that — the
# throwaway key spliced into the image, the QEMU command line, waiting for sshd,
# tearing the VM down — is identical, and was duplicated once already.
#
# Sourced, not executed. The caller must have set `set -Eeuo pipefail` and an ERR
# trap; the functions here do not impose either.
#
# Usage:
#   kb_init <kernel> <image>
#   kb_inject <dir>              # optional, repeatable: contents land at / in the guest
#   kb_start
#   kb_wait || ...
#   kb_ssh <seconds> <args...>
#   kb_stop
#
# Env: K4S_BOOT_TIMEOUT   seconds to wait for sshd, i.e. for the boot (default 180)
#      K4S_CMD_TIMEOUT    seconds to allow the guest command (default: the boot
#                         timeout); a command that runs a container or a test
#                         package needs its own, larger budget
#      K4S_BOOT_SSH_PORT  host port forwarded to the node's sshd (default 2223)

kb_init() {
	KB_KERNEL=${1:?kb_init: kernel}
	KB_IMAGE=${2:?kb_init: initramfs}

	K4S_BOOT_TIMEOUT=${K4S_BOOT_TIMEOUT:-180}
	K4S_CMD_TIMEOUT=${K4S_CMD_TIMEOUT:-$K4S_BOOT_TIMEOUT}
	# QEMU's own lifetime has to outlast both budgets, or the VM is killed while
	# the guest is still working and the failure looks like the guest's. The slack
	# covers QEMU's own startup and teardown.
	KB_VM_TIMEOUT=$((K4S_BOOT_TIMEOUT + K4S_CMD_TIMEOUT + 30))
	# Not K4S_SSH_PORT: the cluster harness owns that name and its default, and the
	# two harnesses would otherwise collide if anyone ever ran them concurrently.
	K4S_BOOT_SSH_PORT=${K4S_BOOT_SSH_PORT:-2223}

	KB_LOG=$(mktemp -t k4s-boot.XXXXXX.log)
	KB_WORK=$(mktemp -d -t k4s-boot.XXXXXX)
	KB_QPID=

	KB_ACCEL=()
	if [ -w /dev/kvm ]; then
		KB_ACCEL=(-enable-kvm -cpu host)
	else
		echo "note: /dev/kvm not writable; falling back to TCG (slow)" >&2
	fi

	# A throwaway key pair, never committed and valid only for this VM on a
	# loopback port. The node image itself carries no key.
	mkdir -p "$KB_WORK/root/etc/ssh"
	ssh-keygen -q -t rsa -b 2048 -N '' -f "$KB_WORK/host_rsa"
	ssh-keygen -q -t rsa -b 2048 -N '' -f "$KB_WORK/client"
	cp "$KB_WORK/client.pub" "$KB_WORK/root/etc/ssh/authorized_keys"
	cp "$KB_WORK/host_rsa" "$KB_WORK/root/etc/ssh/host_rsa"
}

# kb_inject copies a directory tree into the guest's filesystem. Paths are
# preserved relative to that directory, so `kb_inject $d` with $d/tmp/k4s/x puts
# the file at /tmp/k4s/x.
#
# This is how a test binary gets in at all. There is no file transfer to lean on:
# the guest's sshd is u-root's, sftp is not in the image, and scp is only its
# minimal counterpart. Splicing into the initramfs uses the mechanism already
# needed for the keys, and costs nothing at boot.
kb_inject() {
	local dir=${1:?kb_inject: directory}
	[ -d "$dir" ] || { echo "kb_inject: $dir is not a directory" >&2; return 1; }
	cp -a "$dir/." "$KB_WORK/root/"
}

# kb_stop kills the VM. It does not touch the work directory: the caller reads the
# guest's output out of there once the VM is gone, and deleting it here is how a
# harness loses the only record of what went wrong. kb_cleanup does that, from the
# EXIT trap.
#
# Both are safe to call more than once.
kb_stop() {
	if [ -n "${KB_QPID:-}" ]; then
		kill "$KB_QPID" 2>/dev/null || true
		wait "$KB_QPID" 2>/dev/null || true
		KB_QPID=
	fi
}

kb_cleanup() {
	kb_stop
	if [ -n "${KB_WORK:-}" ]; then
		rm -rf "$KB_WORK"
	fi
	echo "guest log: ${KB_LOG:-none}"
}

kb_start() {
	# Splice the keys and anything injected in by appending a small cpio to the
	# image rather than repacking it: the kernel unpacks an initramfs in order and a
	# later entry replaces an earlier one, so this is both cheaper and harder to get
	# wrong than rewriting 228 MB.
	#
	# The image is otherwise the one `make image` produced -- the same image the
	# cluster test and a real node would boot -- so what is under test is the node's
	# own bring-up in cmd/uinit and not a harness-shaped variant of it.
	(cd "$KB_WORK/root" && find . | cpio -o -H newc -R 0:0 2>/dev/null) > "$KB_WORK/override.cpio"
	cat "$KB_IMAGE" "$KB_WORK/override.cpio" > "$KB_WORK/initramfs.cpio"

	echo "booting $KB_KERNEL with $KB_IMAGE (boot ${K4S_BOOT_TIMEOUT}s, command ${K4S_CMD_TIMEOUT}s)" >&2

	# tsc=unstable is not optional on this host: the guest's TSC is skewed under
	# KVM, the kernel marks it unstable partway through the boot, and the console
	# wedges at that moment. It is a property of the test VM, not of the node, so it
	# belongs here and not in configs/ or in uinit.
	#
	# -serial file: rather than -nographic, so the console is a diagnostic record
	# and nothing depends on the guest's stdin. tsc=unstable above is what makes the
	# boot itself reliable; this is what makes a failure readable.
	#
	# -no-reboot, and no -no-shutdown: a guest that panics must exit rather than
	# hang, because every wait here is bounded by a deadline that a wedged QEMU
	# would otherwise outlive.
	timeout "$KB_VM_TIMEOUT" qemu-system-x86_64 \
		-M q35 -m "${KB_MEM:-1024}" -smp 2 "${KB_ACCEL[@]}" \
		-netdev user,id=n0,hostfwd=tcp:127.0.0.1:$K4S_BOOT_SSH_PORT-:2022 \
		-device virtio-net-pci,netdev=n0 \
		-kernel "$KB_KERNEL" -initrd "$KB_WORK/initramfs.cpio" \
		-append "console=ttyS0,115200 panic=-1 cgroup_no_v1=all tsc=unstable" \
		-serial "file:$KB_LOG" -display none -no-reboot &
	KB_QPID=$!
}

# kb_ssh runs a command in the guest. The first argument is a per-call timeout,
# not the boot budget: a readiness probe wants seconds, and a check that runs a
# container or a whole test package wants the whole thing.
#
# A connect to a guest whose sshd has not started yet succeeds -- QEMU's user-mode
# networking accepts the connection before anything is listening -- and then ssh
# waits for a banner that never comes. ConnectTimeout, not a longer sleep, is what
# handles that.
kb_ssh() {
	local budget=$1
	shift
	timeout "$budget" ssh -o LogLevel=ERROR -o StrictHostKeyChecking=no \
		-o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
		-i "$KB_WORK/client" -p "$K4S_BOOT_SSH_PORT" root@127.0.0.1 "$@"
}

# kb_wait polls for sshd, which uinit starts in the node's first seconds, so
# waiting for it is also waiting for uinit to have run. Polls rather than sleeps a
# budget: a boot that is ready in six seconds should not cost two minutes.
kb_wait() {
	local deadline=$((SECONDS + K4S_BOOT_TIMEOUT))
	# </dev/null because u-root's sshd ends a non-PTY session only when the
	# client's stdin reaches EOF, and exec.Cmd.Run waits for that copy: a probe that
	# inherits a terminal runs true, exits, and still holds the session until the
	# timeout kills it. It cannot be -n inside kb_ssh, because test-boot.sh feeds the
	# check script to the guest on stdin.
	until kb_ssh 8 true </dev/null >/dev/null 2>&1; do
		if [ "$SECONDS" -ge "$deadline" ] || ! kill -0 "$KB_QPID" 2>/dev/null; then
			return 1
		fi
		sleep 1
	done
}

# kb_die prints the console, which is the only record of a guest that did not come
# up far enough to say anything itself.
kb_die() {
	echo "$*" >&2
	echo "--- console (tail) ---" >&2
	tail -30 "${KB_LOG:-/dev/null}" >&2 2>/dev/null || true
	return 1
}
