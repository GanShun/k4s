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
# Env: K4S_BOOTS         number of guest boots (default 2)
#
# There is no boot timeout here any more. The node no longer decides when it has
# finished -- it brings itself up and stays up -- so the guest is killed once the
# harness has what it needs, and every wait in this script is individually
# bounded. A fixed "kill it after N seconds" bound used to sit on top of that and
# mostly served to hide the waits that were too long.
#
# Evidence always comes out of the guest over ssh, never off the console: the
# console drops characters under load, a log has to be printed at exactly the
# right moment to be caught at all, and catting one to a 115200-baud line takes
# minutes, while a file read over ssh does not care when it is read. That is the
# whole reason sshd is in the image. The console is captured to a file so that a
# boot which fails to come up says so, and nothing is ever read back from it.

set -Eeuo pipefail

# Say where it died. Under `set -e` a failing command aborts the script with its
# own status and no explanation, which is how a whole leg came to end in a bare
# "Error 255" with the last successful line being "deployment: ok". Knowing the
# line number turns that from a guess into a fact.
trap 'echo "test-cluster.sh: failed at line $LINENO (exit $?)" >&2' ERR

# K4S_XTRACE=1 runs the harness with `set -x`, traced to a file. The trace names
# the command that failed, and that is the only reliable way to find a failure
# `set -e` reports as a bare exit status: the ERR trap above does not fire for an
# explicit exit or a signal, and this harness has both. Give it a file because
# the trace is far too big for the console.
if [ -n "${K4S_XTRACE:-}" ]; then
	exec 2> "${K4S_XTRACE_FILE:-/tmp/k4s-trace.log}"
	PS4='+${LINENO}: '
	set -x
fi

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
CONFIGS=$(dirname "$0")/../configs/node
# Workloads are examples; the node's own definition is configs/node. DIT bakes the
# latter into the image and these are applied to a cluster afterwards, and keeping
# them apart is what lets DIT be one build of the node definition rather than the
# only thing that can consume it.
EXAMPLES=$(dirname "$0")/../examples
POD=$EXAMPLES/smoke-pod.yaml
NETNS_POD=$EXAMPLES/netns-pod.yaml
NGINX_POD=$EXAMPLES/nginx-pod.yaml
DS=$EXAMPLES/ds-pod.yaml
LOGPOD=$EXAMPLES/log-pod.yaml
FLANNEL_DS=$EXAMPLES/flannel-ds.yaml
DEPLOY=$EXAMPLES/deploy-pod.yaml
BOOTS=${K4S_BOOTS:-2}
# flannel is the default because it needs nothing from the kernel that this one
# lacks. K4S_CNI=cilium runs the same test with Cilium instead, which needs the
# kernel built with configs/k4s-cni.config and a great deal more memory, so the
# node VM is given more room there.
CNI=${K4S_CNI:-flannel}
NODE_MEM=${K4S_NODE_MEM:-1536}
CILIUM_VERSION=${K4S_CILIUM_VERSION:-1.20.2}
HELM=${HELM:-helm}
CILIUM_YAML=$CP/cilium.yaml

ACCEL=()
[ -w /dev/kvm ] && ACCEL=(-enable-kvm -cpu host)

mkdir -p "$CP" "$NODEDIR"

# One instance at a time. Two would fight over the port forward and over the
# node VM's console log -- worse, each one's cp_down kills any control plane VM it
# finds, so a second harness silently destroys the first one's control plane and
# the node never registers.
#
# Not a lock file: an flock fd is inherited by every child, including the node
# VM, so the lock outlived the run and the next one could never start. A pid file
# with a liveness check cannot go stale like that.
#
# Deliberately NOT under $CP. That directory is where the run's own pids live and
# is exactly what gets cleaned up with a glob, and `rm -f build/controlplane/*.pid`
# took this file with it -- which is how twelve harnesses ended up running at
# once, each killing the others' control planes.
LOCK=$CP/../k4s-test.pid
if [ -f "$LOCK" ]; then
	oldpid=$(cat "$LOCK" 2>/dev/null || true)
	if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
		echo "another test-cluster.sh is already running (pid $oldpid)" >&2
		echo "if it is not, remove $LOCK" >&2
		exit 1
	fi
fi
echo $$ > "$LOCK"

# Refuse to start if either port is already taken. A stray VM from an earlier
# probe or a forgotten run holds the port forward, so this run's node VM cannot
# bind it -- and then the harness talks over ssh to the *other* machine and reads
# a filesystem belonging to a different boot. That is not hypothetical: it
# produced several rounds of confident, wrong conclusions from another node's
# /tmp, including a whole theory about kubelet never starting.
for p in "$PORT" "$SSH_PORT"; do
	if ss -ltn 2>/dev/null | grep -q ":$p "; then
		echo "port $p is already in use -- a stray VM or a control plane from an earlier run?" >&2
		exit 1
	fi
done

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
	# This image carries the same uinit applet as the node's, and tells it which
	# role it is by this file. The two roles are one package because u-root builds
	# bb with GO111MODULE=off and links only the packages named on its command
	# line, so an applet cannot import a sibling package.
	printf 'control-plane\n' > "$CP/role"
	./u-root/u-root -o "$CP_IMAGE" \
		-files "$CP/role":etc/k4s/role \
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
	u-root/cmds/core/* \
	./cmd/uinit >/dev/null
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
	# Nothing is fed to this guest either. It brings itself up from /bbin/uinit,
	# which is the control-plane role of cmd/uinit, and that polls etcd and the
	# apiserver before it says it is done. The port forward is how both the host
	# and the node reach the apiserver: the host at 127.0.0.1:6443, and the node
	# at 10.0.2.2:6443, which is the host from inside the node's user-mode
	# network.
	qemu-system-x86_64 -M q35 -m 1024 -smp 2 "${ACCEL[@]}" \
		-netdev user,id=n0,hostfwd=tcp:127.0.0.1:$PORT-:$PORT \
		-device virtio-net-pci,netdev=n0 \
		-kernel "$KERNEL" -initrd "$CP_IMAGE" \
		-append "console=ttyS0,115200 panic=-1" \
		-display none -monitor none -serial "file:$CP/controlplane.log" \
		-no-reboot 2>> "$CP/controlplane.log" &
	echo $! > "$CP/controlplane.pid"
	if ! kill -0 "$(cat "$CP/controlplane.pid")" 2>/dev/null; then
		echo "the control plane VM exited at startup" >&2
		tail -20 "$CP/controlplane.log" >&2
		exit 1
	fi
	# The gate is the apiserver answering on the forwarded port, and nothing
	# more. The guest's uinit has already asked etcd and the apiserver whether
	# they are up, and the guard above established that nothing else was serving
	# this port, so a health check here is this VM's apiserver.
	#
	# This replaced three greps of the guest's console for markers it printed
	# itself. The marker for "ready" was only ever a proxy for this check, and the
	# marker for "apiserver: ok" was a grep of a log for the word "Error", which
	# cannot tell a healthy service from one that failed in a way it did not log.
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

	# Drop the agent's postStart hook, and its preStop hook with it.
	#
	# Both fail on this node. Verified, not assumed: with the hooks left in, the
	# agent goes CrashLoopBackOff with `Warning FailedPostStartHook` and
	# `Warning FailedPreStopHook` inside 40s, and the kubelet kills the container --
	# which is the agent exiting 2 with an empty log while the binary itself runs
	# fine. The postStart hook's own job, deleting iptables rules left behind by
	# the AWS VPC CNI plugin, is a no-op on a non-AWS node; the failure is that it
	# runs `iptables-save | grep -c` under `set -o errexit` and the agent image does
	# not have what it needs.
	#
	# The tempting reading -- Cilium's image bundles iptables, so the hook should
	# work and this strip is treating a cause that isn't there -- is what
	# K4S_CILIUM_STRIP_HOOK=0 exists to test, and it is falsified. What is *not*
	# established is which command is missing; preStop failing too means it is not
	# just the VPC-CNI cleanup, so "no iptables" is a guess that this does not
	# confirm.
	if [ "${K4S_CILIUM_STRIP_HOOK:-1}" = 1 ]; then
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
	fi
}

# --- node image -------------------------------------------------------------
splice_image() {
	# Only the kubeconfig and the ssh keys. Cilium's conflist is *not* pre-placed:
	# the agent writes it itself and containerd picks it up, which is what happens
	# on any other node. Pre-placing it was a workaround for a race, and the race
	# is better fixed where it happens -- see run_cilium.
	log "splicing the node kubeconfig and ssh keys into $NODE_IMAGE"
	./u-root/u-root -base "$BASE" -nocmd \
		-files "$NODEDIR/kubeconfig:etc/kubernetes/kubeconfig" \
		-files "$SSH/authorized_keys:etc/ssh/authorized_keys" \
		-files "$SSH/host_rsa:etc/ssh/host_rsa" \
		-initcmd="" -defaultsh="" -o "$NODE_IMAGE" >/dev/null
}

# --- guest ------------------------------------------------------------------
boot() {
	local n=$1
	log "booting the node image (run $n/$BOOTS)"
	# Nothing is fed to this guest. The node brings itself up: u-root's init runs
	# /bin/uinit, a Go program built from cmd/uinit, which brings up the network,
	# sshd, the mounts and cgroups, containerd and kubelet. The console is still
	# captured, because that is where a boot that fails to come up says so first.
	#
	# -serial file: rather than -nographic, so nothing depends on the guest's stdin.
	qemu-system-x86_64 -M q35 -m "$NODE_MEM" -smp 2 "${ACCEL[@]}" \
		-netdev user,id=n0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:2022 \
		-device virtio-net-pci,netdev=n0 \
		-kernel "$KERNEL" -initrd "$NODE_IMAGE" \
		-append "console=ttyS0,115200 panic=-1 cgroup_no_v1=all" \
		-display none -monitor none -serial "file:$CP/boot$n.log" \
		-no-reboot 2>> "$CP/boot$n.log" &
	echo $! > "$CP/qemu.pid"
}

# The harness is responsible for stopping the guest when it's done, the guest
# simply waits for termination.
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

# Two things in guest_get are load-bearing rather than stylistic.
#
# `timeout`, because ConnectTimeout bounds only the TCP connect -- and QEMU's user
# networking port forward accepts the connection immediately whether or not
# anything is listening in the guest. So a connect to a guest whose sshd has not
# started yet succeeds, and ssh then waits forever for a banner that is never
# coming. That hung a whole run for fifteen minutes with no output at all, in
# wait_ssh, which is called the moment the node boots.
#
# LogLevel=ERROR rather than -q, and a non-zero status reported rather than
# swallowed: with -q a dropped connection produced the same empty output as an
# empty file, which made "the kubelet log is empty" and "ssh did not work"
# indistinguishable.
#
# The `if` is load-bearing: `out=$(cmd); rc=$?` does not survive set -e, because the
# shell exits on the failed assignment and `rc=$?` never runs -- the idiom written
# to *handle* a failure is defeated by the option that makes failures fatal. An ERR
# trap is likewise not inherited by shell functions without `set -E`.
guest_get() {
	local out rc
	if out=$(timeout 8 ssh -o LogLevel=ERROR -o StrictHostKeyChecking=no \
		-o UserKnownHostsFile=/dev/null -o BatchMode=yes \
		-o ConnectTimeout=5 -i "$SSH/client" -p "$SSH_PORT" \
		root@127.0.0.1 "$@" 2>&1); then
		rc=0
	else
		rc=$?
	fi
	if [ "$rc" = 124 ]; then
		printf '(ssh to the node timed out)\n'
		return 0
	fi
	if [ "$rc" != 0 ]; then
		if [ -n "$out" ]; then
			printf '(ssh to the node failed, rc=%s: %s)\n' "$rc" "$out"
		else
			printf '(ssh to the node failed, rc=%s, and said nothing)\n' "$rc"
		fi
		return 0
	fi
	printf '%s\n' "$out"
}

# Bounded, short, and loud. Each attempt is capped by guest_get's timeout, and
# the count is small: the point of this function is to find out whether the
# node's sshd is up, not to wait fifteen minutes for it. A silent 45-attempt
# version of this is what turned a broken ssh into a run that hung until its
# outer timeout with no output at all.
wait_ssh() {
	local i out
	for i in $(seq 1 10); do
		out=$(guest_get true)
		if [ -z "$out" ]; then
			return 0
		fi
		echo "  ssh attempt $i: $out" >&2
		sleep 2
	done
	return 1
}

# Wait for a marker to appear in the guest, then read it. Running does not mean
# the container has run its first instruction, and /var/log is a tmpfs, so after a
# reboot the marker is gone and has to be written again.
#
# Matched on the marker's token, not on the file being non-empty: guest_get
# returns 0 and prints its diagnostic to stdout on every failure path, so an ssh
# blip would both satisfy a size test and be recorded as if it were evidence.
wait_marker() {
	local guest_path=$1 out=$2 want=$3 i
	for i in $(seq 1 15); do
		guest_get "cat $guest_path 2>/dev/null" > "$out"
		if grep -q "$want" "$out"; then
			return 0
		fi
		sleep 2
	done
	return 0
}

# The guest's own daemon logs, kept for a second look. collect() and diag() both
# want the same set, so it is written once here rather than twice.
grab_guest_logs() {
	local d=$1 m
	for m in kubelet.log containerd.log sshd.log; do
		guest_get "cat /tmp/$m" > "$d/$m" 2>/dev/null || true
	done
	guest_get 'cat /var/log/pods/*cilium-*/cilium-agent/*.log' > "$d/cilium-agent.log" 2>/dev/null || true
	# flanneld runs out of the node's own /bbin in a DaemonSet and writes here.
	# Nothing asserts on it; it is collected because it is the first thing worth
	# reading when the pod network misbehaves.
	guest_get 'cat /var/log/k4s-flannel/flannel.log' > "$d/flannel.log" 2>/dev/null || true
}

# Everything the checks and the diagnostics need, gathered while the guest is up
# and before stop_guest -- none of it survives the VM. Quiet; diag() prints the
# summary when a check fails.
collect() {
	local d=$CP/diag m
	mkdir -p "$d" "$CP/markers"
	# Cleared, not merely created: a marker left by an earlier run would otherwise
	# let a check pass on evidence this run did not produce.
	rm -f "$CP/markers"/*
	for m in smoke netns ds deploy; do
		case $m in
			smoke)  want=K4S_POD_OK ;;
			netns)  want=K4S_NETNS_OK ;;
			ds)     want=K4S_DS_OK ;;
			deploy) want=K4S_DEPLOY_OK ;;
		esac
		wait_marker "/var/log/k4s-$m/result" "$CP/markers/$m" "$want"
	done
	wait_marker '/var/log/pods/*k4s-log*/log/*.log' "$CP/markers/log" K4S_LOG_OK
	# The off-the-shelf pod has no marker to read: nginx has no shell command to
	# hang one off and writes nothing to a hostPath. The node fetches its page
	# over the pod network instead, which is also the assertion that the pod
	# network carries real traffic and not just that an interface has an
	# address.
	#
	# Through a file, not `-O -`: wget maps `-O -` to /dev/stdout, and /dev here
	# is a bare devtmpfs with no udev, so /dev/stdout does not exist and the
	# write fails silently. wget's stderr is kept in the marker on purpose, so a
	# failure here says why instead of leaving an empty file.
	local ngip i
	ngip=$(K get pod k4s-nginx -o jsonpath='{.status.podIP}' 2>/dev/null || true)
	if [[ -n "$ngip" ]]; then
		# Retried for the same reason as wait_marker: after a reboot the page has
		# to be served again, and an empty marker should mean "it never served"
		# rather than "we asked too early".
		for i in $(seq 1 15); do
			guest_get "wget -O /tmp/k4s-nginx.html http://$ngip/ 2>&1; echo '--- page ---'; cat /tmp/k4s-nginx.html 2>&1" > "$CP/markers/nginx"
			if grep -qi 'Welcome to nginx' "$CP/markers/nginx"; then
				break
			fi
			sleep 2
		done
	fi
	grab_guest_logs "$d"
	guest_get 'ls /etc/cni/net.d; ls /opt/cni/bin' > "$d/cni-files" 2>/dev/null || true
}

# What a failed check prints: the markers, read out of the guest over ssh while
# it is still alive.
diag() {
	local d=$CP/diag m
	mkdir -p "$d"
	echo "  --- markers ---" >&2
	for m in smoke netns ds deploy; do
		printf '  %-7s %s\n' "$m" \
			"$(guest_get "cat /var/log/k4s-$m/result 2>/dev/null" | tr '\n' ' ')" >&2
	done
	echo "  --- is the node's containerd still alive? ---" >&2
	guest_get 'ctr version' | sed 's/^/  /' >&2
	guest_get 'ls -la /tmp' | sed 's/^/  /' >&2
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
	grab_guest_logs "$d"
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

# An off-the-shelf workload: stock nginx, pulled from a public registry and run
# as its maintainers shipped it. It is the only pod here that has to *serve*
# rather than merely run, and it is the only one with no marker to read back --
# nginx has no shell command to hang one off and writes nothing to a hostPath.
# So this waits for the pod, and the fetch that proves it answers happens over
# ssh while the guest is still up (see collect and check_marker).
#
# Ready, not just Running: the pod spec carries a readiness probe, so kubelet
# itself has fetched the page before this returns. That makes "nginx is serving"
# something the node asserts about itself rather than only something the harness
# observes from outside.
run_nginx() {
	log "applying the off-the-shelf nginx pod"
	reapply "$NGINX_POD"
	local i ph ready ip
	for i in $(seq 1 90); do
		ph=$(K get pod k4s-nginx -o jsonpath='{.status.phase}' 2>/dev/null || true)
		ready=$(K get pod k4s-nginx \
			-o jsonpath='{.status.containerStatuses[0].ready}' \
			2>/dev/null || true)
		if [ "$ph" = Running ] && [ "$ready" = true ]; then
			ip=$(K get pod k4s-nginx -o jsonpath='{.status.podIP}' 2>/dev/null || true)
			echo "nginx pod: Running and Ready at ${ip:-<none>}"
			return 0
		fi
		sleep 2
	done
	echo "nginx pod did not become Running and Ready" >&2
	K describe pod k4s-nginx 2>&1 | tail -25 | sed 's/^/  /' >&2
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
	K apply -f "$CILIUM_YAML" >/dev/null
	local i ready waiting lastwaiting=""
	# Generous, because this covers pulling Cilium's images. The node is strictly
	# RAM-only with no image cache, so every boot re-pulls about 300 MiB of them,
	# and that takes minutes. Sixty seconds was enough to fail on a pull that was
	# still in progress and reported as ImagePullBackOff only because it had not
	# finished -- the fast-fail below is what catches a real pull failure, so
	# waiting longer here costs nothing but time on a run that was going to fail
	# anyway.
	for i in $(seq 1 150); do
		ready=$(K get daemonset cilium -n kube-system -o jsonpath='{.status.numberReady}' 2>/dev/null || true)
		if [ "${ready:-0}" = 1 ]; then
			# The agent is ready before it has written its CNI config -- the
			# cni-config cell runs after the health endpoint is up -- and
			# containerd's CRI loads that directory at init and *ignores Create
			# events*, so a pod applied in that gap gets whatever was loaded at
			# init: flannel's plugin, or nothing at all. Wait for the directory
			# to say what the pods need before handing it any.
			local listing
			for _ in $(seq 1 30); do
				listing=$(guest_get 'ls /etc/cni/net.d')
				# Only that Cilium's conflist is there, matched exactly. Whether
				# flannel's is still present does not matter: go-cni sorts the
				# directory lexicographically and 05-cilium wins. An earlier
				# version also required flannel's to be gone, which was wrong
				# twice over -- Cilium does not delete it, it renames it to
				# 10-flannel.conflist.cilium_bak, and a substring grep for
				# 10-flannel.conflist matched that backup name.
				if printf '%s' "$listing" | grep -q '^05-cilium\.conflist$'; then
					echo "cilium: ok (the agent is running, and its CNI config is on the node)"
					return 0
				fi
				sleep 2
			done
			echo "cilium: FAILED (the agent is up but never wrote its CNI config)" >&2
			diag
			return 1
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
	# diag, because the interesting part of a failed pull is in the node's own
	# kubelet log, and `describe` truncates the event text to the point of being
	# useless. Without this a failed Cilium run says only that the agent was not
	# ready, which is true of every possible cause.
	diag
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
	# The off-the-shelf pod. The only check here that is about a *published
	# image* serving rather than about k4s code running: stock nginx, fetched by
	# the node over the pod network.
	if ! grep -qi 'Welcome to nginx' "$m/nginx" 2>/dev/null; then
		echo "nginx: FAILED (the node could not fetch the page from the pod)" >&2
		head -c 400 "$m/nginx" 2>/dev/null | sed 's/^/  /' >&2
		return 1
	fi
	# The log pod's stdout only lands in a file if the node's log path works, so
	# this asserts the plumbing rather than the pod. Without it the pod was
	# applied, waited on and collected, and its evidence read by nothing.
	if ! grep -q 'K4S_LOG_OK' "$m/log" 2>/dev/null; then
		echo "log pod: FAILED (its stdout did not reach /var/log/pods)" >&2
		sed 's/^/  /' "$m/log" >&2
		return 1
	fi
	echo "pod: ok (container wrote its marker)"
	echo "seccomp: ok (container runs under a filter)"
	echo "netns pod: ok (container has an address on eth0 from the CNI)"
	echo "workloads: ok (both controller-created pods wrote their markers)"
	echo "log pod: ok (the pod's stdout reached /var/log/pods)"
	echo "nginx: ok (the node fetched stock nginx's page over the pod network)"
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
# Wait for the Node object first: it is an apiserver poll and needs no ssh, and
# asking a node for ssh the instant it boots is a race that costs a timeout every
# time sshd is not up yet.
if ! wait_node_exists; then
	echo "node did not register" >&2
	wait_ssh || echo "  (and its sshd is not answering either)" >&2
	diag
	tail -30 "$CP/boot1.log" >&2
	exit 1
fi
echo "node: ok (registered)"
wait_ssh || echo "warning: the node's sshd did not come up" >&2
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
run_nginx
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
	run_nginx
	run_workloads
	collect
	stop_guest
	check_marker
done

echo
echo "cluster: ok"
echo "the control plane VM is killed on exit; its console log is $CP/controlplane.log"
