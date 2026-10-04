#!/bin/sh
#
# Capability check run inside the k4s initramfs over the serial console.
#
# The guest console is a tty, so u-root's gosh runs interactively and executes
# this one line at a time. Every line must be a complete command: no multi-line
# if/for blocks, and keep lines short enough not to wrap.

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
ip link >/dev/null && echo "K4S_CHECK: net: ok" || echo "K4S_CHECK: net: fail"

# runc and containerd want a cgroup2 hierarchy; u-root's init leaves none.
mkdir -p /sys/fs/cgroup
mount -t cgroup2 none /sys/fs/cgroup
test -e /sys/fs/cgroup/cgroup.controllers && echo "K4S_CHECK: cgroup2: ok" || echo "K4S_CHECK: cgroup2: fail"

# containerd's state wants a writable, xattr-capable filesystem; ramfs is not.
mkdir -p /var/lib/containerd /run/containerd
mount -t tmpfs tmpfs /var/lib/containerd
containerd </dev/null >/tmp/containerd.log 2>&1 &
sleep 5
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
