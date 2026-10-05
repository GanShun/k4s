#!/bin/sh
#
# The node's bring-up, run by u-root's init as /bin/uinit.
#
# init runs /inito, /bbin/uinit, /bin/uinit, /buildbin/uinit, /bin/defaultsh and
# /bin/sh in sequence, waiting for each to exit. So starting the daemons in the
# background and returning is what leaves the console at a shell afterwards, and
# what tells the rest of the boot that the node is up.
#
# This is a file in the image rather than a script fed to the shell over the
# serial console, which is how it used to work and which cost a great deal of
# time: the console drops characters when handed a lot at once, so the script
# arrived corrupted and the guest stopped partway through with no error, and
# every log that was supposed to follow was simply never reached. A file cannot
# be corrupted in transit. The only constraint left is gosh's, which reads this
# one line at a time: every line must be a complete command, so no multi-line
# blocks and no backslash continuations.
#
# The kubeconfig at /etc/kubernetes/kubeconfig and the ssh keys at /etc/ssh are
# spliced into the image by scripts/test-cluster.sh, which issues them from the
# throwaway CA.

echo "K4S_INIT: start"

# --- network ----------------------------------------------------------------
ip link set eth0 up
dhclient -ipv6=false -timeout 10 eth0
echo "nameserver 10.0.2.3" > /etc/resolv.conf

# --- sshd -------------------------------------------------------------------
# So the harness can read files out of this node directly. Scraping them off the
# serial console is what made every diagnostic in this project slow and
# unreliable: a log has to be printed at exactly the right moment to be caught,
# and catting one to a 115200-baud line takes minutes.
sshd -keys /etc/ssh/authorized_keys -privatekey /etc/ssh/host_rsa >/tmp/sshd.log 2>&1 &
echo "K4S_INIT: sshd"

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

# cgroup v2 only exposes a controller in child cgroups if the parent lists it in
# subtree_control. u-root's init mounts cgroup2 but never enables any, so runc
# fails creating the pod cgroup with ".../cpu.max: no such file or directory".
# One echo per controller: a single write is all-or-nothing, so one unavailable
# controller would leave the root with none enabled.
echo "+cpu" > /sys/fs/cgroup/cgroup.subtree_control
echo "+cpuset" > /sys/fs/cgroup/cgroup.subtree_control
echo "+memory" > /sys/fs/cgroup/cgroup.subtree_control
echo "+pids" > /sys/fs/cgroup/cgroup.subtree_control
echo "+io" > /sys/fs/cgroup/cgroup.subtree_control

# No disk: everything the runtime and kubelet write is RAM. The /var/log/k4s-*
# directories are where the test's pods write their results, as hostPath
# volumes; they have to exist before the kubelet gets a pod that mounts them.
mkdir -p /run/containerd /run/flannel /lib/modules
mkdir -p /var/lib/containerd /var/lib/kubelet /var/log/pods
mkdir -p /var/log/k4s-smoke /var/log/k4s-netns /var/log/k4s-ds
mkdir -p /var/log/k4s-deploy /var/log/k4s-flannel
mount -t tmpfs tmpfs /var/lib/containerd
mount -t tmpfs tmpfs /var/lib/kubelet
mount -t tmpfs tmpfs /var/log/pods

# --- containerd -------------------------------------------------------------
containerd </dev/null >/tmp/containerd.log 2>&1 &
i=0; while ! ctr version >/dev/null 2>&1 && [ $i -lt 30 ]; do sleep 1; i=$((i+1)); done
ctr version >/dev/null 2>&1 && echo "K4S_INIT: containerd: ok" || echo "K4S_INIT: containerd: fail"

# --- kubelet ----------------------------------------------------------------
# Only if the cluster has given us credentials. `make run` boots this same image
# with no kubeconfig spliced in, and there kubelet has nothing to join.
test -s /etc/kubernetes/kubeconfig && echo "K4S_INIT: kubelet: starting" || echo "K4S_INIT: kubelet: skipped (no kubeconfig)"
test -s /etc/kubernetes/kubeconfig && kubelet --config=/etc/kubernetes/kubelet.yaml --kubeconfig=/etc/kubernetes/kubeconfig --hostname-override=k4s-node-1 </dev/null >/tmp/kubelet.log 2>&1 &

echo "K4S_INIT: done"
