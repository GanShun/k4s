//go:build linux && !cgo

package seccomp

// k4sIgnoreUnsupportedSeccomp is true for the cgo-free build.
//
// kubelet unconditionally asks for RuntimeDefault seccomp on the pod sandbox
// (kubernetes/pkg/kubelet/kuberuntime/kuberuntime_sandbox.go), and containerd
// turns that into an OCI seccomp section. runc can only compile that with cgo
// plus libseccomp, so failing closed would make every pod on a cgo-free node
// unschedulable. The pure-Go build therefore warns and runs without seccomp.
//
// This is a real loss of isolation and is the top item to close before this
// runtime is used for anything untrusted. See docs/nsenter-and-runc.md.
const k4sIgnoreUnsupportedSeccomp = true
