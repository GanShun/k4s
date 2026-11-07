// guesttar is a tar for the guest, and only for the guest.
//
// runc's integration tests extract their rootfs with
//
//	sh -c "tar --exclude './dev/*' -C <dest> -xf <tarball>"
//
// and u-root's tar applet has neither -C, --exclude, nor any decompression, so
// that command fails on a plain k4s image and every test in the package fails
// with it. The gnu tar a normal distribution ships is not an option either: this
// image has no libc and no dynamic loader.
//
// So the harness cross-compiles this and puts it first in the guest's PATH. It
// implements exactly the flags that command uses, and says so rather than
// pretending to be tar when something else is asked for.
//
// Not for general use. Modes are masked with 0o777 and then the umask applies, so
// setuid/setgid/sticky bits are lost and the fixture's sticky tmp/ comes out
// ordinary; owners are not preserved, so entries owned by uid 1, 8 and 65534
// become root's. That is fine for a rootfs extracted as root to be used as a
// container rootfs by a suite that checks namespaces, not file metadata -- and it
// would not be fine for anything that cared. There are no pax headers, and
// --exclude matches the name as written in the archive, which is what "./dev/*"
// needs.
package main

import (
	"archive/tar"
	"bufio"
	"compress/gzip"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// multiFlag collects a flag that may be given more than once.
type multiFlag []string

func (m *multiFlag) String() string { return strings.Join(*m, ",") }

func (m *multiFlag) Set(v string) error {
	*m = append(*m, v)
	return nil
}

// normalise expands clustered short flags, because the command this replaces is
// written the way tar is always written: "-xf FILE", not "-x -f FILE". Go's flag
// package cannot parse the former, and rewriting the caller's command line is
// less surprising than failing it.
func normalise(args []string) []string {
	out := make([]string, 0, len(args))
	for _, a := range args {
		if len(a) > 2 && a[0] == '-' && a[1] != '-' && strings.Trim(a[1:], "xtvf") == "" {
			for _, c := range a[1:] {
				out = append(out, "-"+string(c))
			}
			continue
		}
		out = append(out, a)
	}
	return out
}

// shell is what /bin/sh cannot be in this image.
//
// /bin/sh is a symlink to bbin/gosh, and bbin/gosh is a symlink to bb, which
// dispatches on the basename of argv[0]. That basename is "sh", and "sh" is not
// one of bb's applets, so bb reads the next argument as the applet name instead:
// `sh -c 'tar ...'` fails with "command is not present in busybox: -c". runc's
// test helper runs exactly that command, so the whole suite fails before a
// container is created.
//
// Re-exec by the name bb does know. The alternative -- asking every caller to use
// gosh -- is not available: the command is inside upstream's test helper.
func shell() {
	cmd := exec.Command("/bbin/gosh", os.Args[1:]...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	if err := cmd.Run(); err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			os.Exit(ee.ExitCode())
		}
		fmt.Fprintf(os.Stderr, "sh: %v\n", err)
		os.Exit(127)
	}
}

func main() {
	if filepath.Base(os.Args[0]) == "sh" {
		shell()
		return
	}
	os.Args = append([]string{os.Args[0]}, normalise(os.Args[1:])...)
	var (
		extract  bool
		list     bool
		file     string
		dir      string
		excludes multiFlag
		verbose  bool
	)
	flag.BoolVar(&extract, "x", false, "extract")
	flag.BoolVar(&extract, "extract", false, "extract")
	flag.BoolVar(&list, "t", false, "list")
	flag.BoolVar(&list, "list", false, "list")
	flag.StringVar(&file, "f", "", "archive file")
	flag.StringVar(&file, "file", "", "archive file")
	flag.StringVar(&dir, "C", "", "extract into this directory")
	flag.Var(&excludes, "exclude", "skip entries matching this glob (repeatable)")
	flag.BoolVar(&verbose, "v", false, "list entries as they are handled")
	flag.BoolVar(&verbose, "verbose", false, "list entries as they are handled")
	flag.Parse()

	if file == "" || (extract == list) {
		usage()
	}
	if flag.NArg() != 0 {
		fmt.Fprintf(os.Stderr, "guesttar: refusing extra arguments %q\n", flag.Args())
		os.Exit(2)
	}
	if dir == "" {
		dir = "."
	}
	if err := run(file, dir, extract, list, verbose, excludes); err != nil {
		fmt.Fprintf(os.Stderr, "guesttar: %v\n", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintf(os.Stderr, "usage: tar -x|-t -f <archive> [-C <dir>] [--exclude <glob>]...\n")
	os.Exit(2)
}

func run(file, dir string, extract, list, verbose bool, excludes []string) error {
	f, err := os.Open(file)
	if err != nil {
		return err
	}
	defer f.Close()

	r, err := reader(f)
	if err != nil {
		return err
	}

	tr := tar.NewReader(r)
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return fmt.Errorf("%s: %w", file, err)
		}
		if excluded(hdr.Name, excludes) {
			continue
		}
		if verbose || list {
			fmt.Println(hdr.Name)
		}
		if list {
			continue
		}
		if err := extractOne(tr, hdr, dir); err != nil {
			return fmt.Errorf("%s: %w", hdr.Name, err)
		}
	}
}

// reader detects the compression the way tar does, from the first bytes, so the
// caller does not have to name it. Only gzip: the fixture is named .tar.xz and is
// in fact gzip, and xz has no decoder in the standard library.
func reader(f *os.File) (io.Reader, error) {
	br := bufio.NewReaderSize(f, 1<<16)
	magic, err := br.Peek(2)
	if err != nil && err != io.EOF {
		return nil, err
	}
	if len(magic) == 2 && magic[0] == 0x1f && magic[1] == 0x8b {
		zr, err := gzip.NewReader(br)
		if err != nil {
			return nil, err
		}
		return zr, nil
	}
	return br, nil
}

func excluded(name string, patterns []string) bool {
	for _, p := range patterns {
		if ok, err := filepath.Match(p, name); err == nil && ok {
			return true
		}
		if ok, err := filepath.Match(p, strings.TrimPrefix(name, "./")); err == nil && ok {
			return true
		}
	}
	return false
}

func extractOne(r io.Reader, hdr *tar.Header, dir string) error {
	// Clean and re-root so an entry naming an absolute path or walking out with ..
	// writes inside dir. This is not a sandbox: a symlink entry followed by a file
	// entry through it still escapes, which does not matter for a tarball this
	// repository ships and would matter for an untrusted one.
	name := filepath.Clean(hdr.Name)
	for strings.HasPrefix(name, "../") {
		name = strings.TrimPrefix(name, "../")
	}
	target := filepath.Join(dir, strings.TrimPrefix(name, "/"))

	switch hdr.Typeflag {
	case tar.TypeDir:
		return os.MkdirAll(target, os.FileMode(hdr.Mode)&0o777)
	case tar.TypeReg:
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return err
		}
		out, err := os.OpenFile(target, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, os.FileMode(hdr.Mode)&0o777)
		if err != nil {
			return err
		}
		// A busybox rootfs is full of setuid binaries and hard links written as
		// long names; copying is enough for a container rootfs and is what the
		// guest's own tar would have done.
		if _, err := io.Copy(out, r); err != nil {
			out.Close()
			return err
		}
		return out.Close()
	case tar.TypeSymlink:
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return err
		}
		os.Remove(target)
		return os.Symlink(hdr.Linkname, target)
	case tar.TypeLink:
		src := filepath.Join(dir, strings.TrimPrefix(filepath.Clean(hdr.Linkname), "/"))
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return err
		}
		os.Remove(target)
		return os.Link(src, target)
	case tar.TypeChar, tar.TypeBlock, tar.TypeFifo:
		// The suite's rootfs ships ./dev entries; it extracts with ./dev excluded
		// for exactly this reason.
		return nil
	case tar.TypeXGlobalHeader, tar.TypeXHeader:
		return nil
	default:
		return fmt.Errorf("unsupported tar entry type %q", string(hdr.Typeflag))
	}
}
