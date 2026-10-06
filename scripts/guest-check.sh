#!/bin/sh
#
# Capability check run inside the k4s image over the serial console.
#
# The guest console is a tty, so u-root's gosh runs interactively and executes
# this one line at a time. Every line must be a complete command: no multi-line
# if/for blocks, and keep lines short enough not to wrap.
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
ctr run --rm --rootfs /run/rootfs k4stest /bin/echo K4S_CONTAINER_OK </dev/null
echo "K4S_CHECK: container: done"

echo "K4S_CHECK_END"
poweroff
