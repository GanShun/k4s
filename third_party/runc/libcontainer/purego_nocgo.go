//go:build linux && !cgo

package libcontainer

import (
	"os/exec"

	"golang.org/x/sys/unix"
)

// puregoNamespaces is true when runc is built without cgo. In that build the C
// namespace constructor (libcontainer/nsenter) does not exist, so the
// namespaces are created by the Go runtime's clone(2) support in exec.Cmd.
const puregoNamespaces = true

// setCloneFlags asks the kernel to create the container's namespaces directly
// when the init process is cloned. This replaces what nsexec.c does before the
// Go runtime starts.
//
// It covers the rootful case (the one the diskless node uses). A user
// namespace cannot be combined with the others in a single clone(2) -- the
// kernel returns EPERM -- which is exactly the ordering nsexec works around;
// that gap is not handled here.
func setCloneFlags(cmd *exec.Cmd, flags uintptr) {
	if cmd.SysProcAttr == nil {
		cmd.SysProcAttr = &unix.SysProcAttr{}
	}
	cmd.SysProcAttr.Cloneflags = flags
}
