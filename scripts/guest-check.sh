#!/bin/sh
#
# Capability check, run inside the k4s initramfs over the serial console.
#
# This only checks. The node brings itself up before this runs -- mounts,
# cgroup2, containerd, and so on, from configs/node/uinit.sh via u-root's init
# -- so there is nothing to set up here, and setting any of it up twice would
# fail: a second mount of cgroup2, a second containerd fighting for the socket.
#
# The guest console is a tty, so u-root's gosh runs interactively and executes
# this one line at a time. Every line must be a complete command: no multi-line
# if/for blocks, and keep lines short enough not to wrap.

echo "K4S_CHECK_START"
echo "K4S_CHECK: kernel: $(cat /proc/version)"

test -r /proc/version && echo "K4S_CHECK: proc: ok" || echo "K4S_CHECK: proc: fail"
test -d /sys/kernel && echo "K4S_CHECK: sysfs: ok" || echo "K4S_CHECK: sysfs: fail"
test -e /dev/null && echo "K4S_CHECK: devtmpfs: ok" || echo "K4S_CHECK: devtmpfs: fail"

# A tmpfs this script mounts itself, rather than one uinit already mounted: the
# point is that the kernel can do it at all.
mkdir -p /tmp/k4s
mount -t tmpfs tmpfs /tmp/k4s
echo hello > /tmp/k4s/test && echo "K4S_CHECK: tmpfs: ok" || echo "K4S_CHECK: tmpfs: fail"

containerd --version && echo "K4S_CHECK: containerd: ok" || echo "K4S_CHECK: containerd: fail"
coredns -version && echo "K4S_CHECK: coredns: ok" || echo "K4S_CHECK: coredns: fail"

# The network was configured by uinit; this checks that it worked.
ip -4 addr show dev eth0 | grep -q 'inet ' && echo "K4S_CHECK: net: ok" || echo "K4S_CHECK: net: fail"

# runc and containerd want a cgroup2 hierarchy, which uinit mounted.
test -e /sys/fs/cgroup/cgroup.controllers && echo "K4S_CHECK: cgroup2: ok" || echo "K4S_CHECK: cgroup2: fail"

# containerd is running because uinit started it and waited for its socket, so
# this fails if that did not happen rather than papering over it.
ctr version >/dev/null 2>&1 && echo "K4S_CHECK: ctr: ok" || echo "K4S_CHECK: ctr: fail"

containerd-shim-runc-v2 -v >/dev/null 2>&1 && echo "K4S_CHECK: shim: ok" || echo "K4S_CHECK: shim: fail"
kubelet --version >/dev/null 2>&1 && echo "K4S_CHECK: kubelet: ok" || echo "K4S_CHECK: kubelet: fail"

# No image needed: bb is static, so a copy plus one symlink gives the
# container an /bin/echo.
mkdir -p /run/rootfs/bin
cp /bbin/bb /run/rootfs/bin/bb
ln -s bb /run/rootfs/bin/echo
ctr run --rm --rootfs /run/rootfs k4stest /bin/echo K4S_CONTAINER_OK </dev/null
echo "K4S_CHECK: container: done"

echo "--- containerd log tail ---"
tail -n 30 /tmp/containerd.log

echo "K4S_CHECK_END"
poweroff
