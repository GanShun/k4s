// Command uinit brings a guest up from inside its image.
//
// It replaces bring-up scripts that the test harness piped into the guests'
// shells over the serial console, one line at a time. That protocol was the
// single largest source of wasted time in this project. gosh is not bash: every
// line had to be a complete command short enough not to be corrupted in transit,
// `A && B &` was accepted and then silently ignored, and a 157-character line
// lost its redirect and its trailing `&` when read from a file. None of that
// applies here -- this is a program, and the kernel runs it.
//
// u-root's init runs /inito, /bbin/uinit, /bin/uinit, /buildbin/uinit,
// /bin/defaultsh and /bin/sh in sequence, waiting for each to exit. So this
// starts the daemons and returns; they are put in their own sessions so that they
// survive it. It is installed as a bb applet, which u-root's init finds at
// /bbin/uinit.
//
// There are two roles, the node and the control plane, and this file holds both.
// They would be nicer as two commands sharing a package, and that is what they
// were until the applet build refused them: u-root builds bb with GO111MODULE=off
// in a synthetic GOPATH and links only the packages named on its command line, so
// a bb applet cannot import a sibling package. The role is therefore read at
// runtime from /etc/k4s/role, which the image carries.
//
// It never exits early on a failure. u-root's init ignores the exit status and
// starts a shell regardless, so exiting would only hide the problem -- a reported
// failure on the console is what makes a broken boot diagnosable.
package main

import (
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"
)

const (
	roleFile = "/etc/k4s/role"

	sshdLog       = "/tmp/sshd.log"
	containerdLog = "/tmp/containerd.log"
	kubeletLog    = "/tmp/kubelet.log"
)

func main() {
	role, err := os.ReadFile(roleFile)
	if err != nil {
		logf("cannot read %s: %v", roleFile, err)
		return
	}
	switch strings.TrimSpace(string(role)) {
	case "node":
		node()
	case "control-plane":
		controlPlane()
	default:
		logf("%s says %q, which is neither node nor control-plane", roleFile, strings.TrimSpace(string(role)))
	}
}

// --- the node ---------------------------------------------------------------

// node brings up a diskless worker: network, sshd, the mounts and cgroups that
// containerd and runc need, containerd, and kubelet. The kubeconfig is spliced
// into the image by the harness, which issues it from the throwaway CA.
func node() {
	logf("bringing the node up")

	// --- network ------------------------------------------------------------
	step("eth0 up", "ip", "link", "set", "eth0", "up")
	// The address is DHCP from QEMU's user-mode network, whose gateway is
	// 10.0.2.2 and whose resolver is 10.0.2.3. The apiserver is reached at
	// 10.0.2.2, because that is the host from inside the guest.
	step("dhclient", "dhclient", "-ipv6=false", "-timeout", "10", "eth0")
	write("/etc/resolv.conf", "nameserver 10.0.2.3\n")

	// --- sshd ---------------------------------------------------------------
	// The harness reads the node's filesystem over ssh rather than scraping the
	// serial console, so this has to come up early.
	background("sshd", sshdLog,
		"-keys", "/etc/ssh/authorized_keys", "-privatekey", "/etc/ssh/host_rsa")

	// --- kernel filesystems -------------------------------------------------
	// Make / a shared mount. A container that mounts something and expects the
	// host to see it -- Cilium's mount-bpf-fs initContainer does exactly that
	// with bpffs -- needs the mount to propagate, and containerd refuses to even
	// create the container while /sys is private: `path "/sys/fs/bpf" is mounted
	// on "/sys" but it is not a shared mount`. Every distribution's init makes /
	// shared; u-root's does not.
	//
	// Two details, both of which fail quietly or confusingly: no `remount`,
	// because the kernel checks MS_REMOUNT before the propagation flags, so
	// `remount,shared` would do nothing at all; and `-t none`, because without a
	// type u-root's mount tries to open the source as a block device
	// ("open none: no such file or directory") instead of calling mount(2).
	step("shared /", "mount", "-t", "none", "-o", "shared,rec", "none", "/")
	mkdir("/sys/fs/cgroup", "/sys/fs/cgroup")
	step("cgroup2", "mount", "-t", "cgroup2", "none", "/sys/fs/cgroup")

	// cgroup v2 only exposes a controller in child cgroups if the parent lists
	// it in subtree_control. u-root's init mounts cgroup2 but enables none, so
	// runc fails creating the pod cgroup with ".../cpu.max: no such file or
	// directory". One write per controller: a single write is all-or-nothing, so
	// one unavailable controller would leave the root with none enabled.
	for _, c := range []string{"cpu", "cpuset", "memory", "pids", "io"} {
		write("/sys/fs/cgroup/cgroup.subtree_control", "+"+c)
	}
	logf("cgroup controllers: enabled")

	// Cilium's DaemonSet mounts /lib/modules unconditionally, and this image has
	// no modules and so no such directory.
	mkdir("node directories",
		"/lib/modules", "/run/containerd", "/run/flannel",
		"/var/lib/containerd", "/var/lib/kubelet", "/var/log/pods",
		"/var/log/k4s-smoke", "/var/log/k4s-netns",
		"/var/log/k4s-ds", "/var/log/k4s-deploy", "/var/log/k4s-flannel",
		"/var/log/k4s-hook")

	// Strict RAM-only: there is no disk, so everything the runtime and kubelet
	// write is a tmpfs. A tmpfs defaults to half of RAM, which is what decides
	// whether a CNI's images fit -- see docs/testing.md.
	step("tmpfs /var/lib/containerd", "mount", "-t", "tmpfs", "tmpfs", "/var/lib/containerd")
	step("tmpfs /var/lib/kubelet", "mount", "-t", "tmpfs", "tmpfs", "/var/lib/kubelet")
	step("tmpfs /var/log/pods", "mount", "-t", "tmpfs", "tmpfs", "/var/log/pods")

	// --- containerd ---------------------------------------------------------
	background("containerd", containerdLog)
	waitFor("containerd", 30*time.Second, func() error {
		return exec.Command("/bbin/ctr", "version").Run()
	})

	// --- kubelet ------------------------------------------------------------
	// root-dir and cert-dir already default under /var/lib/kubelet, which is the
	// tmpfs above.
	background("kubelet", kubeletLog,
		"--config=/etc/kubernetes/kubelet.yaml",
		"--kubeconfig=/etc/kubernetes/kubeconfig",
		"--hostname-override=k4s-node-1")

	// Nothing here waits for the CNI or for pods. Whether the CNI is up before
	// the pods that need it is the harness's business: it applies the CNI, waits
	// for it, then applies the pods. Waiting here as well was pure dead time.
	logf("done; the node is up")
}

// --- the control plane ------------------------------------------------------

// controlPlane brings up a throwaway Kubernetes control plane: etcd, the
// apiserver, the controller-manager and the scheduler, with the PKI baked into
// the image. It is a VM rather than host processes because the node should join
// something shaped like a real cluster -- the controller-manager is what assigns
// pod CIDRs, runs DaemonSets and Deployments and issues service account tokens.
//
// The host reaches the apiserver through a QEMU port forward on 127.0.0.1:6443.
// The node reaches it at 10.0.2.2:6443, which is the host from inside the node's
// user-mode network, and the same forward carries it here. The apiserver
// certificate carries both addresses.
func controlPlane() {
	logf("bringing the control plane up")

	// --- network ------------------------------------------------------------
	step("eth0 up", "ip", "link", "set", "eth0", "up")
	step("dhclient", "dhclient", "-ipv6=false", "-timeout", "10", "eth0")
	write("/etc/resolv.conf", "nameserver 10.0.2.3\n")

	// --- filesystems --------------------------------------------------------
	// No disk anywhere: etcd's data directory is RAM, and this VM is thrown away.
	mkdir("etcd data dir", "/var/lib/etcd")
	step("tmpfs /var/lib/etcd", "mount", "-t", "tmpfs", "tmpfs", "/var/lib/etcd")

	// --- etcd ---------------------------------------------------------------
	background("etcd", "/tmp/etcd.log",
		"--data-dir", "/var/lib/etcd",
		"--listen-client-urls", "http://127.0.0.1:2379",
		"--advertise-client-urls", "http://127.0.0.1:2379",
		"--listen-peer-urls", "http://127.0.0.1:2380",
		"--initial-advertise-peer-urls", "http://127.0.0.1:2380",
		"--initial-cluster", "default=http://127.0.0.1:2380")

	// --- apiserver ----------------------------------------------------------
	// ServiceAccount admission is on here. With the controller-manager running
	// the token controller, pods then get a service account token, which is what
	// anything talking to the apiserver from inside a pod needs -- the Cilium
	// agent and operator, for instance. The ca.crt a pod is given comes from the
	// kube-root-ca.crt ConfigMap, which the controller-manager publishes from its
	// own --root-ca-file: kube-apiserver had that flag too until it was removed,
	// and passing it here is now an error that stops the apiserver starting.
	background("kube-apiserver", "/tmp/apiserver.log",
		"--etcd-servers=http://127.0.0.1:2379",
		"--secure-port=6443",
		"--bind-address=0.0.0.0",
		"--tls-cert-file=/etc/kubernetes/pki/apiserver.crt",
		"--tls-private-key-file=/etc/kubernetes/pki/apiserver.key",
		"--client-ca-file=/etc/kubernetes/pki/ca.crt",
		"--service-account-key-file=/etc/kubernetes/pki/sa.pub",
		"--service-account-signing-key-file=/etc/kubernetes/pki/sa.key",
		"--service-account-issuer=https://10.0.2.2:6443",
		"--service-cluster-ip-range=10.96.0.0/12",
		"--authorization-mode=AlwaysAllow",
		"--allow-privileged=true")

	// --- controller-manager and scheduler -----------------------------------
	// --allocate-node-cidrs is what gives a node its spec.podCIDR, which flannel
	// refuses to register without. The cluster CIDR matches flannel's network
	// config and the mask size is what makes each node a /24, flannel's default
	// subnet length.
	controllerManager := background("kube-controller-manager", "/tmp/controller-manager.log",
		"--kubeconfig=/etc/kubernetes/admin.kubeconfig",
		"--allocate-node-cidrs=true",
		"--cluster-cidr=10.244.0.0/16",
		"--node-cidr-mask-size=24",
		"--service-cluster-ip-range=10.96.0.0/12",
		"--service-account-private-key-file=/etc/kubernetes/pki/sa.key",
		"--root-ca-file=/etc/kubernetes/pki/ca.crt",
		"--leader-elect=false")
	scheduler := background("kube-scheduler", "/tmp/scheduler.log",
		"--kubeconfig=/etc/kubernetes/admin.kubeconfig",
		"--leader-elect=false")

	// --- readiness ----------------------------------------------------------
	// Asked, not inferred. A service that refused to start leaves a log that
	// looks much like a healthy one, which is exactly what the fed script's greps
	// for the word "Error" could not tell apart.
	plain := &http.Client{Timeout: 5 * time.Second}
	waitFor("etcd", 60*time.Second, func() error {
		return healthz(plain, "http://127.0.0.1:2379/health")
	})

	// /healthz is one of the paths the apiserver serves to anonymous callers, so
	// no client certificate is needed -- only the CA, to verify it.
	client, err := clientWithCA("/etc/kubernetes/pki/ca.crt", 5*time.Second)
	if err != nil {
		logf("apiserver: %v", err)
		return
	}
	waitFor("apiserver", 120*time.Second, func() error {
		return healthz(client, "https://127.0.0.1:6443/healthz")
	})

	// The controller-manager and the scheduler have no health endpoint worth
	// polling, so this reports whether they are still running. That they work is
	// proved later and for real: the DaemonSet and the Deployment the test
	// applies are run and placed by them.
	for _, d := range []struct {
		name string
		pid  int
	}{
		{"kube-controller-manager", controllerManager},
		{"kube-scheduler", scheduler},
	} {
		if alive(d.pid) {
			logf("%s: ok", d.name)
			continue
		}
		logf("%s: not running; see /tmp/%s.log", d.name, d.name)
	}

	logf("done; the control plane is up")
}

// --- shared -----------------------------------------------------------------

// logf writes a progress line to the console. The harness captures the console
// but does not parse it: this is where a boot that fails says so first.
func logf(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "uinit: "+format+"\n", a...)
}

// step runs a command and waits for it, reporting a failure without stopping.
func step(what string, name string, args ...string) {
	path, err := exec.LookPath(name)
	if err != nil {
		logf("%s: %v", what, err)
		return
	}
	cmd := exec.Command(path, args...)
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		logf("%s: %v", what, err)
		return
	}
	logf("%s: ok", what)
}

// background starts a daemon and returns its pid, or 0 if it could not be
// started. It gets its own session, so it is not in line for a SIGHUP when the
// shell u-root's init starts after this exits, and its stdin is /dev/null so
// nothing can block on a console that is not being fed.
func background(name string, logPath string, args ...string) int {
	path, err := exec.LookPath(name)
	if err != nil {
		logf("%s: %v", name, err)
		return 0
	}
	log, err := os.Create(logPath)
	if err != nil {
		logf("%s: %v", name, err)
		return 0
	}
	defer log.Close()
	devnull, err := os.OpenFile(os.DevNull, os.O_RDONLY, 0)
	if err != nil {
		logf("%s: %v", name, err)
		return 0
	}
	defer devnull.Close()

	cmd := exec.Command(path, args...)
	cmd.Stdin = devnull
	cmd.Stdout = log
	cmd.Stderr = log
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		logf("%s: %v", name, err)
		return 0
	}
	logf("%s: started (pid %d, log %s)", name, cmd.Process.Pid, logPath)
	return cmd.Process.Pid
}

// alive reports whether a process started by background is still running. A
// daemon that exited leaves everything else looking normal, which is the failure
// the control plane's fed script could only catch by grepping its log.
func alive(pid int) bool {
	return pid > 0 && syscall.Kill(pid, 0) == nil
}

// write is a one-shot file write, for the cgroup controller list and resolv.conf.
func write(path, content string) {
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		logf("%s: %v", path, err)
	}
}

// mkdir creates directories, reporting the first failure.
func mkdir(what string, dirs ...string) {
	for _, d := range dirs {
		if err := os.MkdirAll(d, 0o755); err != nil {
			logf("%s: %v", what, err)
			return
		}
	}
	logf("%s: ok", what)
}

// waitFor polls until the check passes or the timeout expires, then reports
// either way and returns.
func waitFor(what string, timeout time.Duration, check func() error) bool {
	deadline := time.Now().Add(timeout)
	for {
		err := check()
		if err == nil {
			logf("%s: ok", what)
			return true
		}
		if time.Now().After(deadline) {
			logf("%s: not ready after %s (%v)", what, timeout, err)
			return false
		}
		time.Sleep(time.Second)
	}
}

// clientWithCA returns an HTTP client that trusts the CA at caPath. The image has
// no curl, and readiness probes are the one thing worth doing in-process anyway.
func clientWithCA(caPath string, timeout time.Duration) (*http.Client, error) {
	pem, err := os.ReadFile(caPath)
	if err != nil {
		return nil, err
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(pem) {
		return nil, fmt.Errorf("%s: no certificates found", caPath)
	}
	return &http.Client{
		Timeout:   timeout,
		Transport: &http.Transport{TLSClientConfig: &tls.Config{RootCAs: pool}},
	}, nil
}

// healthz fetches url and returns an error unless it answers 200. A status other
// than 200 is the service saying it is not ready, which is a result rather than a
// failure to ask.
func healthz(client *http.Client, url string) error {
	resp, err := client.Get(url)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("%s: %s", url, resp.Status)
	}
	return nil
}
