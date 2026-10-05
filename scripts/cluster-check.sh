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
mkdir -p /run/containerd /var/lib/containerd /var/lib/kubelet /var/log/pods /var/log/k4s-smoke /var/log/k4s-netns
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
# flanneld is the daemon half: it takes a lease for this node out of the kube
# API (writing flannel annotations onto the Node object, which is why it needs
# the node to have registered first) and writes the subnet it got to
# /run/flannel/subnet.env. The CNI half, /opt/cni/bin/flannel, is what the CRI
# invokes per pod; it reads that file and delegates to bridge and host-local.
# The network config is the baked /etc/kube-flannel/net-conf.json, host-gw
# because this kernel has no VXLAN.
#
# NODE_NAME is how flanneld is told which node it is when it is not running as a
# pod. Running as a DaemonSet it would take POD_NAME/POD_NAMESPACE from the
# downward API and look the pod up; without any of the three it refuses to start
# ("env variables POD_NAME and POD_NAMESPACE must be set").
# --iptables-forward-rules=false because the image has no iptables binary (u-root
# ships none, and the kernel has no filter table either). It only affects the
# FORWARD rules flanneld would add; the pod network itself does not use it.
# flanneld exits rather than retrying when it cannot register, and it can only
# register once the controller-manager has given this node a spec.podCIDR -- so
# it is restarted until the subnet file appears.
while true; do NODE_NAME=k4s-node-1 flannel --kube-subnet-mgr --kubeconfig-file=/etc/kubernetes/kubeconfig --iface=eth0 --iptables-forward-rules=false </dev/null >>/tmp/flannel.log 2>&1; if [ -s /run/flannel/subnet.env ]; then break; fi; sleep 5; done &
echo "K4S_CHECK: flanneld: started"
i=0; while [ ! -s /run/flannel/subnet.env ] && [ $i -lt 30 ]; do sleep 2; i=$((i+1)); done
echo "--- flannel subnet.env ---"
cat /run/flannel/subnet.env

# --- wait for the host to create the pod and the container to write ---------
sleep 30
echo "--- marker @30s ---"
cat /var/log/k4s-smoke/result
cat /var/log/k4s-netns/result
sleep 25
echo "--- marker @55s ---"
cat /var/log/k4s-smoke/result
cat /var/log/k4s-netns/result
sleep 25
echo "--- marker @80s ---"
cat /var/log/k4s-smoke/result
cat /var/log/k4s-netns/result

# --- diagnostics ------------------------------------------------------------
echo "--- kubelet log tail ---"
tail -n 30 /tmp/kubelet.log
echo "--- containerd log tail ---"
tail -n 10 /tmp/containerd.log
echo "--- flannel log tail ---"
tail -n 15 /tmp/flannel.log

echo "K4S_CHECK_END"
poweroff
