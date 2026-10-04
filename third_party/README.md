# third_party

## runc

`runc/` is a fork of [`u-root/runc`](https://github.com/u-root/runc) at
`fc66d646733b11c77772d251a6cb542df8698c06` (the `purego` branch), with its
`.git/` and `vendor/` directories removed.

Upstream's `purego` branch only *deletes* the cgo namespace constructor: its
`libcontainer/nsenter/nsenter.go` is an empty stub under `!cgo`. A
`CGO_ENABLED=0` runc therefore creates no namespaces at all and the container
init dies before reporting its PID — `can't get final child's PID from pipe:
EOF`.

This fork adds a build-tagged pure-Go path:

- `libcontainer/purego_nocgo.go` (`//go:build linux && !cgo`): declares
  `puregoNamespaces = true` and `setCloneFlags(cmd, flags)`, which sets
  `cmd.SysProcAttr.Cloneflags`.
- `libcontainer/purego_cgo.go` (`//go:build linux && cgo`):
  `puregoNamespaces = false` and a no-op `setCloneFlags`, so the cgo build
  behaves exactly as upstream.
- `libcontainer/container_linux.go`, `bootstrapRun`: calls `setCloneFlags`.
- `libcontainer/process_linux.go`, `initProcess.start`: under
  `puregoNamespaces` it uses the direct child PID and skips the bootstrap-data
  write, the PID pipe read, and `waitForChildExit`.
- `libcontainer/seccomp/seccomp_unsupported.go` plus `k4s_nocgo.go` /
  `k4s_strict.go`: seccomp is also cgo-only. kubelet requests `RuntimeDefault`
  on the pod sandbox unconditionally, so the cgo-free build warns and continues
  without seccomp instead of failing every pod. **This means no seccomp
  filtering on a cgo-free node** — see `docs/nsenter-and-runc.md`.

See `docs/nsenter-and-runc.md` for why this works and what it does not cover
(user namespaces).

### Wiring

`go.work` lists it (`use ./third_party/runc`) and `DIT` builds it with
`CGO_ENABLED=0`.

### Moving to a published fork

Push this tree to a fork and point `DIT` at it, so it becomes a normal git
dependency again. The three-file diff is also a reasonable upstream proposal.
