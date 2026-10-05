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
#   5. boot the node image, wait for it to register, create the pod, and check
#      the container wrote its marker
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
# Env: K4S_BOOT_TIMEOUT  seconds to allow each guest boot (default 240)
#      K4S_BOOTS         number of guest boots (default 2)

set -euo pipefail

KERNEL=${1:-build/kernel/arch/x86/boot/bzImage}
BASE=${2:-initramfs.cpio}

CP=build/controlplane
PKI=$CP/pki
NODEDIR=$CP/node
NODE=k4s-node-1
PORT=6443
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
DEPLOY=$CONFIGS/deploy-pod.yaml
BOOT_TIMEOUT=${K4S_BOOT_TIMEOUT:-240}
BOOTS=${K4S_BOOTS:-2}

ACCEL=()
[ -w /dev/kvm ] && ACCEL=(-enable-kvm -cpu host)

mkdir -p "$CP" "$NODEDIR"

log() { printf '\n=== %s ===\n' "$*"; }

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
	cp_down
	# Anything already answering here would hold the port, make QEMU's forward
	# fail, and then satisfy the health check below -- so the run would silently
	# test against a stale control plane instead of this VM. That is not
	# hypothetical: a leftover host-side control plane from before this became a
	# VM did exactly that, and the pods that should have been scheduled by the
	# scheduler in the VM sat Pending against a control plane that has none.
	if K get --raw=/healthz >/dev/null 2>&1; then
		echo "something is already serving 127.0.0.1:$PORT" >&2
		echo "a stale control plane from an earlier run? stop it before running this test" >&2
		exit 1
	fi
	log "booting the control plane VM"
	# Hold stdin open past the script so gosh does not see EOF and exit. The
	# port forward is how both the host and the node reach the apiserver: the
	# host at 127.0.0.1:6443, and the node at 10.0.2.2:6443, which is the host
	# from inside the node's user-mode network.
	( cat "$CP_GUEST"; sleep $((BOOT_TIMEOUT + 60)) ) | \
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
	if ! wait_apiserver; then
		echo "the apiserver never became healthy in the control plane VM" >&2
		tail -40 "$CP/controlplane.log" >&2
		exit 1
	fi
	echo "apiserver: ok (in the control plane VM, with a scheduler)"
}

# --- node image -------------------------------------------------------------
splice_image() {
	log "splicing the node kubeconfig into $NODE_IMAGE"
	./u-root/u-root -base "$BASE" -nocmd \
		-files "$NODEDIR/kubeconfig:etc/kubernetes/kubeconfig" \
		-initcmd="" -defaultsh="" -o "$NODE_IMAGE" >/dev/null
}

# --- guest ------------------------------------------------------------------
boot() {
	local n=$1
	log "booting the node image (run $n/$BOOTS)"
	# Hold stdin open past the script so gosh does not see EOF and exit.
	( cat "$GUEST"; sleep $((BOOT_TIMEOUT + 60)) ) | \
		qemu-system-x86_64 -M q35 -m 1536 -smp 2 "${ACCEL[@]}" \
			-netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
			-kernel "$KERNEL" -initrd "$NODE_IMAGE" \
			-append "console=ttyS0,115200 panic=-1 cgroup_no_v1=all" \
			-nographic -no-reboot > "$CP/boot$n.log" 2>&1 &
	echo $! > "$CP/qemu.pid"
}

wait_qemu() {
	local pid i
	pid=$(cat "$CP/qemu.pid")
	for i in $(seq 1 $((BOOT_TIMEOUT + 60))); do
		if ! kill -0 "$pid" 2>/dev/null; then
			return 0
		fi
		sleep 1
	done
	kill "$pid" 2>/dev/null || true
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

run_pod() {
	log "applying the smoke pod"
	K apply -f "$POD" >/dev/null
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
	K apply -f "$NETNS_POD" >/dev/null
	local i ph ip
	for i in $(seq 1 90); do
		ph=$(K get pod k4s-netns -o jsonpath='{.status.phase}' 2>/dev/null || true)
		if [ "$ph" = Running ]; then
			ip=$(K get pod k4s-netns -o jsonpath='{.status.podIP}' 2>/dev/null || true)
			if [[ "$ip" == 10.244.* ]]; then
				echo "pod IP: $ip (from the flannel subnet)"
				return 0
			fi
			echo "netns pod: FAILED (Running, but its address is ${ip:-<none>}, not from 10.244.0.0/16)" >&2
			return 1
		fi
		sleep 2
	done
	echo "netns pod: FAILED (never reached Running)" >&2
	K describe pod k4s-netns 2>&1 | tail -25 | sed 's/^/  /' >&2
	return 1
}

# The DaemonSet controller and the scheduler both live in the control plane VM,
# so these only become ready if it is doing its job: the DaemonSet controller
# assigns its own node, and nothing pins the Deployment, so it needs the
# scheduler.
run_workloads() {
	log "applying a DaemonSet and a Deployment"
	K apply -f "$DS" >/dev/null
	K apply -f "$DEPLOY" >/dev/null
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
	local clean
	clean=$(mktemp -t k4s-clean.XXXXXX)
	sed 's/\x1b\[[0-9;]*[A-Za-z]//g' "$1" | grep -v '^\$ ' > "$clean" || true
	if ! grep -q 'K4S_POD_OK' "$clean"; then
		echo "pod: FAILED (no K4S_POD_OK in the guest log, $1)" >&2
		tail -50 "$clean" >&2
		rm -f "$clean"
		return 1
	fi
	# The container reports Seccomp: 2 (SECCOMP_MODE_FILTER) only if a filter
	# is actually installed, so this is the assertion that the cgo-free runc
	# enforced the profile rather than merely starting the container.
	if ! grep -qE 'Seccomp:[[:space:]]+2' "$clean"; then
		echo "seccomp: FAILED (container not running under a seccomp filter)" >&2
		tail -30 "$clean" >&2
		rm -f "$clean"
		return 1
	fi
	if ! grep -q 'K4S_NETNS_OK' "$clean"; then
		echo "netns pod: FAILED (no K4S_NETNS_OK: the pod that needs a CNI did not run, $1)" >&2
		tail -50 "$clean" >&2
		rm -f "$clean"
		return 1
	fi
	if ! grep -qE 'inet[[:space:]]+10\.244\.' "$clean"; then
		echo "netns pod: FAILED (the container is not in the pod's network namespace)" >&2
		echo "  the CRI gave the sandbox an address, but the container reports this interface:" >&2
		grep -a -A2 'K4S_NETNS_OK' "$clean" | sed 's/^/    /' >&2 || true
		echo "  cause: the cgo-free runc does not join namespaces given by path, so the" >&2
		echo "  container inherits the host's. See docs/nsenter-and-runc.md." >&2
		rm -f "$clean"
		return 1
	fi
	if ! grep -q 'K4S_DS_OK' "$clean"; then
		echo "daemonset: FAILED (the DaemonSet pod never wrote its marker, $1)" >&2
		tail -40 "$clean" >&2
		rm -f "$clean"
		return 1
	fi
	if ! grep -q 'K4S_DEPLOY_OK' "$clean"; then
		echo "deployment: FAILED (the Deployment pod never wrote its marker, $1)" >&2
		tail -40 "$clean" >&2
		rm -f "$clean"
		return 1
	fi
	echo "pod: ok (container wrote its marker)"
	echo "seccomp: ok (container runs under a filter)"
	echo "netns pod: ok (container has an address on eth0 from the CNI)"
	echo "workloads: ok (both controller-created pods wrote their markers)"
	rm -f "$clean"
	return 0
}

# --- main -------------------------------------------------------------------
[ -f "$KERNEL" ] || { echo "missing kernel $KERNEL (run make kernel)" >&2; exit 1; }
[ -f "$BASE" ] || { echo "missing $BASE (run make image)" >&2; exit 1; }

build_control_plane
gen_pki
build_controlplane_image
cp_up
splice_image

cleanup() {
	kill "$(cat "$CP/qemu.pid" 2>/dev/null)" 2>/dev/null || true
	cp_down
}
trap cleanup EXIT

boot 1
if ! wait_node; then
	echo "node did not register" >&2
	tail -30 "$CP/boot1.log" >&2
	exit 1
fi
echo "node: ok (registered and Ready)"
# Both pods go on together: one hostNetwork, one asking for a CNI, which
# together are the whole statement about this node's networking.
run_pod
run_netns_pod
run_workloads
wait_qemu
check_marker "$CP/boot1.log"

for n in $(seq 2 "$BOOTS"); do
	log "reboot: same node image, it must rejoin and the pod must come back"
	boot "$n"
	if ! wait_node; then
		echo "node did not rejoin" >&2
		tail -30 "$CP/boot$n.log" >&2
		exit 1
	fi
	echo "node: ok (rejoined)"
	run_pod
	# The pod objects outlived the reboot, so the controllers recreate them on
	# their own; this waits for them and re-checks the addresses the CNI hands
	# out. The control plane VM kept running throughout, which is the point.
	run_netns_pod
	run_workloads
	wait_qemu
	check_marker "$CP/boot$n.log"
done

echo
echo "cluster: ok"
echo "the control plane VM is killed on exit; its console log is $CP/controlplane.log"
