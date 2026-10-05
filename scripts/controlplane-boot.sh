#!/bin/sh
#
# Guest side of the control plane VM, piped into the initramfs shell.
#
# This is a throwaway Kubernetes control plane in a VM of its own: etcd, the
# apiserver, the controller-manager and the scheduler, with the PKI baked into
# the image. It exists as a VM rather than as processes on the host because the
# node should join something shaped like a real cluster -- the controller-manager
# is what assigns pod CIDRs, runs DaemonSets and Deployments and issues service
# account tokens, and none of that exists without it.
#
# The host reaches the apiserver through a QEMU port forward on 127.0.0.1:6443.
# The node reaches it at 10.0.2.2:6443, which is the host from inside the node's
# user-mode network, and the same forward carries it here. The apiserver
# certificate carries both addresses.
#
# Every line must be a complete command: this is piped into gosh.

echo "K4S_CP_START"

# --- network ----------------------------------------------------------------
ip link set eth0 up
dhclient -ipv6=false -timeout 10 eth0
echo "nameserver 10.0.2.3" > /etc/resolv.conf

# --- filesystems ------------------------------------------------------------
# No disk anywhere: etcd's data directory is RAM, and this VM is thrown away.
mkdir -p /var/lib/etcd
mount -t tmpfs tmpfs /var/lib/etcd

# --- etcd -------------------------------------------------------------------
etcd --data-dir /var/lib/etcd --listen-client-urls http://127.0.0.1:2379 --advertise-client-urls http://127.0.0.1:2379 --listen-peer-urls http://127.0.0.1:2380 --initial-advertise-peer-urls http://127.0.0.1:2380 --initial-cluster default=http://127.0.0.1:2380 </dev/null >/tmp/etcd.log 2>&1 &
sleep 5

# --- apiserver --------------------------------------------------------------
# ServiceAccount admission is on here, unlike the host-side control plane this
# replaced. With the controller-manager running the token controller, pods then
# get a service account token, which is what anything talking to the apiserver
# from inside a pod needs -- the Cilium agent and operator, for instance.
kube-apiserver --etcd-servers=http://127.0.0.1:2379 --secure-port=6443 --bind-address=0.0.0.0 --tls-cert-file=/etc/kubernetes/pki/apiserver.crt --tls-private-key-file=/etc/kubernetes/pki/apiserver.key --client-ca-file=/etc/kubernetes/pki/ca.crt --service-account-key-file=/etc/kubernetes/pki/sa.pub --service-account-signing-key-file=/etc/kubernetes/pki/sa.key --service-account-issuer=https://10.0.2.2:6443 --service-cluster-ip-range=10.96.0.0/12 --authorization-mode=AlwaysAllow --allow-privileged=true </dev/null >/tmp/apiserver.log 2>&1 &
sleep 15

# --- controller-manager and scheduler ---------------------------------------
# --allocate-node-cidrs is what gives a node its spec.podCIDR, which flannel
# refuses to register without. The cluster CIDR matches flannel's network config
# and the mask size is what makes each node a /24, which is flannel's default
# subnet length.
kube-controller-manager --kubeconfig=/etc/kubernetes/admin.kubeconfig --allocate-node-cidrs=true --cluster-cidr=10.244.0.0/16 --node-cidr-mask-size=24 --service-cluster-ip-range=10.96.0.0/12 --service-account-private-key-file=/etc/kubernetes/pki/sa.key --root-ca-file=/etc/kubernetes/pki/ca.crt --leader-elect=false </dev/null >/tmp/controller-manager.log 2>&1 &
kube-scheduler --kubeconfig=/etc/kubernetes/admin.kubeconfig --leader-elect=false </dev/null >/tmp/scheduler.log 2>&1 &
sleep 10

# --- diagnostics ------------------------------------------------------------
echo "--- etcd log tail ---"
tail -n 5 /tmp/etcd.log
echo "--- apiserver log tail ---"
tail -n 5 /tmp/apiserver.log
echo "--- controller-manager log tail ---"
tail -n 5 /tmp/controller-manager.log

echo "K4S_CP_READY"

# Stay up for the node test. The harness kills this VM when it is done; the
# sleep is only here so that gosh does not exit and drop to a shell in the
# middle of the run.
sleep 1800
