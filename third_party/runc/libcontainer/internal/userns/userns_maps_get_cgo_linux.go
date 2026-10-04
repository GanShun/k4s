//go:build cgo

package userns

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"unsafe"

	"github.com/sirupsen/logrus"
)

/*
#include <stdlib.h>
extern int spawn_userns_cat(char *userns_path, char *path, int outfd, int errfd);
*/
import "C"

// Do something equivalent to nsenter --user=<nsPath> cat <path>, but more
// efficiently. Returns the contents of the requested file from within the user
// namespace.
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

	cNsPath := C.CString(nsPath)
	defer C.free(unsafe.Pointer(cNsPath))
	cPath := C.CString(path)
	defer C.free(unsafe.Pointer(cPath))

	childPid := C.spawn_userns_cat(cNsPath, cPath, C.int(wtr.Fd()), C.int(errWtr.Fd()))

	if childPid < 0 {
		return nil, fmt.Errorf("failed to spawn fork for userns")
	} else if childPid == 0 {
		// this should never happen
		panic("runc executing inside fork child -- unsafe state!")
	}

	// We are in the parent -- close the write end of the pipe before reading.
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

	// Clean up the child.
	child, err := os.FindProcess(int(childPid))
	if err != nil {
		return nil, fmt.Errorf("could not find userns spawn process: %w", err)
	}
	state, err := child.Wait()
	if err != nil {
		return nil, fmt.Errorf("failed to wait for userns spawn process: %w", err)
	}
	if !state.Success() {
		errStr := string(errOutput)
		if errStr == "" {
			errStr = fmt.Sprintf("unknown error (status code %d)", state.ExitCode())
		}
		return nil, fmt.Errorf("userns spawn: %s", errStr)
	} else if len(errOutput) > 0 {
		// We can just ignore weird output in the error pipe if the process
		// didn't bail(), but for completeness output for debugging.
		logrus.Debugf("userns spawn succeeded but unexpected error message found: %s", string(errOutput))
	}
	// The subprocess succeeded, return whatever it wrote to the pipe.
	return output, nil
}
