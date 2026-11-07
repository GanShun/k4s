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
# Env: K4S_BOOT_TIMEOUT  seconds to wait for sshd (default 180)
#      K4S_CMD_TIMEOUT   seconds for the check itself (default: the boot timeout)
#      K4S_BOOT_SSH_PORT host port forwarded to the node's sshd (default 2223)
#
# Needs ssh, ssh-keygen and cpio on the host. cpio is what splices the key in.

set -Eeuo pipefail

# Under `set -e` a failing command aborts with its own status and no explanation,
# and an ERR trap is not inherited by shell functions without -E. This script is
# short, but lib/boot.sh's functions run inside it, so the two behave alike.
trap 'echo "test-boot.sh: failed at line $LINENO (exit $?)" >&2' ERR

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/lib/boot.sh
. "$HERE/lib/boot.sh"

KERNEL=${1:?usage: test-boot.sh <kernel> <initramfs> [guest-script]}
IMAGE=${2:?usage: test-boot.sh <kernel> <initramfs> [guest-script]}
CHECK=${3:-$HERE/guest-check.sh}

kb_init "$KERNEL" "$IMAGE"
# The work directory holds the guest's output, so it is removed only on the way
# out, after the output has been read.
trap 'rc=$?; kb_cleanup; exit $rc' EXIT

kb_start
kb_wait || { echo "boot: FAILED (sshd never answered)" >&2; exit 1; }

# The script runs as the remote command's stdin, with gosh on the other end of
# it. sshd runs its shell as `<shell> -c <command>`, and gosh's shell is
# /bin/sh, so the command is `/bin/sh`: the outer gosh runs the inner one, which
# with no command of its own reads stdin as a script. `sh -s` looked right and is
# not -- gosh has no -s, so it errored out and printed bb's applet list.
#
# Its own budget, not the probe's: this mounts filesystems, runs `ctr version` and
# runs a container, and on TCG without /dev/kvm that is not an 8-second exercise.
rc=0
kb_ssh "$K4S_CMD_TIMEOUT" '/bin/sh' < "$CHECK" > "$KB_WORK/out" 2>&1 || rc=$?

kb_stop

echo "--- guest output (tail) ---"
tail -40 "$KB_WORK/out"
if [ -s "$KB_WORK/out" ]; then
	echo "--- console (tail) ---"
	tail -15 "$KB_LOG"
fi
echo "---------------------------"

if ! grep -qx 'K4S_CHECK_START' "$KB_WORK/out" || ! grep -qx 'K4S_CHECK_END' "$KB_WORK/out"; then
	echo "boot: FAILED (the check did not run to completion; ssh rc=$rc, log $KB_LOG)" >&2
	echo "last console lines:" >&2
	tail -20 "$KB_LOG" >&2
	exit 1
fi
echo "boot: ok"

if grep -qE '^K4S_CHECK:.*: fail' "$KB_WORK/out"; then
	echo "capabilities: FAILED" >&2
	grep -aE '^K4S_CHECK:.*: fail' "$KB_WORK/out" >&2
	exit 1
fi
echo "capabilities: ok"

# The container's own output is the proof it actually ran.
if ! grep -qx 'K4S_CONTAINER_OK' "$KB_WORK/out"; then
	echo "container: FAILED (marker not seen)" >&2
	exit 1
fi
echo "container: ok"
