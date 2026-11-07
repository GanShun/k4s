#!/bin/bash
#
# Run runc's root-only test suite inside a booted k4s node.
#
# `libcontainer/integration` is the suite that checks the fork's claims against a
# real container: namespaces, cgroups, mounts, seccomp, exec. It needs root, and
# the shared CI runner does not have it -- `libcontainer-integration` in runc's
# .gitlab-ci.yml probes for CAP_SYS_ADMIN first and reports that it is missing
# (runc issue #4). The k4s node boots as root with CAP_SYS_ADMIN, which makes it
# the one place this suite can run at all.
#
# What the suite needs that the image does not give it, and what this provides:
#
#   - the test binary itself: cross-compiled here, injected into the initramfs;
#   - a `tar` that understands "-C", "--exclude" and a compressed archive: the
#     suite extracts its rootfs with one, and u-root's tar applet has none of the
#     three. scripts/guesttar.go is built for that and put first in PATH;
# Everything injected lands under /k4s, not /tmp: u-root's init mounts a tmpfs
# over /tmp while bringing the node up, so a file the initramfs placed there is
# hidden by the time anything can read it. /k4s is mounted over by nothing.
#
#   - the busybox rootfs fixture: injected at the path the binary has compiled in,
#     which is why the inject directory mirrors this checkout's absolute path;
#   - tests/integration/get-images.sh, which the suite runs at init. The real one
#     is bash and calls `go env` and curl; the guest has gosh, no Go and no
#     network. A stub that prints the fixture path it was given replaces it.
#
# Usage: test-runc.sh <kernel> <initramfs> [test-run-regex]
#
# Env: RUNC_DIR        the runc checkout (default: this repo's sibling ../runc)
#      K4S_RUNC_TIMEOUT seconds for the suite itself (default 1800)
#      K4S_BOOT_TIMEOUT, K4S_CMD_TIMEOUT, K4S_BOOT_SSH_PORT   see lib/boot.sh;
#                       K4S_RUNC_TIMEOUT sets the command budget unless that is
#                       given explicitly

set -Eeuo pipefail

trap 'echo "test-runc.sh: failed at line $LINENO (exit $?)" >&2' ERR

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/lib/boot.sh
. "$HERE/lib/boot.sh"

KERNEL=${1:?usage: test-runc.sh <kernel> <initramfs> [test-run-regex]}
IMAGE=${2:?usage: test-runc.sh <kernel> <initramfs> [test-run-regex]}
RUN=${3:-.}
RUNC_DIR=${RUNC_DIR:-$HERE/../../runc}
K4S_RUNC_TIMEOUT=${K4S_RUNC_TIMEOUT:-1800}
K4S_CMD_TIMEOUT=${K4S_CMD_TIMEOUT:-$K4S_RUNC_TIMEOUT}

RUNC_DIR=$(cd "$RUNC_DIR" && pwd)
[ -d "$RUNC_DIR/libcontainer/integration" ] || { echo "test-runc.sh: $RUNC_DIR is not a runc checkout" >&2; exit 1; }
FIXTURE=$RUNC_DIR/tests/integration/testdata/busybox-amd64.tar.xz
if [ ! -f "$FIXTURE" ]; then
	# Gitignored upstream: a fresh clone has no rootfs, and the script that fetches
	# it is bash calling curl, which is fine here and not in the guest.
	echo "fetching the rootfs fixture (not in a fresh checkout)"
	"$RUNC_DIR/tests/integration/get-images.sh" >/dev/null || {
		echo "test-runc.sh: could not fetch $FIXTURE; run $RUNC_DIR/tests/integration/get-images.sh" >&2
		exit 1
	}
fi
[ -f "$FIXTURE" ] || { echo "test-runc.sh: missing fixture $FIXTURE" >&2; exit 1; }

# The guest's full output goes here and is kept: the tail is enough to see that
# something failed, and useless for finding out why.
KB_OUT=$(mktemp -t k4s-runc.XXXXXX.log)

kb_init "$KERNEL" "$IMAGE"
# The work directory holds the guest's output, so it is removed only on the way
# out, after the output has been read.
trap 'rc=$?; kb_cleanup; exit $rc' EXIT

PUSH=$KB_WORK/push
mkdir -p "$PUSH/k4s/bin" \
	"$PUSH$RUNC_DIR/tests/integration/testdata" \
	"$PUSH/k4s/work"

echo "building the suite from $RUNC_DIR"
# CGO_ENABLED=0 is the build under test. The test binary is cross-compiled here
# rather than in the guest because the image has no toolchain, which also means
# its compiled-in source path is this checkout's -- hence the inject tree below.
(cd "$RUNC_DIR" && GOWORK=off CGO_ENABLED=0 go test -c -o "$PUSH/k4s/integration.test" ./libcontainer/integration)

echo "building the guest tar"
# CGO_ENABLED=0 is not optional: the guest has no libc and no dynamic loader, so a
# dynamically linked binary fails at execve with ENOENT -- which reads as "the file
# is missing" and is not.
CGO_ENABLED=0 GOWORK=off GO111MODULE=off go build -o "$PUSH/k4s/bin/tar" "$HERE/guesttar.go"
# The same binary, under the name the suite's helper shell needs. See the shell
# function in guesttar.go for why /bin/sh cannot do this job in this image.
cp "$PUSH/k4s/bin/tar" "$PUSH/k4s/bin/sh"

# The fixture keeps its name; it is gzip despite the .tar.xz name, and guesttar
# sniffs the compression rather than trusting either.
cp "$FIXTURE" "$PUSH$RUNC_DIR/tests/integration/testdata/"

# The stub, at the path the test binary calls. It prints what the real one prints
# for the image that is actually here, and nothing else.
cat > "$PUSH$RUNC_DIR/tests/integration/get-images.sh" <<STUB
#!/bin/sh
# Written by scripts/test-runc.sh. The real script is bash, runs "go env" and
# curls a rootfs; none of that exists in this guest. The fixture is already here.
echo "BUSYBOX_IMAGE=$RUNC_DIR/tests/integration/testdata/busybox-amd64.tar.xz"
STUB
chmod +x "$PUSH$RUNC_DIR/tests/integration/get-images.sh"

# The guest's script. One complete command per line: gosh reads a script a line at
# a time, so no continuations and no multi-line blocks. Written here rather than
# committed because every value in it is a decision this script just made.
# The heredoc below is unquoted so that the selector can be interpolated, which
# means anything with a $ in it is expanded here and not in the guest. The Go test
# timeout is therefore computed here, with a floor: the suite should report its own
# timeout before ssh gives up, and a budget of a minute or less would otherwise
# produce a negative one.
if [ "$K4S_CMD_TIMEOUT" -gt 120 ]; then
	TEST_TIMEOUT=$((K4S_CMD_TIMEOUT - 60))
else
	TEST_TIMEOUT=60
fi

cat > "$PUSH/k4s/run.sh" <<GUEST
#!/bin/sh
echo K4S_RUNC_START
export PATH=/k4s/bin:/bbin:/bin:/usr/bin
cd /k4s/work
# The exit status, not the PASS/FAIL lines, is the verdict: a timeout panics
# without printing "--- FAIL:" for the test that was running, and a panic in
# init or an os.Exit from a helper never reaches the testing package at all.
# Both would otherwise read as success whenever an earlier test passed.
/k4s/integration.test -test.v -test.timeout ${TEST_TIMEOUT}s -test.run '$RUN'
echo K4S_RUNC_RC=\$?
echo K4S_RUNC_END
GUEST
chmod +x "$PUSH/k4s/run.sh"
# The heredoc above is unquoted, so $? would be expanded here -- into the status of
# whatever ran last, which is 0 -- and the verdict could never fail. Check the file
# that was actually written rather than trusting the escaping.
if ! grep -q 'K4S_RUNC_RC=\$?' "$PUSH/k4s/run.sh"; then
	echo "test-runc.sh: the generated run.sh lost its literal \$?, so the exit-status verdict is dead:" >&2
	sed 's/^/    /' "$PUSH/k4s/run.sh" >&2
	exit 1
fi

kb_inject "$PUSH"

kb_start
kb_wait || { echo "boot: FAILED (sshd never answered)" >&2; exit 1; }

echo "running the suite in the guest (timeout ${K4S_CMD_TIMEOUT}s)"
rc=0
kb_ssh "$K4S_CMD_TIMEOUT" '/k4s/run.sh' > "$KB_WORK/out" 2>&1 || rc=$?

kb_stop
cp "$KB_WORK/out" "$KB_OUT"

echo "--- guest output (tail) ---"
tail -30 "$KB_OUT"
echo "--- the failures, without the cgroup-device noise ---"
# One awk, not a pipeline into head: under pipefail a grep that matches nothing
# exits 1 and kills the script on a run where every selected test passed, and a
# head that exits early gives its writer SIGPIPE. awk exits 0 either way, and
# stops itself at 80 lines.
awk '/_test\.go:[0-9]+:|--- (FAIL|SKIP):/ && !/^time=/ {print; if (++n >= 80) exit}' "$KB_OUT"
echo "---------------------------"
echo "full guest output: $KB_OUT"

FAILED=0
if ! grep -qx 'K4S_RUNC_START' "$KB_OUT" || ! grep -qx 'K4S_RUNC_END' "$KB_OUT"; then
	echo "runc-integration: FAILED (the run did not complete; ssh rc=$rc, log $KB_LOG)" >&2
	tail -20 "$KB_LOG" >&2
	exit 1
fi

# A test that never ran and a test that failed are different failures, and the
# suite's own summary line hides which. Name both.
mapfile -t PASSED < <(sed -n 's/^--- PASS: \([A-Za-z0-9_/]*\).*/\1/p' "$KB_WORK/out")
mapfile -t FAILED_TESTS < <(sed -n 's/^--- FAIL: \([A-Za-z0-9_/]*\).*/\1/p' "$KB_WORK/out")
mapfile -t SKIPPED < <(sed -n 's/^--- SKIP: \([A-Za-z0-9_/]*\).*/\1/p' "$KB_WORK/out")

echo "passed: ${#PASSED[@]}  failed: ${#FAILED_TESTS[@]}  skipped: ${#SKIPPED[@]}"
if [ "${#FAILED_TESTS[@]}" -gt 0 ]; then
	printf '  FAIL %s\n' "${FAILED_TESTS[@]}"
	FAILED=1
fi
if [ "${#SKIPPED[@]}" -gt 0 ]; then
	printf '  SKIP %s\n' "${SKIPPED[@]}"
fi
if [ "${#PASSED[@]}" -eq 0 ] && [ "${#FAILED_TESTS[@]}" -eq 0 ]; then
	echo "runc-integration: FAILED (no test reported a result for -test.run '$RUN')" >&2
	exit 1
fi

# The binary's own status, because the lists above cannot see a timeout or a
# panic: neither prints "--- FAIL:" for the test that was running.
if ! grep -qx 'K4S_RUNC_RC=0' "$KB_OUT"; then
	echo "runc-integration: FAILED (the suite exited $(sed -n 's/^K4S_RUNC_RC=//p' "$KB_OUT" | head -1); ssh rc=$rc)" >&2
	exit 1
fi

if [ "$FAILED" != 0 ]; then
	echo "runc-integration: FAILED"
	exit 1
fi
echo "runc-integration: ok"
