//go:build !linux || (cgo && !seccomp)

package seccomp

// k4sIgnoreUnsupportedSeccomp is false everywhere except the cgo-free build,
// so upstream's fail-closed behaviour is unchanged for cgo builds.
const k4sIgnoreUnsupportedSeccomp = false
