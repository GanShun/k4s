# Quickstart: build the node image and run the cluster tests

This repository builds a **diskless Kubernetes worker node**: a Linux kernel plus
a u-root initramfs carrying containerd, a cgo-free runc, kubelet and the CNI
plugins. It then tests that node under QEMU against a throwaway control plane.
`docs/roadmap.md` is the design, and `docs/testing.md` explains what each test
proves.

Two repositories are involved, and they must be **siblings**:

| Repository | Branch | What it is |
| --- | --- | --- |
| [`GanShun/k4s`](https://github.com/GanShun/k4s) | `k4s-dev` | this repository: the image, `DIT` and the QEMU harness |
| [`GanShun/runc`](https://github.com/GanShun/runc) | `k4s-dev` | the runc fork, which creates and joins namespaces and compiles seccomp profiles in Go, so a `CGO_ENABLED=0` runc works. Its `ROADMAP.md` says what is verified and what is not |

`go.work` names the fork as `../runc`. If there is no `../runc`, `DIT` clones
`GanShun/runc` `k4s-dev` there. An existing checkout is used exactly as it
stands, so you can test your own runc changes in it.

## Machine requirements

Measured on the development host (Ubuntu 24.04, kernel 6.8, 8 CPUs, 15 GiB of
RAM).

| | Minimum | Recommended | Why |
| --- | --- | --- | --- |
| Architecture | x86_64 | | Every VM is `qemu-system-x86_64 -M q35`, and the kernel config is for amd64 |
| KVM | optional | **`/dev/kvm` writable by your user** (`sudo usermod -aG kvm $USER`, then log in again). On a cloud VM, enable nested virtualisation. | Without KVM, QEMU falls back to TCG, which is much slower. `make test` then needs `K4S_BOOT_TIMEOUT=900`. The cluster tests have **not been measured under TCG**, so treat them as unsupported without KVM. |
| CPU | 4 | 8 | Each VM is `-smp 2`, a cluster run boots two VMs, and the kernel and Go builds run in parallel |
| RAM, flannel (`make test-cluster`) | 6 GiB | 8 GiB | The control-plane VM takes 1.5 GiB and the node 1.5 GiB, plus the host-side build |
| RAM, Cilium (`make test-cluster-cni`) | 12 GiB | 16 GiB | The node VM needs 6 GiB: its image store is a tmpfs, which gets half of the node's RAM |
| Disk | 25 GiB free | 40 GiB | Measured on a cold start (2026-11-08): about 19 GiB in all. The kernel checkout is 2.1 GiB, `build/` 2.8 GiB, the component checkouts and the image 1.2 GiB, and the Go module and build caches under `$HOME` 12 GiB |
| Network | outbound HTTPS | | github.com (components), git.kernel.org (the kernel, from the stable tree), proxy.golang.org, docker.io and registry.k8s.io (test images), helm.cilium.io and quay.io (Cilium) |
| Local ports | | | 6443 (the apiserver forward), 2222 and 2223 (ssh into the node) must be free |
| Root | **not needed** | | The VMs use QEMU user-mode networking, and nothing is mounted on the host |

### Software

- **Go 1.27.0 or newer.** containerd `main` declares `go 1.27.0`. A go.dev
  tarball is enough, and u-root's build warning that it recommends Go 1.25 or
  1.26 is harmless.
- On Debian or Ubuntu:

  ```
  sudo apt install git make gcc libc6-dev python3 curl cpio openssh-client openssl \
       bc bison flex libelf-dev libssl-dev pahole kmod xz-utils \
       qemu-system-x86
  ```

  - `pahole` is needed when the kernel is configured and built. Without root:
    `apt-get download pahole && dpkg-deb -x pahole_*.deb ~/pahole`, then
    `PAHOLE=~/pahole/usr/bin/pahole make kernel`.
- **[helm](https://helm.sh/docs/intro/install/)**, for the Cilium test only.
  Point at one off `PATH` with `HELM=/path/to/helm`.

## Run it

```
mkdir k4s-work && cd k4s-work
git clone -b k4s-dev https://github.com/GanShun/runc     # optional: DIT clones it if absent
git clone -b k4s-dev https://github.com/GanShun/k4s
cd k4s
make test-all
```

`make test-all` builds the kernel (`make kernel`) and the image (`make image`,
which runs `DIT`), then runs three tests one after another:

| Target | What it proves | Verdict lines |
| --- | --- | --- |
| `make test` | the node boots, has the capabilities it needs, and runs a container | `boot: ok`, `capabilities: ok`, `container: ok` |
| `make test-cluster` | the node joins a control-plane VM with flannel, runs pods (under seccomp, in their own network namespace, with a lifecycle hook, sharing a PID namespace, plus a DaemonSet, a Deployment and nginx), and does it all again after a reboot | `node`, `flannel`, `pod`, `seccomp`, `netns pod`, `log pod`, `nginx`, `hook`, `pidns`, `daemonset`, `deployment`, `workloads`, `cluster`; `service`, `dns` and `egress` say `skipped` |
| `make test-cluster-cni` | the same, with **Cilium** as the CNI, plus Services, cluster DNS and egress | the same lines, with `cilium` in place of `flannel`, and `service`, `dns` and `egress` as `ok` |

**Expected times**, measured from a fresh clone with empty Go caches, on the
development host with KVM (2026-11-08):

| Step | Cold | Warm |
| --- | --- | --- |
| `make kernel` | 4 min | under a minute, when nothing changed |
| `make image` | 4 min | about 2 min |
| `make test` | 10 s | 10 s |
| `make test-cluster` | 3.7 min, about 1.5 of it building the control-plane binaries | about 75 s |
| `make test-cluster-cni` | 7.4 min, mostly pulling Cilium's images into the node | about 210 s |

So a cold `make test-all` takes about 20 minutes.

Useful knobs:

| Variable | What it does |
| --- | --- |
| `K4S_BOOTS` | the number of boots per cluster run (default 2) |
| `K4S_BOOT_TIMEOUT` | seconds `make test` allows the guest (default 180) |
| `K4S_XTRACE=1` | trace the cluster harness to `/tmp/k4s-trace.log` |

The full table is in `docs/testing.md`.

## What works and what does not, yet

Cilium is the CNI this project is heading for, with its kube-proxy replacement
and BPF masquerading, so the image needs no `iptables` userland. On the Cilium
leg a pod reaches a ClusterIP Service, resolves a cluster name through CoreDNS,
and fetches an off-cluster address (`service`, `dns`, `egress`). The flannel leg
has no service routing or NAT, and says `skipped` for those three. A pod in a
`shareProcessNamespace` pod sees its sibling's processes (`pidns`).

The node is **not yet a complete worker**. These are the known gaps:

- **More than one node.** Every test boots a single worker.
- **`kubectl exec -it`, `attach` and `port-forward`** are untested: the runc
  fork's `ROADMAP.md` §3. The test's control-plane VM cannot reach the node's
  kubelet port, so the harness cannot exercise them yet either.
- **`kubectl debug --target`** goes through the same runc path as
  `shareProcessNamespace` (a container init joining a PID namespace by path), but
  has no check of its own.
- **Joining.** The node's kubelet credential is spliced into the image for each
  test run, and its name is fixed. TLS bootstrapping is designed in
  `docs/roadmap.md` but not built.
- **User namespaces** (`hostUsers: false`) and checkpoint/restore are not
  supported by the cgo-free runc (`ROADMAP.md` §4).
