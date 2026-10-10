#!/bin/sh
#
# Capability check run inside the k4s image over ssh, as `/bin/sh` with this file
# on stdin. (`sh -s` was what the harness sent first; gosh has no -s, so it errored
# out and bb printed its applet list instead.)
#
# **Every line has to be a complete command.** gosh reads its stdin a line at a
# time, so no continuations and no multi-line if/for blocks. The *width* half of
# the old rule is retired with the console -- that was the tty dropping characters
# when handed a lot at once, and a pipe does not do that.
#
# uinit has already brought the image up by the time this runs: the network, the
# cgroup2 hierarchy, the tmpfs mounts and containerd are all its work. This used
# to repeat that setup, and starting a second containerd broke the running one --
# containerd removes its socket before it listens, so the second instance
# destroyed the first one's socket and then failed to bind, leaving `ctr version`
# unable to connect at all.
#
# Checking a node that has brought itself up is the better test anyway: it is the
# same bring-up the cluster test uses, rather than a second one that exists only
# here.

echo "K4S_CHECK_START"
echo "K4S_CHECK: kernel: $(cat /proc/version)"

test -r /proc/version && echo "K4S_CHECK: proc: ok" || echo "K4S_CHECK: proc: fail"
test -d /sys/kernel && echo "K4S_CHECK: sysfs: ok" || echo "K4S_CHECK: sysfs: fail"
test -e /dev/null && echo "K4S_CHECK: devtmpfs: ok" || echo "K4S_CHECK: devtmpfs: fail"

mkdir -p /tmp/k4s
mount -t tmpfs tmpfs /tmp/k4s
echo hello > /tmp/k4s/test && echo "K4S_CHECK: tmpfs: ok" || echo "K4S_CHECK: tmpfs: fail"

containerd --version && echo "K4S_CHECK: containerd: ok" || echo "K4S_CHECK: containerd: fail"
coredns -version && echo "K4S_CHECK: coredns: ok" || echo "K4S_CHECK: coredns: fail"

# uinit set the network up, so this only asks whether it worked.
ip -4 addr show dev eth0 | grep -q 'inet ' && echo "K4S_CHECK: net: ok" || echo "K4S_CHECK: net: fail"

# And the cgroup2 hierarchy, which runc needs. u-root's init mounts cgroup2 but
# enables no controllers; uinit is what writes subtree_control.
test -e /sys/fs/cgroup/cgroup.controllers && echo "K4S_CHECK: cgroup2: ok" || echo "K4S_CHECK: cgroup2: fail"

# containerd is uinit's. See the note above about why there is not a second one.
ctr version >/dev/null 2>&1 && echo "K4S_CHECK: ctr: ok" || echo "K4S_CHECK: ctr: fail"

containerd-shim-runc-v2 -v >/dev/null 2>&1 && echo "K4S_CHECK: shim: ok" || echo "K4S_CHECK: shim: fail"
kubelet --version >/dev/null 2>&1 && echo "K4S_CHECK: kubelet: ok" || echo "K4S_CHECK: kubelet: fail"

# No image needed: bb is static, so a copy plus one symlink gives the container
# an /bin/echo.
mkdir -p /run/rootfs/bin
cp /bbin/bb /run/rootfs/bin/bb
ln -s bb /run/rootfs/bin/echo
# `ctr run` failing must not be silent: this script does not run under set -e, so a
# failed container run used to fall through to a cheerful `container: done`. One
# line, because gosh reads its stdin a line at a time and an if/fi block would not
# survive that. The marker is still what proves the container started; this is what
# makes a failure report itself through the same channel as every other check.
ctr run --rm --rootfs /run/rootfs k4stest /bin/echo K4S_CONTAINER_OK </dev/null || echo "K4S_CHECK: container: fail"

echo "K4S_CHECK_END"

# No poweroff: the harness owns the VM's lifetime, and a guest that powers itself
# off while its own ssh session is still draining can truncate the output this
# whole check is read from.
