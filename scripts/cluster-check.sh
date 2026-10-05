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

# Lines in this script have to stay short: the serial console drops characters
# out of long ones, which is how a diagnostic once arrived as `tail -25` and
# reported an empty log that was not. (u-root's `tail` is coredns's applet
# anyway, so `cat` is the safer tool.) The globs are written out inline rather
# than held in a variable, because expansion does not apply to the result of a
# variable expansion: `cat /var/log/pods/*cilium-*/cilium-agent/*.log` printed nothing at all.

# --- network ----------------------------------------------------------------
ip link set eth0 up
dhclient -ipv6=false -timeout 10 eth0
echo "nameserver 10.0.2.3" > /etc/resolv.conf

# --- kernel filesystems -----------------------------------------------------
# Make / a shared mount. A container that mounts something and expects the host
# to see it -- Cilium's mount-bpf-fs initContainer does exactly that with bpffs
# -- needs the mount to propagate, and containerd refuses to even create the
# container while /sys is private: "path \"/sys/fs/bpf\" is mounted on \"/sys\"
# but it is not a shared mount". Every distribution's init makes / shared;
# u-root's does not, so the node does it here.
#
# Two details, both of which fail quietly or confusingly: no `remount`, because
# the kernel checks MS_REMOUNT before the propagation flags, so `remount,shared`
# would do nothing at all; and `-t none`, because without a type u-root's mount
# tries to open the source as a block device ("open none: no such file or
# directory") instead of calling mount(2) with the flags.
mount -t none -o shared,rec none /
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
# Whichever CNI is in use: flannel writes a subnet file that its plugin reads,
# Cilium writes its own CNI config and the agent installs the plugin. Wait for
# either, because nothing with a network namespace of its own can start before
# one of them exists.
i=0; while [ ! -s /run/flannel/subnet.env ] && [ ! -e /etc/cni/net.d/05-cilium.conflist ] && [ $i -lt 60 ]; do sleep 2; i=$((i+1)); done
echo "--- cni state ---"
cat /run/flannel/subnet.env
ls /etc/cni/net.d

# --- wait for the host to create the pod and the container to write ---------
# Four looks at the same files, a minute apart, rather than one at the end:
# when a check fails the harness kills this VM, so anything printed only at
# the end is lost exactly when it is wanted. The CNI logs come with them.
sleep 60
echo "--- marker @60s ---"
cat /var/log/k4s-smoke/result
cat /var/log/k4s-netns/result
cat /var/log/k4s-ds/result
cat /var/log/k4s-deploy/result
cat /var/log/k4s-flannel/flannel.log
cat /var/log/pods/*cilium-*/cilium-agent/*.log
sleep 60
echo "--- marker @120s ---"
cat /var/log/k4s-smoke/result
cat /var/log/k4s-netns/result
cat /var/log/k4s-ds/result
cat /var/log/k4s-deploy/result
cat /var/log/k4s-flannel/flannel.log
cat /var/log/pods/*cilium-*/cilium-agent/*.log
sleep 60
echo "--- marker @180s ---"
cat /var/log/k4s-smoke/result
cat /var/log/k4s-netns/result
cat /var/log/k4s-ds/result
cat /var/log/k4s-deploy/result
cat /var/log/k4s-flannel/flannel.log
cat /var/log/pods/*cilium-*/cilium-agent/*.log
sleep 60
echo "--- marker @240s ---"
cat /var/log/k4s-smoke/result
cat /var/log/k4s-netns/result
cat /var/log/k4s-ds/result
cat /var/log/k4s-deploy/result
cat /var/log/k4s-flannel/flannel.log
cat /var/log/pods/*cilium-*/cilium-agent/*.log

# --- diagnostics ------------------------------------------------------------
echo "--- kubelet log tail ---"
tail -n 30 /tmp/kubelet.log
echo "--- containerd tail ---"
tail -n 10 /tmp/containerd.log
echo "--- containerd, cilium ---"
grep cilium /tmp/containerd.log
echo "--- flannel log ---"
cat /var/log/k4s-flannel/flannel.log
echo "--- agent log ---"
ls /var/log/pods
ls /var/log/pods/*cilium*/
cat /var/log/pods/*cilium-*/cilium-agent/*.log
echo "--- envoy log ---"
cat /var/log/pods/*cilium-envoy-*/*/*.log

echo "K4S_CHECK_END"
poweroff
