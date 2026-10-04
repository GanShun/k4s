# nsenter and running runc without cgo

This note explains why container runtimes are normally C/cgo, why the u-root
`purego` runc fails, and how `third_party/runc` makes a `CGO_ENABLED=0` runc
work for rootful containers.

## What `nsenter` is

It is **not** the util-linux `nsenter(1)` command. It is runc's internal
`libcontainer/nsenter` package, whose implementation is `nsexec.c` (~1200
lines). On upstream runc, `nsenter.go` is a cgo file whose only job is to
register a C *constructor*:

```go
//go:build linux && !gccgo
package nsenter
/*
#cgo CFLAGS: -Wall
extern void nsexec();
void __attribute__((constructor)) init(void) { nsexec(); }
*/
import "C"
```

A constructor runs **before the Go runtime boots**, in the `runc init`
process. That timing is the whole point: `setns(2)`/`unshare(2)` act on a
single thread, and you cannot move a multithreaded process between namespaces.
Go's runtime is multithreaded from startup, so the namespace work has to happen
before it exists.

### The three stages

`nsexec.c` is one function driven by `setjmp`/`clone`, communicating over
pipes. The stages show up in `ps`:

- `runc:[0:PARENT]` — `clone_parent()`s stage 1 with the namespace flags. For a
  user namespace it stays behind to write the child's `uid_map`/`gid_map`
  (entering a userns drops your capabilities in the old one, so the parent must
  do this). It forwards the final PID to `runc create`.
- `runc:[1:CHILD]` — `setns()` into joined namespaces; `unshare(CLONE_NEWUSER)`
  **first**, then the rest separately; double-forks to enter the PID namespace
  (a PID namespace only applies to children). It sends stage 2's PID to stage 0
  and exits.
- `runc:[2:INIT]` — the container init. The constructor returns, the Go runtime
  starts, and `libcontainer/init_linux.go` continues in the right namespaces.

The awkwardness is documented in the source: userns capability drops, the
PID-namespace double-fork, SELinux/mqueue label ordering, and old kernel bugs
where `CLONE_NEWUSER` was not handled before the other namespaces.

## Why `!cgo` fails today

The parent (`libcontainer/process_linux.go`, `initProcess.start`) encodes the
clone flags and namespace paths as netlink `bootstrapData` and writes them to
the init pipe. The **constructor** consumes that, creates the namespaces, and
writes `{"stage1_pid":N,"stage2_pid":M}` back. The parent reads that PID with
`getChildPid()`.

With no constructor, the flags are never applied, nobody writes the PID, and
the parent fails reading the pipe. u-root's `purego` branch leaves the
constructor empty and nothing in its place.

## The pure-Go path

Two things are needed, and both are on the **parent** side:

1. Create the namespaces with Go's own `clone(2)` support. `os/exec` can do
   this: `cmd.SysProcAttr.Cloneflags = namespaces.CloneFlags()`. The child is
   then created directly in the namespaces, and for `CLONE_NEWPID` it *is*
   PID 1 — no double-fork.
2. Because the direct child is now the container init, use its PID
   (`cmd.Process.Pid`) instead of the constructor's pipe report, and skip
   `waitForChildExit` (there is no intermediate stage-0 to reap). Do not write
   `bootstrapData`; nothing consumes it, and it would desync the child's read
   of the `initConfig` JSON that follows on the same pipe.

That is the whole change (`third_party/runc`). The child is untouched: its Go
`startInitialization()` already decodes `initConfig` and runs the
`procReady`/`procRun` sync.

### Evidence

A standalone probe proved the premise in the guest:

```go
cmd.SysProcAttr = &syscall.SysProcAttr{
    Chroot: rootfs,
    Cloneflags: CLONE_NEWNS|CLONE_NEWUTS|CLONE_NEWIPC|
                CLONE_NEWNET|CLONE_NEWPID|CLONE_NEWCGROUP,
}
```

ran a chrooted static binary (`NS_PROBE_OK`). Then the patched runc, built
`CGO_ENABLED=0`, ran a container through containerd, and inside it
`/proc/self/status` reported `Pid: 1` with its own PID-namespace inode — real
isolation, not the host's namespaces.

## What is not covered

- **User namespaces / rootless.** A single `clone(2)` with `CLONE_NEWUSER`
  plus the other namespaces returns `EPERM`; that is exactly the ordering
  nsexec works around (unshare userns -> parent maps uid/gid -> unshare the
  rest). The fork does not do this, so rootless containers do not work yet.
  The node runs containers as root, so this does not block it. `SysProcAttr`
  does support `UidMappings`/`GidMappings`; the staging is the missing part.
- **`runc exec` / setns path** (`setnsProcess`), checkpoint/restore (CRIU), and
  the mount-source remapping handshake — only the `create`/`run` path was
  exercised.
- Configurations that force a real `setns`/double-fork will need the PID
  reporting built back.

## Related: cgroup v1 vs v2

Separately, u-root's init mounts cgroup **v1** controllers, which binds `cpu`,
`pids` and `io` to v1 and leaves cgroup v2 with only `cpuset` and `memory`, so
runc fails with `openat2 .../cpu.weight: no such file or directory`. Booting
with `cgroup_no_v1=all` gives v2 the full controller set. This is in the QEMU
command lines in `scripts/test-boot.sh` and the `Makefile`.
