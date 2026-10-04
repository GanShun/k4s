//go:build !cgo

package userns

import (
	"bytes"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"strings"
	"syscall"

	"github.com/sirupsen/logrus"
	"golang.org/x/sys/unix"
)

const envName = "__RUNC__DUMPNS"

func init() {
	s := os.Getenv(envName)
	if len(s) == 0 {
		return
	}
	files := strings.Split(s, "\x00")
	if len(files) != 2 {
		log.Fatalf(envName+": %q, but must be two null-seperated fields", files)
	}
	if err := dumpns(files[0], files[1]); err != nil {
		log.Fatalf("dumpns:%v", err)
	}
}

func dumpns(nsPath, file string) error {
	fd, err := os.Open(nsPath)
	if err != nil {
		return fmt.Errorf("Failed to open ns: %v\n", err)
	}
	defer fd.Close()

	if _, _, err := syscall.AllThreadsSyscall(unix.SYS_SETNS, fd.Fd(), uintptr(syscall.CLONE_NEWUSER), 0); err != 0 {
		return fmt.Errorf("setns %v(fd %d)failed: %v\n", nsPath, fd.Fd(), err)
	}
	out, err := os.ReadFile(file)
	if err != nil {
		return err
	}
	_, err = os.Stdout.Write(out)
	return err
}

func spawnUserNamespaceCat(nsPath, path string) ([]byte, error) {
	rdr, wtr, err := os.Pipe()
	if err != nil {
		return nil, fmt.Errorf("create pipe for userns spawn failed: %w", err)
	}
	defer rdr.Close()
	defer wtr.Close()

	errRdr, errWtr, err := os.Pipe()
	if err != nil {
		return nil, fmt.Errorf("create error pipe for userns spawn failed: %w", err)
	}
	defer errRdr.Close()
	defer errWtr.Close()

	c := exec.Command("/proc/self/exe")
	c.Stdout, c.Stderr = wtr, errRdr

	c.Env = append(c.Env, envName+"="+nsPath+"\x00"+path)
	c.SysProcAttr = &syscall.SysProcAttr{
		Cloneflags: syscall.CLONE_NEWUTS,
	}

	if err := c.Run(); err != nil {
		log.Fatal(err)
	}
	wtr.Close()
	output, err := io.ReadAll(rdr)
	rdr.Close()
	if err != nil {
		return nil, fmt.Errorf("reading from userns spawn failed: %w", err)
	}

	// Ditto for the error pipe.
	errWtr.Close()
	errOutput, err := io.ReadAll(errRdr)
	errRdr.Close()
	if err != nil {
		return nil, fmt.Errorf("reading from userns spawn error pipe failed: %w", err)
	}
	errOutput = bytes.TrimSpace(errOutput)

	if err := c.Wait(); err != nil {
		return nil, fmt.Errorf("failed to wait for userns spawn process: %s: %w", string(errOutput), err)
	}

	if len(errOutput) > 0 {
		// We can just ignore weird output in the error pipe if the process
		// didn't bail(), but for completeness output for debugging.
		logrus.Debugf("userns spawn succeeded but unexpected error message found: %s", string(errOutput))
	}
	// The subprocess succeeded, return whatever it wrote to the pipe.
	return output, nil
}
