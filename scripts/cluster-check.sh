#!/bin/sh
#
# Guest side of the M1 join test, piped into the initramfs shell.
#
# The console is a tty and u-root's gosh runs this one line at a time, so every
# line must be a complete command: no multi-line blocks and no backslash
# continuations. Fixed sleeps stand in for a poll loop.
#
# The kubeconfig at /etc/kubernetes/kubeconfig is spliced in by
# scripts/test-cluster.sh, which issues it from the throwaway CA.

echo "K4S_CHECK_START"

# --- network ----------------------------------------------------------------
ip link set eth0 up
dhclient -ipv6=false -timeout 10 eth0
echo "nameserver 10.0.2.3" > /etc/resolv.conf

# --- kernel filesystems -----------------------------------------------------
mkdir -p /sys/fs/cgroup
mount -t cgroup2 none /sys/fs/cgroup
# cgroup v2 only exposes a controller in child cgroups if the parent lists it
# in subtree_control. u-root's init mounts cgroup2 but never enables any, so
# runc fails creating the pod cgroup with ".../cpu.max: no such file or
# directory". One echo per controller: a single write is all-or-nothing, so one
# unavailable controller would leave the root with none enabled.
echo "+cpu" > /sys/fs/cgroup/cgroup.subtree_control
echo "+cpuset" > /sys/fs/cgroup/cgroup.subtree_control
echo "+memory" > /sys/fs/cgroup/cgroup.subtree_control
echo "+pids" > /sys/fs/cgroup/cgroup.subtree_control
echo "+io" > /sys/fs/cgroup/cgroup.subtree_control

# No disk: everything the runtime and kubelet write is RAM.
mkdir -p /run/containerd /var/lib/containerd /var/lib/kubelet /var/log/pods /var/log/k4s-smoke
mount -t tmpfs tmpfs /var/lib/containerd
mount -t tmpfs tmpfs /var/lib/kubelet
mount -t tmpfs tmpfs /var/log/pods

# --- containerd -------------------------------------------------------------
containerd </dev/null >/tmp/containerd.log 2>&1 &
sleep 6
ctr version >/dev/null 2>&1 && echo "K4S_CHECK: ctr: ok" || echo "K4S_CHECK: ctr: fail"

# --- kubelet ----------------------------------------------------------------
# One line on purpose: gosh does not join backslash continuations. root-dir and
# cert-dir already default under /var/lib/kubelet, which is the tmpfs above.
kubelet --config=/etc/kubernetes/kubelet.yaml --kubeconfig=/etc/kubernetes/kubeconfig --hostname-override=k4s-node-1 </dev/null >/tmp/kubelet.log 2>&1 &
echo "K4S_CHECK: kubelet: started"

# --- wait for the host to create the pod and the container to write ---------
sleep 30
echo "--- marker @30s ---"
cat /var/log/k4s-smoke/result
sleep 25
echo "--- marker @55s ---"
cat /var/log/k4s-smoke/result
sleep 25
echo "--- marker @80s ---"
cat /var/log/k4s-smoke/result

# --- diagnostics ------------------------------------------------------------
echo "--- kubelet log tail ---"
tail -n 30 /tmp/kubelet.log
echo "--- containerd log tail ---"
tail -n 10 /tmp/containerd.log

echo "K4S_CHECK_END"
poweroff
