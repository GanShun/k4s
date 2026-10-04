#!/bin/sh
#
# Capability check run inside the k4s initramfs over the serial console.
#
# gosh executes this from stdin, so keep it POSIX and simple. Each line prints
# a "K4S_CHECK: <name>: ok|fail" marker; test-boot.sh greps for these.

echo "K4S_CHECK_START"
echo "K4S_CHECK: cmdline: $(cat /proc/cmdline)"
echo "K4S_CHECK: kernel: $(cat /proc/version)"

if [ -r /proc/version ]; then echo "K4S_CHECK: proc: ok"; else echo "K4S_CHECK: proc: fail"; fi
if [ -d /sys/kernel ]; then echo "K4S_CHECK: sysfs: ok"; else echo "K4S_CHECK: sysfs: fail"; fi
if [ -e /dev/null ]; then echo "K4S_CHECK: devtmpfs: ok"; else echo "K4S_CHECK: devtmpfs: fail"; fi

if mount -t tmpfs tmpfs /tmp; then echo "K4S_CHECK: tmpfs: ok"; else echo "K4S_CHECK: tmpfs: fail"; fi
if echo hello > /tmp/k4s-test; then echo "K4S_CHECK: tmpfs-write: ok"; else echo "K4S_CHECK: tmpfs-write: fail"; fi

if containerd --version; then echo "K4S_CHECK: containerd: ok"; else echo "K4S_CHECK: containerd: fail"; fi
if coredns -version; then echo "K4S_CHECK: coredns: ok"; else echo "K4S_CHECK: coredns: fail"; fi
if ip link; then echo "K4S_CHECK: net: ok"; else echo "K4S_CHECK: net: fail"; fi

echo "K4S_CHECK_END"
poweroff
