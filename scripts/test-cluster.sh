#!/bin/bash
#
# M1 join test: a throwaway control plane on the host, and kubelet running in
# the QEMU guest as a node.
#
# Steps:
#   1. build etcd, kube-apiserver and kubectl from the pinned sources
#   2. generate a throwaway CA and a kubelet kubeconfig from it
#   3. start etcd + kube-apiserver on the host (no scheduler, no
#      controller-manager: the smoke pod is pinned with nodeName)
#   4. splice the kubeconfig into a copy of the initramfs
#   5. boot the node image, wait for it to register, create the pod, and check
#      the container wrote its marker
#   5b. also create a pod that asks for its own network namespace, and check it
#      gets an address from the CNI
#   6. boot it again, unchanged, and check it rejoins and the pod returns
#
# The kubeconfig is issued per run and spliced in; it is never committed.
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
GUEST=$(dirname "$0")/cluster-check.sh
POD=$(dirname "$0")/../configs/node/smoke-pod.yaml
NETNS_POD=$(dirname "$0")/../configs/node/netns-pod.yaml
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
		&& [ -x "$CP/kube-controller-manager" ]; then
		return 0
	fi
	log "building control plane binaries (etcd, kube-apiserver, kubectl, controller-manager)"
	mkdir -p "$CP"
	(cd etcd/server && GOWORK=off CGO_ENABLED=0 go build -o ../../build/controlplane/etcd .)
	(cd kubernetes && CGO_ENABLED=0 env -u GOARCH -u GOOS \
		go build -mod=vendor -o ../build/controlplane/kube-apiserver ./cmd/kube-apiserver)
	(cd kubernetes && CGO_ENABLED=0 env -u GOARCH -u GOOS \
		go build -mod=vendor -o ../build/controlplane/kubectl ./cmd/kubectl)
	(cd kubernetes && CGO_ENABLED=0 env -u GOARCH -u GOOS \
		go build -mod=vendor -o ../build/controlplane/kube-controller-manager ./cmd/kube-controller-manager)
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
	# The controller-manager runs on the host, so it uses the admin identity and
	# the loopback address. It needs to be able to patch Nodes, which is what
	# gives a node its spec.podCIDR -- and flannel refuses to start without one.
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

cp_down() {
	for p in apiserver etcd controller-manager; do
		if [ -f "$CP/$p.pid" ]; then
			kill "$(cat "$CP/$p.pid")" 2>/dev/null || true
			rm -f "$CP/$p.pid"
		fi
	done
	kill_binaries
	sleep 1
}

# Kill anything still running out of $CP that the pid files did not account for,
# which is what an interrupted run leaves behind.
#
# This matches /proc/<pid>/exe rather than the command line. `pkill -f
# build/controlplane/etcd` matches *any* process whose command line merely
# mentions that path, and the caller of this script is such a process as soon as
# it is wrapped in something like `bash -c '... build/controlplane/etcd ...'`,
# so it killed its own caller. Matching the executable cannot do that.
kill_binaries() {
	local target pid exe
	for target in "$CP/kube-apiserver" "$CP/etcd" "$CP/kube-controller-manager"; do
		target=$(readlink -f "$target" 2>/dev/null) || continue
		for pid in /proc/[0-9]*; do
			pid=${pid#/proc/}
			exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null) || continue
			# A binary replaced while running reports as "<path> (deleted)".
			if [ "${exe% (deleted)}" = "$target" ]; then
				kill "$pid" 2>/dev/null || true
			fi
		done
	done
}

wait_apiserver() {
	local i
	for i in $(seq 1 60); do
		if K get --raw=/healthz >/dev/null 2>&1; then
			return 0
		fi
		sleep 1
	done
	return 1
}

cp_up() {
	cp_down
	rm -rf "$CP/etcd-data"
	log "starting etcd and kube-apiserver"
	nohup "$CP/etcd" --data-dir "$CP/etcd-data" \
		--listen-client-urls http://127.0.0.1:2379 \
		--advertise-client-urls http://127.0.0.1:2379 \
		--listen-peer-urls http://127.0.0.1:2380 \
		--initial-advertise-peer-urls http://127.0.0.1:2380 \
		--initial-cluster default=http://127.0.0.1:2380 > "$CP/etcd.log" 2>&1 &
	echo $! > "$CP/etcd.pid"
	sleep 3
	nohup "$CP/kube-apiserver" \
		--etcd-servers=http://127.0.0.1:2379 --secure-port="$PORT" --bind-address=0.0.0.0 \
		--tls-cert-file="$PKI/apiserver.crt" --tls-private-key-file="$PKI/apiserver.key" \
		--client-ca-file="$PKI/ca.crt" \
		--service-account-key-file="$PKI/sa.pub" \
		--service-account-signing-key-file="$PKI/sa.key" \
		--service-account-issuer="$SERVER" --service-cluster-ip-range=10.96.0.0/12 \
		--authorization-mode=AlwaysAllow --disable-admission-plugins=ServiceAccount \
		--allow-privileged=true > "$CP/apiserver.log" 2>&1 &
	echo $! > "$CP/apiserver.pid"
	if ! wait_apiserver; then
		echo "apiserver did not become healthy" >&2
		tail -20 "$CP/apiserver.log" >&2
		exit 1
	fi
	echo "apiserver: ok"

	# The controller-manager is here for --allocate-node-cidrs: a node only gets
	# its spec.podCIDR from this, and flannel refuses to register without one
	# ("node %q pod cidr not assigned"). The cluster CIDR has to match flannel's
	# network config, and the mask size is what makes each node a /24, which is
	# flannel's default subnet length.
	log "starting kube-controller-manager (node CIDR allocation)"
	nohup "$CP/kube-controller-manager" \
		--kubeconfig="$PKI/admin.kubeconfig" \
		--allocate-node-cidrs=true \
		--cluster-cidr=10.244.0.0/16 \
		--node-cidr-mask-size=24 \
		--service-cluster-ip-range=10.96.0.0/12 \
		--service-account-private-key-file="$PKI/sa.key" \
		--root-ca-file="$PKI/ca.crt" \
		--leader-elect=false > "$CP/controller-manager.log" 2>&1 &
	echo $! > "$CP/controller-manager.pid"
	sleep 3
	if ! kill -0 "$(cat "$CP/controller-manager.pid")" 2>/dev/null; then
		echo "controller-manager exited at startup" >&2
		tail -20 "$CP/controller-manager.log" >&2
		exit 1
	fi
	echo "controller-manager: ok (node CIDR allocation on)"
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
	echo "pod: ok (container wrote its marker)"
	echo "seccomp: ok (container runs under a filter)"
	echo "netns pod: ok (container has an address on eth0 from the CNI)"
	rm -f "$clean"
	return 0
}

# --- main -------------------------------------------------------------------
[ -f "$KERNEL" ] || { echo "missing kernel $KERNEL (run make kernel)" >&2; exit 1; }
[ -f "$BASE" ] || { echo "missing $BASE (run make image)" >&2; exit 1; }

build_control_plane
gen_pki
cp_up
splice_image

trap 'kill "$(cat "$CP/qemu.pid" 2>/dev/null)" 2>/dev/null || true' EXIT

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
	# The pod object outlived the reboot, so kubelet recreates it on its own;
	# this waits for it and re-checks the address the CNI hands out.
	run_netns_pod
	wait_qemu
	check_marker "$CP/boot$n.log"
done

echo
echo "cluster: ok"
echo "control plane left running (stop with: kill \$(cat $CP/etcd.pid $CP/apiserver.pid))"
