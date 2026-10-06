// Command uinit brings the node up from inside the image.
//
// It replaces a bring-up script that the test harness piped into the guest's
// shell over the serial console, one line at a time. That protocol was the
// single largest source of wasted time in this project. gosh is not bash: every
// line had to be a complete command short enough not to be corrupted in
// transit, `A && B &` was accepted and then silently ignored, and a
// 157-character line lost its redirect and its trailing `&` when read from a
// file. None of that applies here -- this is a program, and the kernel runs it.
//
// u-root's init runs /inito, /bbin/uinit, /bin/uinit, /buildbin/uinit,
// /bin/defaultsh and /bin/sh in sequence, waiting for each to exit. So this
// starts the daemons and returns; they are put in their own sessions so that
// they survive it.
//
// It never exits early on a failure. u-root's init ignores the exit status and
// starts a shell regardless, so exiting would only hide the problem -- a
// reported failure on the console is what makes a broken boot diagnosable.
package main

import (
	"fmt"
	"os"
	"os/exec"
	"syscall"
	"time"
)

// Where the daemons write. Read back over ssh by the harness, never off the
// console: a log has to be printed at exactly the right moment to be caught
// there, and printing one takes minutes at 115200 baud.
const (
	sshdLog       = "/tmp/sshd.log"
	containerdLog = "/tmp/containerd.log"
	kubeletLog    = "/tmp/kubelet.log"
)

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

// background starts a daemon and returns. It gets its own session, so it is not
// in line for a SIGHUP when the shell that u-root's init starts after this
// exits, and its stdin is /dev/null so nothing can block on a console that is
// no longer being fed.
func background(name string, logPath string, args ...string) {
	path, err := exec.LookPath(name)
	if err != nil {
		logf("%s: %v", name, err)
		return
	}
	log, err := os.Create(logPath)
	if err != nil {
		logf("%s: %v", name, err)
		return
	}
	defer log.Close()
	devnull, err := os.OpenFile(os.DevNull, os.O_RDONLY, 0)
	if err != nil {
		logf("%s: %v", name, err)
		return
	}
	defer devnull.Close()

	cmd := exec.Command(path, args...)
	cmd.Stdin = devnull
	cmd.Stdout = log
	cmd.Stderr = log
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		logf("%s: %v", name, err)
		return
	}
	logf("%s: started (pid %d, log %s)", name, cmd.Process.Pid, logPath)
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

// waitFor polls until the check passes or the timeout expires.
func waitFor(what string, timeout time.Duration, check func() error) {
	deadline := time.Now().Add(timeout)
	for {
		err := check()
		if err == nil {
			logf("%s: ok", what)
			return
		}
		if time.Now().After(deadline) {
			logf("%s: timed out after %s (%v)", what, timeout, err)
			return
		}
		time.Sleep(time.Second)
	}
}

func main() {
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
		"/var/log/k4s-ds", "/var/log/k4s-deploy", "/var/log/k4s-flannel")

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
	// tmpfs above. The kubeconfig is spliced into the image by the harness, which
	// issues it from the throwaway CA.
	background("kubelet", kubeletLog,
		"--config=/etc/kubernetes/kubelet.yaml",
		"--kubeconfig=/etc/kubernetes/kubeconfig",
		"--hostname-override=k4s-node-1")

	// Nothing here waits for the CNI or for pods. Whether the CNI is up before
	// the pods that need it is the harness's business: it applies the CNI, waits
	// for it, then applies the pods. Waiting here as well was pure dead time.
	logf("done; the node is up")
}
