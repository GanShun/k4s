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
mkdir -p /run/containerd /var/lib/containerd /var/lib/kubelet /var/log/pods /var/log/k4s-smoke /var/log/k4s-netns /var/log/k4s-ds /var/log/k4s-deploy /var/log/k4s-flannel
mkdir -p /run/flannel
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

# --- flannel ----------------------------------------------------------------
# flanneld runs as a DaemonSet now (configs/node/flannel-ds.yaml, applied by the
# harness once this node has registered), not as a process here. It takes a
# subnet lease for this node out of the kube API and writes it to the host's
# /run/flannel/subnet.env, which is where the CNI plugin -- /opt/cni/bin/flannel,
# run by the runtime on the host -- reads it before delegating to bridge and
# host-local.
#
# So all that is left here is to wait for the DaemonSet to have done its job.
# That is also the ordering the pods need: nothing with a network namespace of
# its own can start before that file exists.
i=0; while [ ! -s /run/flannel/subnet.env ] && [ $i -lt 30 ]; do sleep 2; i=$((i+1)); done
echo "--- flannel subnet.env ---"
cat /run/flannel/subnet.env

# --- wait for the host to create the pod and the container to write ---------
sleep 40
echo "--- marker @40s ---"
tail -n 6 /var/log/k4s-flannel/flannel.log
cat /var/log/k4s-smoke/result
cat /var/log/k4s-netns/result
cat /var/log/k4s-ds/result
cat /var/log/k4s-deploy/result
sleep 40
echo "--- marker @80s ---"
tail -n 6 /var/log/k4s-flannel/flannel.log
cat /var/log/k4s-smoke/result
cat /var/log/k4s-netns/result
cat /var/log/k4s-ds/result
cat /var/log/k4s-deploy/result
sleep 40
echo "--- marker @120s ---"
tail -n 6 /var/log/k4s-flannel/flannel.log
cat /var/log/k4s-smoke/result
cat /var/log/k4s-netns/result
cat /var/log/k4s-ds/result
cat /var/log/k4s-deploy/result

# --- diagnostics ------------------------------------------------------------
echo "--- kubelet log tail ---"
tail -n 30 /tmp/kubelet.log
echo "--- containerd log tail ---"
tail -n 10 /tmp/containerd.log
echo "--- flannel log tail ---"
tail -n 20 /var/log/k4s-flannel/flannel.log

echo "K4S_CHECK_END"
poweroff
