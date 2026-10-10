// Command runc-ns stages a "runc exec" process into the container's PID
// namespace.
//
// setns(2) cannot put the caller into a PID namespace. pidns_install()
// (kernel/pid_namespace.c:392) stores the target in
// nsproxy->pid_ns_for_children and returns -- the caller does not move, and
// only its *next child* is created there. execve(2) creates no process, so
// "setns, then exec the next stage" cannot join one: the exec'd stage is still
// in the caller's PID namespace. A fork is required, and Go cannot fork and
// keep running Go. It can fork and *re-exec*, which is what os/exec does, and
// the next stage here is a fresh program, so nothing has to survive the fork.
//
// So this is nsexec's stage 1 with an execve in place of the double fork:
//
//  1. setns(CLONE_NEWPID) into the container's PID namespace. That only arms
//     pid_ns_for_children -- see above.
//  2. start the next stage on the same locked OS thread. The clone(2) that
//     os/exec performs is the fork, so the new process is created in the
//     container's PID namespace, and it is "runc init" that then joins the
//     container's other namespaces itself, exactly as it does for a container
//     the pod's own init.
//  3. report that process's host PID to runc, and exit.
//
// The next stage is deliberately made a child of *runc* rather than of this
// process (CLONE_PARENT), exactly as nsexec's clone_parent() does
// (nsexec.c:322). runc reaps the process it exec'd and turns its exit status
// into the exit status of "runc exec": its SIGCHLD loop is a wait4(-1) over its
// own children (signals.go: reap), so a process that is nobody's child would
// never be reported as exited and "runc exec" would hang forever. nsexec says
// the same thing at nsexec.c:930-935, where it asks runc to reap stage 1 for
// it.
//
// Every other file descriptor runc handed over -- the init, sync and log pipes,
// the console and pidfd sockets, any preserved descriptors, and the container's
// stdio -- is inherited by the next stage untouched, because the numbering does
// not change across one more exec and the _LIBCONTAINER_* variables that name
// them are inherited too. Nothing is re-plumbed here, and nothing is inspected.
//
// It never unlocks the OS thread. A LockOSThread goroutine that exits without
// unlocking takes the thread with it, which is what happens here.
package main

import (
	"fmt"
	"os"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"syscall"

	"golang.org/x/sys/unix"
)

// reportFdEnv names the descriptor the child's host PID is written to. It is
// the write end of a pipe runc holds the read end of.
const reportFdEnv = "_LIBCONTAINER_RUNCNS_PIDFD"

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "runc-ns: %v\n", err)
		os.Exit(1)
	}
}

// run is: runc-ns <pid-namespace-path> <command> [args...], where <command> is
// the runc binary and its first argument is "init".
func run() error {
	if len(os.Args) < 3 {
		return fmt.Errorf("usage: runc-ns <pid-namespace-path> <command> [args...]")
	}
	pidNsPath, argv := os.Args[1], os.Args[2:]

	reportFd, err := strconv.Atoi(strings.TrimSpace(os.Getenv(reportFdEnv)))
	if err != nil {
		return fmt.Errorf("%s: %w", reportFdEnv, err)
	}

	// pid_ns_for_children lives in the nsproxy, which every thread of a process
	// shares, so the setns has to happen on the thread whose clone(2) creates
	// the child, and nothing may clone in between. That is why there is exactly
	// one os/exec call below and no goroutine anywhere in this program.
	runtime.LockOSThread()

	fd, err := unix.Open(pidNsPath, unix.O_RDONLY|unix.O_CLOEXEC, 0)
	if err != nil {
		return fmt.Errorf("open %s: %w", pidNsPath, err)
	}
	err = unix.Setns(fd, unix.CLONE_NEWPID)
	unix.Close(fd)
	if err != nil {
		return fmt.Errorf("setns(CLONE_NEWPID, %s): %w", pidNsPath, err)
	}

	return startStage(argv, reportFd)
}

// startStage starts the next stage and reports its host PID to runc.
func startStage(argv []string, reportFd int) error {
	// If anything below fails after the clone, runc must see EOF on the report
	// pipe rather than wait for a pid that will never arrive. Close-on-exec
	// also keeps the descriptor out of the container's process, which is both
	// tidier and what makes a failure after the clone diagnosable instead of a
	// hang.
	unix.CloseOnExec(reportFd)

	cmd := &exec.Cmd{
		// Path is used for execve(2) exactly as given: it is the path runc
		// built for its own child, which is /proc/self/fd/N of a sealed copy of
		// the runc binary (or /proc/self/exe when that copy already exists).
		// The descriptor numbering is unchanged by this one extra process, so
		// the same path still resolves here. exec.Command's LookPath is
		// deliberately skipped: the path is absolute, and when it names an
		// O_PATH descriptor of a sealed memfd there is nothing useful for
		// LookPath to check anyway.
		Path:   argv[0],
		Args:   argv,
		Stdin:  os.Stdin,
		Stdout: os.Stdout,
		Stderr: os.Stderr,
		// No Dir, so the child inherits this process's working directory, which
		// runc set to the container's root before starting this helper.
		//
		// Env is left nil, so the child inherits this process's environment --
		// every _LIBCONTAINER_* variable runc set, unexamined.
		SysProcAttr: &syscall.SysProcAttr{
			// The child of this child is runc's, not ours. See the package
			// comment.
			Cloneflags: syscall.CLONE_PARENT,
		},
	}

	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start %s: %w", argv[0], err)
	}

	// This process's own PID namespace was not changed by the setns above, so
	// the value clone(2) returned is the child's number in *this* process's
	// active namespace -- runc's -- which is the number runc needs.
	// (kernel/fork.c:2761: nr = pid_vnr(pid).)
	report := strconv.Itoa(cmd.Process.Pid) + "\n"
	if _, err := unix.Write(reportFd, []byte(report)); err != nil {
		// runc now has no pid for this process, so nothing will ever signal,
		// count or reap it. Take it down rather than leak a container process
		// that no one can account for.
		_ = cmd.Process.Kill()
		return fmt.Errorf("report pid %d: %w", cmd.Process.Pid, err)
	}
	return nil
}
