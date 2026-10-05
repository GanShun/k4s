#!/bin/bash
#
# M1 join test: a throwaway Kubernetes control plane in one QEMU VM, and the
# node image running kubelet in another.
#
# Steps:
#   1. build etcd, kube-apiserver, kube-controller-manager, kube-scheduler and
#      kubectl from the pinned sources
#   2. generate a throwaway CA, a kubelet kubeconfig and an admin kubeconfig
#   3. build a control plane image with the PKI baked in, boot it as a VM, and
#      wait for the apiserver through a port forward on 127.0.0.1:6443
#   4. splice the kubelet kubeconfig into a copy of the node initramfs
#   5. boot the node image, wait for it to register, apply the flannel DaemonSet
#      so the node has a CNI, then create the pods and check their markers
#   5b. also create a pod that asks for its own network namespace, and check it
#      gets an address from the CNI
#   5c. apply a DaemonSet and a Deployment, so the controller-manager and the
#      scheduler are exercised rather than just present
#   6. boot it again, unchanged, and check it rejoins and everything returns
#
# The control plane is a VM rather than host processes because a node should
# join something shaped like a real cluster: the controller-manager is what
# assigns pod CIDRs, runs DaemonSets and Deployments and issues service account
# tokens, and the host-side control plane this replaced had none of that.
#
# The kubeconfigs and PKI are generated per run and spliced in; never committed.
#
# Usage: test-cluster.sh [kernel] [base-initramfs]
# Env: K4S_BOOT_TIMEOUT  hard bound, in seconds, from a guest's boot to the end
#                         of its work (default 120). Nothing here should need
#                         more than that; if it does, something is wrong and
#                         waiting longer only hides it.
#      K4S_BOOTS         number of guest boots (default 2)

set -euo pipefail

KERNEL=${1:-build/kernel/arch/x86/boot/bzImage}
BASE=${2:-initramfs.cpio}

CP=build/controlplane
PKI=$CP/pki
SSH=$CP/ssh
NODEDIR=$CP/node
NODE=k4s-node-1
PORT=6443
SSH_PORT=${K4S_SSH_PORT:-2222}
APISERVER="https://127.0.0.1:$PORT"
SERVER="https://10.0.2.2:$PORT"
NODE_IMAGE=$CP/node-test.cpio
CP_IMAGE=$CP/controlplane-image.cpio
GUEST=$(dirname "$0")/cluster-check.sh
CP_GUEST=$(dirname "$0")/controlplane-boot.sh
CONFIGS=$(dirname "$0")/../configs/node
POD=$CONFIGS/smoke-pod.yaml
NETNS_POD=$CONFIGS/netns-pod.yaml
DS=$CONFIGS/ds-pod.yaml
LOGPOD=$CONFIGS/log-pod.yaml
FLANNEL_DS=$CONFIGS/flannel-ds.yaml
DEPLOY=$CONFIGS/deploy-pod.yaml
BOOT_TIMEOUT=${K4S_BOOT_TIMEOUT:-120}
BOOTS=${K4S_BOOTS:-2}
# flannel is the default because it needs nothing from the kernel that this one
# lacks. K4S_CNI=cilium runs the same test with Cilium instead, which needs the
# kernel built with configs/k4s-cni.config and a great deal more memory, so the
# node VM is given more room there.
CNI=${K4S_CNI:-flannel}
# 1 reuses a control plane VM that is already up, and leaves it up, so that
# repeated attempts at the node side cost a node boot instead of two VM boots
# and a control plane image build.
NODE_MEM=${K4S_NODE_MEM:-1536}
CILIUM_VERSION=${K4S_CILIUM_VERSION:-1.20.2}
HELM=${HELM:-helm}
CILIUM_YAML=$CP/cilium.yaml

ACCEL=()
[ -w /dev/kvm ] && ACCEL=(-enable-kvm -cpu host)

mkdir -p "$CP" "$NODEDIR"

# One instance at a time. Two would fight over the port forward and over the
# node VM's console log. Not a lock file: an flock fd is inherited by every
# child, including the node VM -- so the lock outlived the run and the next one
# could never start. A pid file with a liveness check cannot go stale like that.
if [ -f "$CP/run.pid" ]; then
	oldpid=$(cat "$CP/run.pid" 2>/dev/null || true)
	if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
		echo "another test-cluster.sh is already running (pid $oldpid)" >&2
		exit 1
	fi
fi
echo $$ > "$CP/run.pid"

# Every phase line carries the elapsed seconds. The point of this test is to
# be quick, and the only way to keep it that way is to be able to see where the
# time goes without guessing.
log() { printf '\n=== t+%ss %s ===\n' "$SECONDS" "$*"; }

K() {
	"$CP/kubectl" --server="$APISERVER" \
		--certificate-authority="$PKI/ca.crt" \
		--client-certificate="$PKI/admin.crt" --client-key="$PKI/admin.key" "$@"
}

# --- control plane ----------------------------------------------------------
build_control_plane() {
	if [ -x "$CP/etcd" ] && [ -x "$CP/kube-apiserver" ] && [ -x "$CP/kubectl" ] \
		&& [ -x "$CP/kube-controller-manager" ] && [ -x "$CP/kube-scheduler" ]; then
		return 0
	fi
	log "building control plane binaries (etcd, apiserver, controller-manager, scheduler, kubectl)"
	mkdir -p "$CP"
	# -s -w on the four that go into the image: they are stripped of symbols and
	# DWARF, which is a third off the size of a 400 MB initramfs. kubectl stays
	# on the host and is left as it is.
	(cd etcd/server && GOWORK=off CGO_ENABLED=0 go build -ldflags "-s -w" \
		-o ../../build/controlplane/etcd .)
	for b in kube-apiserver kube-controller-manager kube-scheduler kubectl; do
		(cd kubernetes && CGO_ENABLED=0 env -u GOARCH -u GOOS go build -mod=vendor \
			-ldflags "-s -w" -o "../build/controlplane/$b" "./cmd/$b")
	done
}

# A throwaway key so the harness can read files out of the guest over ssh
# instead of scraping them off the serial console. u-root's sshd takes its host
# key and its authorized_keys as paths, so both are spliced into the node image
# and generated per run, never committed, exactly like the PKI above.
gen_ssh_keys() {
	if [ -s "$SSH/client" ] && [ -s "$SSH/authorized_keys" ]; then
		return 0
	fi
	log "generating a throwaway ssh key"
	rm -rf "$SSH"
	mkdir -p "$SSH"
	ssh-keygen -q -t rsa -b 2048 -N '' -f "$SSH/host_rsa" >/dev/null
	ssh-keygen -q -t rsa -b 2048 -N '' -f "$SSH/client" >/dev/null
	cp "$SSH/client.pub" "$SSH/authorized_keys"
}

gen_pki() {
	if [ -f "$PKI/ca.crt" ] && [ -f "$NODEDIR/kubeconfig" ] && [ -f "$PKI/admin.kubeconfig" ]; then
		return 0
	fi
	log "generating throwaway PKI"
	rm -rf "$PKI"
	mkdir -p "$PKI"
	openssl req -x509 -newkey rsa:2048 -nodes -keyout "$PKI/ca.key" -out "$PKI/ca.crt" \
		-days 3650 -subj "/CN=k4s-test-ca" 2>/dev/null
	cat > "$PKI/apiserver.cnf" <<'EOF'
[req]
distinguished_name=dn
req_extensions=v3
[dn]
[v3]
subjectAltName=@alt
[alt]
DNS.1=localhost
DNS.2=kubernetes
IP.1=127.0.0.1
IP.2=10.0.2.2
EOF
	openssl req -newkey rsa:2048 -nodes -keyout "$PKI/apiserver.key" -out "$PKI/apiserver.csr" \
		-subj "/CN=kube-apiserver" -config "$PKI/apiserver.cnf" 2>/dev/null
	openssl x509 -req -in "$PKI/apiserver.csr" -CA "$PKI/ca.crt" -CAkey "$PKI/ca.key" \
		-CAcreateserial -out "$PKI/apiserver.crt" -days 3650 \
		-extensions v3 -extfile "$PKI/apiserver.cnf" 2>/dev/null
	openssl req -newkey rsa:2048 -nodes -keyout "$PKI/kubelet.key" -out "$PKI/kubelet.csr" \
		-subj "/CN=system:node:$NODE/O=system:nodes" 2>/dev/null
	openssl x509 -req -in "$PKI/kubelet.csr" -CA "$PKI/ca.crt" -CAkey "$PKI/ca.key" \
		-CAcreateserial -out "$PKI/kubelet.crt" -days 3650 2>/dev/null
	openssl req -newkey rsa:2048 -nodes -keyout "$PKI/admin.key" -out "$PKI/admin.csr" \
		-subj "/CN=admin/O=system:masters" 2>/dev/null
	openssl x509 -req -in "$PKI/admin.csr" -CA "$PKI/ca.crt" -CAkey "$PKI/ca.key" \
		-CAcreateserial -out "$PKI/admin.crt" -days 3650 2>/dev/null
	openssl genrsa -out "$PKI/sa.key" 2048 2>/dev/null
	openssl rsa -in "$PKI/sa.key" -pubout -out "$PKI/sa.pub" 2>/dev/null
	{
		echo "apiVersion: v1"
		echo "kind: Config"
		echo "clusters:"
		echo "- name: k4s"
		echo "  cluster:"
		echo "    server: $SERVER"
		echo "    certificate-authority-data: $(base64 -w0 "$PKI/ca.crt")"
		echo "users:"
		echo "- name: kubelet"
		echo "  user:"
		echo "    client-certificate-data: $(base64 -w0 "$PKI/kubelet.crt")"
		echo "    client-key-data: $(base64 -w0 "$PKI/kubelet.key")"
		echo "contexts:"
		echo "- name: k4s"
		echo "  context:"
		echo "    cluster: k4s"
		echo "    user: kubelet"
		echo "current-context: k4s"
	} > "$NODEDIR/kubeconfig"
	# The controller-manager and scheduler run inside the control plane VM, so
	# they use the admin identity against the loopback address. The
	# controller-manager needs to patch Nodes, which is what gives a node its
	# spec.podCIDR -- and flannel refuses to start without one.
	{
		echo "apiVersion: v1"
		echo "kind: Config"
		echo "clusters:"
		echo "- name: k4s"
		echo "  cluster:"
		echo "    server: $APISERVER"
		echo "    certificate-authority-data: $(base64 -w0 "$PKI/ca.crt")"
		echo "users:"
		echo "- name: admin"
		echo "  user:"
		echo "    client-certificate-data: $(base64 -w0 "$PKI/admin.crt")"
		echo "    client-key-data: $(base64 -w0 "$PKI/admin.key")"
		echo "contexts:"
		echo "- name: k4s"
		echo "  context:"
		echo "    cluster: k4s"
		echo "    user: admin"
		echo "current-context: k4s"
	} > "$PKI/admin.kubeconfig"
}

# Kill a QEMU still running a given initrd, which is what an interrupted run
# leaves behind and what would otherwise hold the port forward open.
#
# Both the executable and the command line have to match. An earlier version of
# this script matched on the command line alone and killed its own caller,
# because the caller's command line mentioned the path; requiring the process to
# actually be qemu-system-x86_64 makes that impossible.
kill_qemu_for() {
	local image=$1 pid exe cmd
	for pid in /proc/[0-9]*; do
		pid=${pid#/proc/}
		exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null) || continue
		# A binary replaced while running reports as "<path> (deleted)".
		exe=${exe% (deleted)}
		case "${exe##*/}" in
		qemu-system-x86_64) ;;
		*) continue ;;
		esac
		cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null) || continue
		case "$cmd" in
		*"$image"*) kill "$pid" 2>/dev/null || true ;;
		esac
	done
}

cp_down() {
	if [ -f "$CP/controlplane.pid" ]; then
		kill "$(cat "$CP/controlplane.pid")" 2>/dev/null || true
		rm -f "$CP/controlplane.pid"
	fi
	kill_qemu_for "$CP_IMAGE"
	sleep 1
}

wait_apiserver() {
	local i
	# Generous, because this polls across a VM boot: QEMU, then etcd, then the
	# apiserver, which the guest starts on a fixed schedule.
	for i in $(seq 1 180); do
		if K get --raw=/healthz >/dev/null 2>&1; then
			return 0
		fi
		sleep 1
	done
	return 1
}

build_controlplane_image() {
	log "building the control plane image"
	./u-root/u-root -o "$CP_IMAGE" \
		-files "$CP/etcd":bin/etcd \
		-files "$CP/kube-apiserver":bin/kube-apiserver \
		-files "$CP/kube-controller-manager":bin/kube-controller-manager \
		-files "$CP/kube-scheduler":bin/kube-scheduler \
		-files "$PKI/ca.crt":etc/kubernetes/pki/ca.crt \
		-files "$PKI/apiserver.crt":etc/kubernetes/pki/apiserver.crt \
		-files "$PKI/apiserver.key":etc/kubernetes/pki/apiserver.key \
		-files "$PKI/sa.key":etc/kubernetes/pki/sa.key \
		-files "$PKI/sa.pub":etc/kubernetes/pki/sa.pub \
		-files "$PKI/admin.kubeconfig":etc/kubernetes/admin.kubeconfig \
		-files "$CONFIGS/passwd":etc/passwd \
		-files "$CONFIGS/group":etc/group \
		-files "$CONFIGS/hosts":etc/hosts \
		u-root/cmds/core/* >/dev/null
}

cp_up() {
	# Always a fresh control plane, and always stop whatever an earlier run left
	# behind first. Reusing one was a speed hack, and it quietly made runs depend
	# on each other: that VM's etcd keeps the last run's Node, pods, DaemonSets
	# and CiliumNodes, so a run could pass or fail on another run's objects. A
	# stale pod status makes the checks fire instantly and for the wrong reason,
	# and a stale Node object makes "node: ok (registered)" meaningless because
	# it reports a Node that a previous node VM registered.
	cp_down
	local i
	for i in $(seq 1 15); do
		K get --raw=/healthz >/dev/null 2>&1 || break
		sleep 1
	done
	# If something still answers, it is not a VM this script knows how to stop,
	# and testing against it would be worse than failing: QEMU's forward would
	# fail and the health check below would be satisfied by the stale one.
	if K get --raw=/healthz >/dev/null 2>&1; then
		echo "something is already serving 127.0.0.1:$PORT" >&2
		echo "and it is not a control plane VM this script started" >&2
		exit 1
	fi
	log "booting the control plane VM"
	# Hold stdin open past the script so gosh does not see EOF and exit. The
	# port forward is how both the host and the node reach the apiserver: the
	# host at 127.0.0.1:6443, and the node at 10.0.2.2:6443, which is the host
	# from inside the node's user-mode network.
	cat "$CP_GUEST" | feed_guest "$CP/controlplane.pid" | \
		qemu-system-x86_64 -M q35 -m 1024 -smp 2 "${ACCEL[@]}" \
			-netdev user,id=n0,hostfwd=tcp:127.0.0.1:$PORT-:$PORT \
			-device virtio-net-pci,netdev=n0 \
			-kernel "$KERNEL" -initrd "$CP_IMAGE" \
			-append "console=ttyS0,115200 panic=-1" \
			-nographic -no-reboot > "$CP/controlplane.log" 2>&1 &
	echo $! > "$CP/controlplane.pid"
	if ! kill -0 "$(cat "$CP/controlplane.pid")" 2>/dev/null; then
		echo "the control plane VM exited at startup" >&2
		tail -20 "$CP/controlplane.log" >&2
		exit 1
	fi
	# The guest prints this once etcd, the apiserver, the controller-manager and
	# the scheduler are all running. Requiring it is what distinguishes this
	# VM's apiserver from anything else that happens to answer on the port.
	local i
	for i in $(seq 1 150); do
		grep -qa 'K4S_CP_READY' "$CP/controlplane.log" && break
		sleep 1
	done
	if ! grep -qa 'K4S_CP_READY' "$CP/controlplane.log"; then
		echo "the control plane VM never reported ready" >&2
		tail -40 "$CP/controlplane.log" >&2
		exit 1
	fi
	# The guest checks each service rather than assuming, because a service that
	# refused to start leaves everything else looking normal.
	if ! grep -qa 'K4S_CP: apiserver: ok' "$CP/controlplane.log"; then
		echo "a service in the control plane VM failed to start" >&2
		grep -a 'K4S_CP: ' "$CP/controlplane.log" >&2
		grep -a -A5 'apiserver log tail' "$CP/controlplane.log" >&2
		exit 1
	fi
	if ! wait_apiserver; then
		echo "the apiserver never became healthy in the control plane VM" >&2
		tail -40 "$CP/controlplane.log" >&2
		exit 1
	fi
	echo "apiserver: ok (in the control plane VM, with a scheduler)"
}

# --- Cilium -----------------------------------------------------------------
# The manifest is rendered from Cilium's chart rather than taken from a release
# asset, because it has to be told things: which apiserver to talk to (there is
# no service routing on this node, so the ClusterIP is a black hole) and which
# addresses to hand out. helm template renders it; the chart is pinned by
# version, and the images it names are pinned by digest already.
build_cilium() {
	[ "$CNI" = cilium ] || return 0
	log "rendering the Cilium $CILIUM_VERSION manifest"
	# helm pull --untar refuses to overwrite, so the chart from a previous run has
	# to go first.
	rm -rf "$CP/charts/cilium"
	"$HELM" pull cilium --version "$CILIUM_VERSION" --repo https://helm.cilium.io \
		--untar --untardir "$CP/charts" >/dev/null
	"$HELM" template cilium "$CP/charts/cilium" --namespace kube-system \
		--set k8sServiceHost=10.0.2.2 --set k8sServicePort="$PORT" \
		--set ipam.mode=kubernetes \
		--set operator.replicas=1 \
		--set hubble.enabled=false --set hubble.relay.enabled=false \
		--set hubble.ui.enabled=false > "$CILIUM_YAML"

	# Drop the agent's postStart hook. Its only job is deleting iptables rules
	# left behind by the AWS VPC CNI plugin, which this node has never run: on
	# any non-AWS node it is a no-op. It fails here regardless, because it opens
	# with `iptables-save | grep -c` under `set -o errexit` and this node has no
	# iptables at all -- and a failed postStart hook makes the kubelet kill the
	# container. That is what made the agent exit 2 with an empty log while the
	# binary itself runs fine. See docs/cilium.md.
	python3 - "$CILIUM_YAML" <<-'PY'
	import sys
	path = sys.argv[1]
	out, skipping, removed = [], False, 0
	for line in open(path):
	    if line.rstrip("\n") == "          postStart:":
	        skipping, removed = True, removed + 1
	        continue
	    if skipping and line.rstrip("\n") == "          preStop:":
	        skipping = False
	    if not skipping:
	        out.append(line)
	assert removed == 1, f"expected one postStart hook, removed {removed}"
	open(path, "w").writelines(out)
	PY
}

# --- node image -------------------------------------------------------------
splice_image() {
	# Cilium writes this conflist itself, once its agent is ready -- but the CRI
	# reads the config directory once, at startup, which is before that. An empty
	# directory is ErrCNINotInitialized; a directory with flannel's conflist in
	# it makes containerd cache the flannel plugin, and then every sandbox fails
	# with "failed to load flannel 'subnet.env'", which is what this cost us. So
	# put the same conflist Cilium will write there up front; the agent rewrites
	# it identically when it becomes ready.
	local extra=()
	if [ "$CNI" = cilium ]; then
		extra=(-files "$CONFIGS/05-cilium.conflist:etc/cni/net.d/05-cilium.conflist")
	fi
	log "splicing the node kubeconfig, ssh keys and CNI config into $NODE_IMAGE"
	./u-root/u-root -base "$BASE" -nocmd \
		-files "$NODEDIR/kubeconfig:etc/kubernetes/kubeconfig" \
		-files "$SSH/authorized_keys:etc/ssh/authorized_keys" \
		-files "$SSH/host_rsa:etc/ssh/host_rsa" \
		"${extra[@]}" \
		-initcmd="" -defaultsh="" -o "$NODE_IMAGE" >/dev/null
}

# --- guest ------------------------------------------------------------------
boot() {
	local n=$1
	log "booting the node image (run $n/$BOOTS)"
	# Hold stdin open past the script so gosh does not see EOF and exit.
	{
		# Cilium's DaemonSet mounts /lib/modules unconditionally, and this image
		# has no modules and so no such directory.
		#
		# Cilium's conflist has to be the only one on disk before containerd
		# starts, because the CRI reads that directory once and then uses what it
		# cached. Leaving flannel's there means containerd caches the flannel
		# plugin and every sandbox fails with "failed to load flannel
		# 'subnet.env'", which is exactly what happened. The Cilium conflist is
		# spliced into the image for the same reason: deleting flannel's and
		# waiting for Cilium to write its own leaves the directory empty when
		# containerd looks, and a directory with no conflist in it is
		# ErrCNINotInitialized, which is the same failure one step earlier.
		if [ "$CNI" = cilium ]; then
			printf 'mkdir -p /lib/modules\n'
			printf 'rm -f /etc/cni/net.d/10-flannel.conflist\n'
		fi
		cat "$GUEST"
	} | feed_guest "$CP/qemu.pid" | qemu-system-x86_64 -M q35 -m "$NODE_MEM" -smp 2 "${ACCEL[@]}" \
			-netdev user,id=n0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:2022 \
			-device virtio-net-pci,netdev=n0 \
			-kernel "$KERNEL" -initrd "$NODE_IMAGE" \
			-append "console=ttyS0,115200 panic=-1 cgroup_no_v1=all" \
			-nographic -no-reboot > "$CP/boot$n.log" 2>&1 &
	echo $! > "$CP/qemu.pid"
}

# Feed the guest its script, then hold stdin open until the VM is gone: gosh
# treats a closed stdin as end of script and would exit before the guest has
# finished. The point is that it must not outlive the VM. Sleeping a fixed
# BOOT_TIMEOUT + 60 here instead leaves the pipeline -- and therefore anything
# that waits for it, including this script's own exit -- alive for up to eleven
# minutes after the guest has powered off, which is dead time on every run.
#
# One line at a time, and slowly. Handing the whole script to the serial port at
# once overruns the guest's UART and drops characters, which corrupts the script
# and stops the guest partway through -- the console simply ends mid-file with no
# error, and everything the guest was supposed to print afterwards is missing.
# At 115200 baud a 78-character line takes about 7ms, so 50ms leaves plenty of
# room; a 150-line script costs under eight seconds.
feed_guest() {
	local pidfile=$1 line
	while IFS= read -r line; do
		printf '%s\n' "$line"
		sleep 0.05
	done
	while [ ! -s "$pidfile" ] || kill -0 "$(cat "$pidfile")" 2>/dev/null; do
		sleep 1
	done
}

# Kill a VM that outlives its bound, and exit as soon as it is gone so this
# never holds the run open by itself.
watchdog() {
	local limit=$1 pid=$2 i
	for i in $(seq 1 "$limit"); do
		kill -0 "$pid" 2>/dev/null || return 0
		sleep 1
	done
	echo "WATCHDOG: the guest outlived its ${limit}s bound; killing it" >&2
	kill -9 "$pid" 2>/dev/null || true
}

# The guest is not asked to power itself off, and this does not wait for it to
# exit. It used to, and that made the guest's own idea of when it had finished
# race every check the harness makes: the guest would shut down as soon as its
# script ended, while the harness was still applying pods and waiting for them,
# so the files read afterwards were empty and the VM was gone. The harness knows
# when it is done -- it is the one waiting for the markers -- so it reads what it
# needs over ssh and then stops the VM.
stop_guest() {
	local pid
	pid=$(cat "$CP/qemu.pid" 2>/dev/null || true)
	[ -n "$pid" ] && kill "$pid" 2>/dev/null || true
	local i
	for i in $(seq 1 10); do
		kill -0 "$pid" 2>/dev/null || return 0
		sleep 1
	done
	kill -9 "$pid" 2>/dev/null || true
}

wait_qemu() {
	local pid i
	pid=$(cat "$CP/qemu.pid")
	# The bound is hard: from the guest's boot to the end of its work is
	# BOOT_TIMEOUT seconds, and a guest that is still running after that is a
	# bug to be found, not waited out.
	watchdog "$BOOT_TIMEOUT" "$pid" &
	for i in $(seq 1 "$BOOT_TIMEOUT"); do
		if ! kill -0 "$pid" 2>/dev/null; then
			return 0
		fi
		sleep 1
	done
	echo "the guest was still running after ${BOOT_TIMEOUT}s; killing it" >&2
	kill -9 "$pid" 2>/dev/null || true
}

# Wait only for the Node object, not for it to be Ready. When the CNI installs
# its own config -- Cilium does -- the node cannot become Ready until that has
# happened, so waiting for Ready before applying the CNI is a deadlock: nothing
# would ever run the DaemonSet that makes the node Ready.
# Read files out of the guest over ssh. This is the whole reason sshd is in the
# image: the serial console cannot be trusted with bulk output, a file that is
# read does not have to be printed at the right moment to be caught, and catting
# a log to a 115200-baud line takes minutes.
guest_get() {
	ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		-o BatchMode=yes -o ConnectTimeout=5 -i "$SSH/client" \
		-p "$SSH_PORT" root@127.0.0.1 "$@" 2>&1 || true
}

wait_ssh() {
	local i
	for i in $(seq 1 45); do
		if guest_get true >/dev/null 2>&1; then
			return 0
		fi
		sleep 1
	done
	return 1
}

# Everything worth knowing about a failed run, read out of the guest over ssh
# while it is still alive. This is what sshd is in the image for. The serial
# console cannot do this job: a log has to be printed at exactly the right
# moment to be caught, catting one to a 115200-baud line takes minutes, and
# handing the console too much at once corrupts the guest's own script. A file
# that is read does not have to be printed at any particular moment at all.
# Pull everything the checks and the diagnostics need out of the guest while it
# is still up, and keep it on the host. This is the reason sshd is in the image:
# the serial console cannot be trusted with bulk output, a log takes minutes to
# print at 115200 baud, and a file that is read does not have to be printed at
# the right moment to be caught. Quiet -- diag() prints the summary.
collect() {
	local d=$CP/diag m
	mkdir -p "$d" "$CP/markers"
	for m in smoke netns ds deploy; do
		guest_get "cat /var/log/k4s-$m/result 2>/dev/null" > "$CP/markers/$m"
	done
	guest_get 'cat /var/log/pods/*k4s-log*/log/*.log 2>/dev/null' > "$CP/markers/log"
	for m in kubelet.log containerd.log sshd.log; do
		guest_get "cat /tmp/$m" > "$d/$m" 2>/dev/null || true
	done
	guest_get 'cat /var/log/pods/*cilium-*/cilium-agent/*.log' > "$d/cilium-agent.log" 2>/dev/null || true
	guest_get 'ls /etc/cni/net.d; ls /opt/cni/bin' > "$d/cni-files" 2>/dev/null || true
}

diag() {
	local d=$CP/diag m
	mkdir -p "$d"
	echo "  --- markers ---" >&2
	for m in smoke netns ds deploy; do
		printf '  %-7s %s\n' "$m" \
			"$(guest_get "cat /var/log/k4s-$m/result 2>/dev/null" | tr '\n' ' ')" >&2
	done
	echo "  --- cni on disk ---" >&2
	guest_get 'ls /etc/cni/net.d; ls /opt/cni/bin' | sed 's/^/  /' >&2
	echo "  --- cilium-cni plugin log ---" >&2
	guest_get 'cat /var/run/cilium/cilium-cni.log 2>&1 | tail -n 15' | sed 's/^/  /' >&2
	echo "  --- kubelet, the netns pod ---" >&2
	guest_get 'grep k4s-netns /tmp/kubelet.log | tail -n 10' | sed 's/^/  /' >&2
	echo "  --- kubelet, last 12 ---" >&2
	guest_get 'tail -n 12 /tmp/kubelet.log' | sed 's/^/  /' >&2
	echo "  --- containerd, cni ---" >&2
	guest_get 'grep -iE "cni|sandbox" /tmp/containerd.log | tail -n 10' | sed 's/^/  /' >&2
	echo "  --- the agent, errors ---" >&2
	guest_get 'grep -E "level=(error|fatal)" /var/log/pods/*cilium-*/cilium-agent/*.log | tail -n 12' | sed 's/^/  /' >&2
	# Keep the full logs for a second look, rather than printing them.
	for m in kubelet.log containerd.log sshd.log; do
		guest_get "cat /tmp/$m" > "$d/$m" 2>/dev/null || true
	done
	guest_get 'cat /var/log/pods/*cilium-*/cilium-agent/*.log' > "$d/cilium-agent.log" 2>/dev/null || true
	echo "  (full logs kept in $d)" >&2
}

wait_node_exists() {
	local i
	for i in $(seq 1 90); do
		if K get node "$NODE" >/dev/null 2>&1; then
			return 0
		fi
		sleep 2
	done
	return 1
}

wait_node() {
	local i
	for i in $(seq 1 90); do
		if [ "$(K get node "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ]; then
			return 0
		fi
		sleep 2
	done
	return 1
}

# Delete a workload before applying it. Runs are self-contained now, so this is
# belt and braces rather than the load-bearing thing it was when a reused
# control plane could hand back a previous run's status.
reapply() {
	K delete -f "$1" --ignore-not-found >/dev/null 2>&1 || true
	K apply -f "$1" >/dev/null
}

run_pod() {
	log "applying the smoke pod"
	reapply "$POD"
	local i ph
	for i in $(seq 1 90); do
		ph=$(K get pod k4s-smoke -o jsonpath='{.status.phase}' 2>/dev/null || true)
		if [ "$ph" = Running ]; then
			echo "pod phase: Running"
			return 0
		fi
		sleep 2
	done
	echo "pod did not reach Running" >&2
	K get pod k4s-smoke -o wide 2>&1 | sed 's/^/  /' >&2
	return 1
}

# A pod that asks for its own network namespace only runs if the CNI gives it an
# address, so this is the assertion that the node has a working pod network
# rather than merely a CNI config file. Both ends are checked: the apiserver's
# view of the address here, and the container's own view of eth0 in check_marker.
run_netns_pod() {
	log "applying the pod that needs a CNI"
	reapply "$NETNS_POD"
	local i ph ip
	for i in $(seq 1 90); do
		ph=$(K get pod k4s-netns -o jsonpath='{.status.phase}' 2>/dev/null || true)
		if [ "$ph" = Running ]; then
			ip=$(K get pod k4s-netns -o jsonpath='{.status.podIP}' 2>/dev/null || true)
			if [[ "$ip" == 10.244.* ]]; then
				echo "pod IP: $ip (from the node's pod CIDR)"
				return 0
			fi
			echo "netns pod: FAILED (Running, but its address is ${ip:-<none>}, not from 10.244.0.0/16)" >&2
			diag
			return 1
		fi
		sleep 2
	done
	echo "netns pod: FAILED (never reached Running)" >&2
	K describe pod k4s-netns 2>&1 | tail -25 | sed 's/^/  /' >&2
	diag
	return 1
}

# flanneld is a DaemonSet now, so the node has a CNI only once its pod is
# running: it writes the subnet file the CNI plugin reads, and nothing with a
# network namespace of its own can start before that. It is hostNetwork, so it
# needs no CNI to start itself.
run_cni() {
	if [ "$CNI" = cilium ]; then
		run_cilium
		return
	fi
	run_flannel
}

# Cilium installs its own CNI config, so the node's /etc/cni/net.d starts empty
# and the CRI reports NetworkReady=false until the agent writes it. That is why
# the node only becomes Ready after this DaemonSet is up, and why the agent has
# to be hostNetwork.
run_cilium() {
	log "applying Cilium"
	# Remove flannel first. Runs are self-contained now, so a fresh control plane
	# has no flannel in it, but a DaemonSet left over from a failed earlier apply
	# in this same run would come back on the new node and give it two CNIs.
	K delete daemonset k4s-flannel -n kube-system --ignore-not-found >/dev/null 2>&1 || true
	K apply -f "$CILIUM_YAML" >/dev/null
	local i ready waiting lastwaiting=""
	for i in $(seq 1 30); do
		ready=$(K get daemonset cilium -n kube-system -o jsonpath='{.status.numberReady}' 2>/dev/null || true)
		if [ "${ready:-0}" = 1 ]; then
			echo "cilium: ok (the agent is running on the node)"
			return 0
		fi
		# Bail as soon as the agent is visibly failing rather than waiting out
		# the timeout: a crash-looping container backs off exponentially, so
		# the remaining minutes contain no information. Cilium's pods are
		# created within seconds, which is the whole reason this is worth
		# distinguishing from "slow".
		# Only after the agent has had a chance, and only if the same reason
		# shows up twice: right after the DaemonSet is applied, the pod status
		# still describes the previous run's crash loop.
		if [ "$i" -lt 15 ]; then
			sleep 2
			continue
		fi
		waiting=$(K get pods -n kube-system -l k8s-app=cilium \
			-o jsonpath='{.items[*].status.containerStatuses[*].state.waiting.reason}' 2>/dev/null || true)
		if [ "$waiting" = "$lastwaiting" ]; then
			case "$waiting" in
			*CrashLoopBackOff*|*ImagePullBackOff*|*ErrImagePull*|*CreateContainerError*|*RunContainerError*)
			echo "cilium: FAILED (agent $waiting) after $((i * 2))s" >&2
			# Read the node's side of the story over ssh while it is still up.
			diag
			K get pods -n kube-system -o wide 2>&1 | sed 's/^/  /' >&2
			K describe pod -n kube-system -l k8s-app=cilium 2>&1 | tail -25 | sed 's/^/  /' >&2
			return 1
			;;
			esac
		fi
		lastwaiting=$waiting
		sleep 2
	done
	echo "cilium: FAILED (agent ready=${ready:-0})" >&2
	K get daemonset,deployment,pods -n kube-system -o wide 2>&1 | sed 's/^/  /' >&2
	K describe pod -n kube-system -l k8s-app=cilium 2>&1 | tail -30 | sed 's/^/  /' >&2
	return 1
}

run_flannel() {
	log "applying the flannel DaemonSet"
	# flanneld exits rather than retrying when it cannot take a subnet lease, and
	# a lease needs the node to have a spec.podCIDR, which the controller-manager
	# assigns a few seconds after the node registers. Applying this before that
	# lands puts flanneld into a restart backoff for no reason, so wait for it.
	local i cidr
	for i in $(seq 1 60); do
		cidr=$(K get node "$NODE" -o jsonpath='{.spec.podCIDR}' 2>/dev/null || true)
		[ -n "$cidr" ] && break
		sleep 1
	done
	if [ -z "$cidr" ]; then
		echo "flannel: FAILED (the node never got a podCIDR from the controller-manager)" >&2
		return 1
	fi
	echo "node podCIDR: $cidr"
	K apply -f "$FLANNEL_DS" >/dev/null
	local ready
	for i in $(seq 1 90); do
		ready=$(K get daemonset k4s-flannel -n kube-system -o jsonpath='{.status.numberReady}' 2>/dev/null || true)
		if [ "${ready:-0}" = 1 ]; then
			echo "flannel: ok (the DaemonSet is up and holds a subnet lease)"
			return 0
		fi
		sleep 2
	done
	echo "flannel: FAILED (DaemonSet ready=${ready:-0})" >&2
	K get daemonset,pods -n kube-system -o wide 2>&1 | sed 's/^/  /' >&2
	K describe pod -n kube-system -l app=k4s-flannel 2>&1 | tail -25 | sed 's/^/  /' >&2
	return 1
}

# The stdout pod: it exists to answer whether the node captures container
# output at all, so all that is checked here is that it runs. What it printed is
# read from the guest's console.
run_log_pod() {
	local i ph
	for i in $(seq 1 90); do
		ph=$(K get pod k4s-log -o jsonpath='{.status.phase}' 2>/dev/null || true)
		if [ "$ph" = Running ]; then
			return 0
		fi
		sleep 2
	done
	echo "log pod: FAILED (phase ${ph:-none})" >&2
	K describe pod k4s-log 2>&1 | tail -20 | sed 's/^/  /' >&2
	return 1
}

# The DaemonSet controller and the scheduler both live in the control plane VM,
# so these only become ready if it is doing its job: the DaemonSet controller
# assigns its own node, and nothing pins the Deployment, so it needs the
# scheduler.
run_workloads() {
	log "applying a DaemonSet and a Deployment"
	reapply "$DS"
	reapply "$DEPLOY"
	reapply "$LOGPOD"
	local i ds deploy
	for i in $(seq 1 120); do
		ds=$(K get daemonset k4s-ds -o jsonpath='{.status.numberReady}' 2>/dev/null || true)
		deploy=$(K get deployment k4s-deploy -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)
		if [ "${ds:-0}" = 1 ] && [ "${deploy:-0}" = 1 ]; then
			echo "daemonset: ok (the controller-manager ran it)"
			echo "deployment: ok (the scheduler placed it)"
			return 0
		fi
		sleep 2
	done
	echo "workloads: FAILED (daemonset ready=${ds:-0}, deployment available=${deploy:-0})" >&2
	K get daemonset,deployment,pods -o wide 2>&1 | sed 's/^/  /' >&2
	return 1
}

check_marker() {
	local m=$CP/markers
	if ! grep -q 'K4S_POD_OK' "$m/smoke" 2>/dev/null; then
		echo "pod: FAILED (the smoke pod did not write K4S_POD_OK)" >&2
		sed 's/^/  /' "$m/smoke" >&2
		return 1
	fi
	# The container reports Seccomp: 2 (SECCOMP_MODE_FILTER) only if a filter is
	# actually installed, so this is the assertion that the cgo-free runc
	# enforced the profile rather than merely starting the container.
	if ! grep -qE 'Seccomp:[[:space:]]+2' "$m/smoke"; then
		echo "seccomp: FAILED (container not running under a seccomp filter)" >&2
		sed 's/^/  /' "$m/smoke" >&2
		return 1
	fi
	if ! grep -q 'K4S_NETNS_OK' "$m/netns" 2>/dev/null; then
		echo "netns pod: FAILED (the pod that needs a CNI did not run)" >&2
		sed 's/^/  /' "$m/netns" >&2
		return 1
	fi
	if ! grep -qE 'inet[[:space:]]+10\.244\.' "$m/netns"; then
		echo "netns pod: FAILED (the container is not in the pod's network namespace)" >&2
		echo "  the CRI gave the sandbox an address, but the container reports:" >&2
		sed 's/^/    /' "$m/netns" >&2
		echo "  cause: the cgo-free runc does not join namespaces given by path, so" >&2
		echo "  the container inherits the host's. See docs/nsenter-and-runc.md." >&2
		return 1
	fi
	if ! grep -q 'K4S_DS_OK' "$m/ds" 2>/dev/null; then
		echo "daemonset: FAILED (the DaemonSet pod never wrote its marker)" >&2
		sed 's/^/  /' "$m/ds" >&2
		return 1
	fi
	if ! grep -q 'K4S_DEPLOY_OK' "$m/deploy" 2>/dev/null; then
		echo "deployment: FAILED (the Deployment pod never wrote its marker)" >&2
		sed 's/^/  /' "$m/deploy" >&2
		return 1
	fi
	echo "pod: ok (container wrote its marker)"
	echo "seccomp: ok (container runs under a filter)"
	echo "netns pod: ok (container has an address on eth0 from the CNI)"
	echo "workloads: ok (both controller-created pods wrote their markers)"
	return 0
}

# --- main -------------------------------------------------------------------
[ -f "$KERNEL" ] || { echo "missing kernel $KERNEL (run make kernel)" >&2; exit 1; }
[ -f "$BASE" ] || { echo "missing $BASE (run make image)" >&2; exit 1; }

build_control_plane
gen_pki
gen_ssh_keys
build_controlplane_image
build_cilium
cp_up
splice_image

cleanup() {
	kill "$(cat "$CP/qemu.pid" 2>/dev/null)" 2>/dev/null || true
	cp_down
}
trap cleanup EXIT

boot 1
if ! wait_node_exists; then
	echo "node did not register" >&2
	tail -30 "$CP/boot1.log" >&2
	exit 1
fi
echo "node: ok (registered)"
# The guest's sshd comes up early, and every diagnostic from here on reads the
# node over ssh rather than off the console.
wait_ssh || echo "warning: the guest's sshd did not come up" >&2
# The CNI goes on before waiting for Ready, not after: Cilium installs its own
# CNI config, so the node stays NotReady (NetworkReady=false) until the agent is
# running, and the agent is a DaemonSet that only exists once the node does.
run_cni
if ! wait_node; then
	echo "node never became Ready" >&2
	K get node "$NODE" -o wide 2>&1 | sed 's/^/  /' >&2
	K get pods -A -o wide 2>&1 | sed 's/^/  /' >&2
	tail -30 "$CP/boot1.log" >&2
	exit 1
fi
echo "node: ok (registered and Ready)"
# Both pods go on together: one hostNetwork, one asking for a CNI, which
# together are the whole statement about this node's networking.
run_pod
run_netns_pod
run_workloads
run_log_pod
collect
stop_guest
check_marker

for n in $(seq 2 "$BOOTS"); do
	log "reboot: same node image, it must rejoin and the pod must come back"
	boot "$n"
	if ! wait_node_exists; then
		echo "node did not rejoin" >&2
		tail -30 "$CP/boot$n.log" >&2
		exit 1
	fi
	echo "node: ok (rejoined)"
	# The DaemonSet object outlived the reboot, so its pod comes back on its own;
	# this waits for it, and for the node to be Ready again, before the pods that
	# need the CNI.
	run_cni
	if ! wait_node; then
		echo "node never became Ready after the reboot" >&2
		tail -30 "$CP/boot$n.log" >&2
		exit 1
	fi
	run_pod
	# The pod objects outlived the reboot, so the controllers recreate them on
	# their own; this waits for them and re-checks the addresses the CNI hands
	# out. The control plane VM kept running throughout, which is the point.
	run_netns_pod
	run_workloads
	collect
	stop_guest
	check_marker
done

echo
echo "cluster: ok"
echo "the control plane VM is killed on exit; its console log is $CP/controlplane.log"
