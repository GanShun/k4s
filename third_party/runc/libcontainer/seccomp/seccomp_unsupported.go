//go:build !linux || !cgo || !seccomp

package seccomp

import (
	"errors"

	"github.com/opencontainers/runc/libcontainer/configs"
	"github.com/opencontainers/runtime-spec/specs-go"
	"github.com/sirupsen/logrus"
)

var ErrSeccompNotEnabled = errors.New("seccomp: config provided but seccomp not supported")

// InitSeccomp does nothing because seccomp is not supported.
//
// In the cgo-free build it warns and continues (see k4s_nocgo.go); every other
// build keeps upstream's fail-closed behaviour.
func InitSeccomp(config *configs.Seccomp) (int, error) {
	if config != nil {
		if k4sIgnoreUnsupportedSeccomp {
			logrus.Warn("k4s: seccomp profile requested but this runc is built without seccomp (cgo+libseccomp); running WITHOUT seccomp")
			return -1, nil
		}
		return -1, ErrSeccompNotEnabled
	}
	return -1, nil
}

// FlagSupported tells if a provided seccomp flag is supported.
func FlagSupported(_ specs.LinuxSeccompFlag) error {
	if k4sIgnoreUnsupportedSeccomp {
		return nil
	}
	return ErrSeccompNotEnabled
}

// Version returns major, minor, and micro.
func Version() (uint, uint, uint) {
	return 0, 0, 0
}

// Enabled is true if seccomp support is compiled in.
const Enabled = false
