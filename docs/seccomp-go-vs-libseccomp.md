# What the Go seccomp compiler does differently from libseccomp

`libcontainer/seccomp` on the `purego-seccomp` branch of the runc fork compiles
a seccomp profile to classic BPF in Go, so runc can enforce a profile without
cgo and without libseccomp. This document records what that compiler does
*differently* from the libseccomp build, measured by installing both filters
into a real Linux kernel and comparing what the kernel then does with the same
syscalls.

The short version: **995 profile/probe pairs were measured for each build, and
53 of them diverged.** Those 53 reduced to seven root causes. Two of them were
fail-open -- the Go build let through something the libseccomp build stopped --
and the rest are either fail-closed or a hard failure on one side. None of the
seven is a crash; all are semantic.

**Two of the seven are now fixed and the other five are not.** The sections that
follow keep the *before* BPF, because that is what was measured, and say below
the measurement what changed. The re-run on the same kernel and libseccomp gives
**51** divergences, all from the five root causes that were deliberately left
alone; the [status section](#status-after-the-fix) breaks them down.

Nothing was installed on the host. Every filter was installed by a short-lived
child process inside a QEMU VM.

## How this was measured

`libcontainer/seccomp/vmdiff/` is a small harness built from the same source
twice:

| build | how | compiler |
| --- | --- | --- |
| `runner` | `CGO_ENABLED=0` | `bpf_linux.go`, the Go compiler |
| `runner-cgo` | `CGO_ENABLED=1 -tags seccomp` | libseccomp, plus `patchbpf` |

Both are packed into an initramfs with a kernel image and booted under QEMU.
The init process runs both binaries, each of which installs a filter and issues
one raw syscall per (profile, probe) pair, and prints what the kernel returned.
The two reports are then compared line by line.

Why this and not the existing test: `TestAgainstLibseccomp` compares the two
compiled programs **in the `x/net/bpf` interpreter**. That catches a wrong jump
direction, and it is how the 64-bit-argument and `SCMP_CMP_MASKED_EQ` bugs were
found. But the interpreter is not the kernel, it cannot see anything that
depends on `seccomp_data` layout or on the syscall entry path, and it *skips*
the cases where the two builds are known not to agree -- which is exactly where
the interesting differences are. It also cannot see differences that are not in
the program at all, like which syscall *names* resolve.

Design points that make the observations trustworthy:

- **The probe runs in assembly, not in Go.** A filter that denies the Go
  runtime's own syscalls kills the runtime (with a SIGTRAP, via its fatal
  path) before the probe can run; that was the first thing the harness had to
  get past. `probeAndStore` issues the syscall, stores the result into a shared
  memory page and exits, with no Go code in between. The result page is the
  report channel because `write` itself may be filtered.
- **The child is killed by the parent once the answer is stored**, so a filter
  that blocks `exit_group` (or every syscall) cannot stall the harness.
- **`KILL_THREAD` is told from `KILL_PROCESS` by a survivor thread**, because
  killing one thread does not kill a Go process: its other threads keep it
  alive, which is itself observable and is the same on both builds.
- **The child records which profile it installed** and the parent compares that
  with what it expected, so a mis-indexed case cannot silently produce a
  finding.
- **A pair whose child died before issuing the probe is retried**, and reported
  as a harness failure if it keeps happening. Two full runs produce byte-for-byte
  identical reports (modulo the addresses in a Go traceback).

## The divergences, worst first

### 1. A rule for `socket` does not block `socketcall` (fail-open)

On 32-bit architectures that multiplex the socket and System V IPC calls
(i386, mips, ppc, ...), libseccomp does not filter `socket(2)` at all. It
resolves the name to a *pseudo-syscall* and rewrites the rule into one on
`socketcall(2)` with `arg0 == SYS_SOCKET`, and it emits a rule for the direct
32-bit `socket` syscall as well, for kernels new enough to have one. The Go
build has no such notion: its i386 table (from `x/sys/unix`) gives `socket` the
flat number 359 and filters only that.

The profile is `{socket -> ERRNO(EACCES)}` with `SCMP_ARCH_X86` listed. Both
programs, for `AUDIT_ARCH_I386`:

```
; libseccomp
cgo[  8] jeq #359,4          ; direct i386 socket
cgo[  9] jneq #102,2         ; socketcall?
cgo[ 10] ld [16]             ;   arg0
cgo[ 11] jeq #1,1            ;   == SYS_SOCKET?
cgo[ 12] ret #2147418112     ;   ALLOW
cgo[ 13] ret #327693         ;   ERRNO(EACCES)

; Go
go[ 14] ld [0]
go[ 15] jneq #359,1
go[ 16] ret #327693          ; direct i386 socket -> ERRNO(EACCES)
go[ 17] ret #2147418112      ; everything else ALLOW
```

Measured in the VM, `socketcall(SYS_SOCKET, ...)` from a 64-bit process through
`int 0x80`:

| probe | natural | Go build | libseccomp build |
| --- | --- | --- | --- |
| `i386 socketcall(SOCKET)` | `EFAULT` (14) | `EFAULT` (14) -- untouched | `EACCES` (13) -- blocked |

**Direction: fail-open.** A 32-bit process that issues `socketcall` directly --
which is the documented, still-supported interface, and the only one on kernels
older than 4.3 -- is not stopped by a Go-build profile that blocks `socket`.
libseccomp stops it. The same rewriting applies to `bind`, `connect`, `accept4`,
`sendto`, `recvfrom`, `getsockopt`, ... and to the System V IPC calls through
`ipc`, so a profile that blocks those on an i386 process has the same hole.

`libcontainer/seccomp/vmdiff/namecov` shows the same thing one level up: for
`SCMP_ARCH_X86` it reports 27 "number mismatches", and every one of them is a
name libseccomp resolves to a negative pseudo-syscall number (`socket` ->
-101, `bind` -> -102, `msgget` -> -213, ...) where the Go table has a flat
number (359, 361, 399, ...).

*Fixed.* `libcontainer/seccomp/internal/mkpseudosyscalls` extracts libseccomp's
negative pseudo-numbers and generates
`libcontainer/seccomp/pseudosyscalls_linux.go`: for each architecture whose table
has `socketcall`/`ipc`, the syscall names it multiplexes, the multiplexor's
number, and the subcall number computed the way libseccomp computes it --
`(-pseudo) % 100` for the socket family and `% 200` for ipc, which is the
arithmetic `abi_rule_add` in libseccomp's `syscalls.c` performs. The name list is
the Go table's, because a name the Go table does not have is dropped by the
compiler anyway, and the table is generated rather than written down, so it
cannot drift from the libseccomp it was measured against. `compileArchSection`
in `libcontainer/seccomp/bpf_linux.go` emits the multiplexed rule *in addition
to* the flat number, so a kernel with only `socketcall` and one that accepts the
flat number are both covered.

Closing this exposed one thing the section above did not measure: on a 32-bit
architecture libseccomp compares only the low 32 bits of every argument,
because `arch_arg_offset_hi` in libseccomp's `arch.c` returns `EDOM` unless
`arch_def.size` is `ARCH_SIZE_64`. The Go compiler compared the whole 64-bit
value, so a 64-bit process that reached the i386 entry path with `int 0x80` and a
64-bit `arg0` -- `seccomp_data.args` comes from the full registers, `syscall.h`
in the amd64 kernel does not truncate them -- would have run
`socketcall(0x100000001, ...)` through a profile that blocks `socket`, even after
the multiplexed rule was emitted. The compiler now compares the words an
architecture has (`auditArg64Bit`, `bpf_linux.go`).
`TestAgainstLibseccompPseudoSyscall` compares the two builds in the interpreter
over 800 (number, argument) pairs including high-bit arguments, and fails if the
high word is compared on a 32-bit architecture.


### 2. Two rules for one syscall: first match wins, and libseccomp drops one (fail-open)

`matchCall` in the cgo build skips a rule whose action equals the profile's
default action, *regardless of its arguments*, and logs it as redundant. The Go
compiler only skips a rule that both equals the default **and** has no
arguments. So for a profile with two rules on one syscall, the two builds can
end up keeping different rules -- and the Go build keeps them in profile order
and takes the first that matches, while libseccomp keeps the one that survived.

Profile: default `ALLOW`, then `{close, arg0 == 12345, ALLOW}` followed by
`{close, arg0 == 12345, ERRNO(EACCES)}`.

```
; Go: both rules are present, and the ALLOW one is first
go[ 13] jneq #12345,1
go[ 14] ret #2147418112      ; ALLOW  <- reached first
go[ 15] ld [20]
...
go[ 19] ret #327693          ; ERRNO(EACCES)

; libseccomp: the redundant ALLOW is gone, so ERRNO is what is left
cgo[  9] jeq #12345,1
cgo[ 10] ret #2147418112     ; ALLOW (no match)
cgo[ 11] ret #327693         ; ERRNO(EACCES) (match)
```

| probe | natural | Go build | libseccomp build |
| --- | --- | --- | --- |
| `close(12345)` | `EBADF` (9) | `EBADF` (9) -- **allowed** | `EACCES` (13) -- denied |

**Direction: fail-open.** A profile that denies something conditionally and
earlier *allowed* the same syscall and argument is enforced by the cgo build and
ignored by the Go build. The reverse order (`ERRNO` first) agrees, because both
then take the `ERRNO` rule.

*Fixed.* The Go compiler now drops any rule whose action equals the profile's
default action, arguments or not, which is what `matchCall` does in
`libcontainer/seccomp/seccomp_linux.go`. libseccomp's semantics are the ones to
adopt rather than the reverse: the default action already says what the rule
says, so keeping the rule cannot change an outcome except by matching before a
later rule for the same syscall, and that shadowing is the fail-open. The change
is in `compileArchSection` (`bpf_linux.go`), and
`TestDivergence2RedundantRuleDropped` pins it by compiling the profile with and
without the redundant rule and requiring the two programs to be identical.

The `-ENOSYS` stub boundary is computed by `findLastSyscalls`, which walks every
rule, redundant or not -- exactly as libseccomp's `patchbpf` does -- so a dropped
rule still moves the boundary. That is why the remaining boundary divergences are
the ones whose *names* libseccomp cannot resolve (below), not a difference in
which of two rules wins.


### 3. The `-ENOSYS` boundary is computed per implementation, and moves with the name tables

Both builds prepend the `-ENOSYS` stub: a syscall whose number is larger than
any number the profile mentions returns `ENOSYS` instead of the default action,
so libc can fall back from a new syscall to an old one. "Any number the profile
mentions" is computed by resolving each rule's *name* against the
implementation's own table:

- the Go build uses `syscalls_linux.go`, generated from `x/sys/unix`;
- libseccomp uses its own table, via `findLastSyscalls` in `patchbpf`.

When the two tables disagree about a name, the two boundaries disagree, and
every syscall number between them gets a different answer. Two things make the
tables disagree: a name one table does not have (divergence 4), and a rule one
side drops and the other keeps (divergence 2).

Profile: default `ERRNO(EPERM)`, `{clone -> ALLOW}`, `{statmount -> ALLOW}`.

```
; Go: statmount is in the table, so the boundary is 457
go[  5] jgt #457,2
go[  8] ret #327718          ; ENOSYS

; libseccomp: statmount is not a name it knows, so the boundary is clone=56
cgo[  5] jgt #56,2
cgo[  8] ret #327718         ; ENOSYS
```

| probe | natural | Go build | libseccomp build |
| --- | --- | --- | --- |
| `clone3` (435) | `EINVAL` (22) | `EPERM` (1) | `ENOSYS` (38) |
| `openat` (257) | `EFAULT` (14) | `EPERM` (1) | `ENOSYS` (38) |
| `statmount` (457) | `EFAULT` (14) | `EFAULT` (14) | `ENOSYS` (38) |

**Direction: both, and it has a concrete consequence.** `clone3` is the syscall
libc probes for and falls back from. `ENOSYS` is what makes glibc retry with
`clone`, and this profile allows `clone`. So on the libseccomp build a fork
succeeds; on the Go build `clone3` is denied with `EPERM`, there is no fallback,
and the fork fails. The same profile therefore starts a workload under one build
and breaks it under the other.

The other direction is visible too: `stub-boundary-statmount` has no exit rules,
so libseccomp's boundary is 0 and it emits no stub at all, while the Go build's
is 457. There `nr=1000` is `ENOSYS` under the Go build and the default action
under libseccomp.

*Not fixed here.* Closing it means either making the stub boundary independent
of the name tables (e.g. compute it from the *kernel's* numbering and a
profile-wide maximum that both agree on) or making the tables identical.

### 4. Syscall name coverage differs, in both directions

The Go table is generated from the kernel headers that `x/sys/unix` ships;
libseccomp's table comes from its own release. Newer names exist in one and not
the other. On this kernel (6.8) and libseccomp (2.5.5) the observable cases are
all in the direction of **the Go build knowing more**:

| profile | probe | natural | Go build | libseccomp build |
| --- | --- | --- | --- | --- |
| `{statmount -> ERRNO}` | `statmount` | `EFAULT` (14) | `EPERM` (1) | `EFAULT` (14) |
| `{listmount -> ERRNO}` | `listmount` | `EFAULT` (14) | `EPERM` (1) | `EFAULT` (14) |
| `{lsm_list_modules -> ERRNO}` | `lsm_list_modules` | `EFAULT` (14) | `EPERM` (1) | `EFAULT` (14) |
| `{uretprobe -> ERRNO}` | `uretprobe` | `ENOSYS` (38) | `EPERM` (1) | `ENOSYS` (38) |

`statmount`, `listmount` and `lsm_*` were added in Linux 6.8 and are in the Go
table; libseccomp 2.5.5 predates them, so its rule is dropped and the syscall
runs. `uretprobe` (335) is a Linux 6.11 syscall that `x/sys/unix` already has;
this kernel does not implement it, so the difference is invisible in effect
today.

**Direction: fail-closed today** -- the Go build enforces rules the libseccomp
build silently drops. The reverse is possible by construction: any name
libseccomp knows and `x/sys/unix` does not would be a fail-open. The candidates
on amd64 are pseudo-syscalls and aliases (`_llseek`, `socketcall`, `ipc`,
`_newselect`, `fstat64`, ...), and measured here a rule naming `_llseek` or
`socketcall` on amd64 makes *no* difference to either build's behaviour (both
end up not filtering anything for that name), so no fail-open was found on this
kernel. The finding is that the tables are a moving target: the same profile is
enforced differently depending on which `x/sys/unix` and which libseccomp the
build happens to use, and nothing pins them to each other.

The practical hazard is version skew: a rule naming a syscall that the *build's*
table lacks is dropped silently (`logrus.Debugf`, not a warning) on both sides.
For a *deny* rule that is fail-open, and neither implementation treats it as an
error.

*Not fixed here.* Options: resolve names from a single shared table (i.e. ship
libseccomp's table, or generate one for both), or make an unresolvable name in a
profile a hard error rather than a debug log.

### 5. Two conditions on one argument: ANDed, or split into two rules

`matchCall` detects two conditions on the same argument index and, "to revert to
old behavior", adds each as a *separate* rule. The Go compiler ANDs them.

Profile: default `ALLOW`, `{close, arg0 == 12345, arg0 == 12346 -> ERRNO(EACCES)}`.

```
; Go: one rule, both conditions must hold, so it can never match
go[ 13] jneq #12345,5
go[ 17] jneq #12346,1
go[ 18] ret #327693

; libseccomp: two rules, so either value matches
cgo[  9] jeq #12346,2
cgo[ 10] jeq #12345,1
cgo[ 11] ret #2147418112
cgo[ 12] ret #327693
```

| probe | natural | Go build | libseccomp build |
| --- | --- | --- | --- |
| `close(12345)` | `EBADF` (9) | `EBADF` (9) -- allowed | `EACCES` (13) -- denied |

**Direction: fail-open for the Go build in this shape**, though the semantics
are just different: an ANDed pair of contradictory conditions is a rule that
matches nothing, while two rules match either value. Which one a profile author
meant is not decidable from the profile.

### 6. x32, when the profile lists `SCMP_ARCH_X32`

Known and already documented in `docs/nsenter-and-runc.md`; the harness now
confirms it against the kernel rather than the interpreter. An x32 syscall
signals itself with bit 30 of the syscall number, and `seccomp_data.arch` is
`AUDIT_ARCH_X86_64` for both ABIs. `x/sys/unix` carries no x32 table, so the Go
build refuses x32 numbers outright (`KILL_THREAD`). libseccomp, when the profile
lists `SCMP_ARCH_X32`, filters them through its own x32 table.

Profile: `SCMP_ARCH_X32` listed, default `ALLOW`, `{read -> ERRNO(EACCES)}`.

| probe | natural | Go build | libseccomp build |
| --- | --- | --- | --- |
| `x32 read` | `ENOSYS` (38) | killed (no result) | `EACCES` (13) |
| `x32 getpid` | `ENOSYS` (38) | killed (no result) | `ENOSYS` (38) |
| `survivor x32 getpid` | `ENOSYS` (38) | **`thread-killed (process survived)`** | `ENOSYS` (38) |

The last row is the one that says which kill it is: the probe thread died and
another thread of the same process lived on, so the Go build's x32 guard is a
`KILL_THREAD`, not a `KILL_PROCESS`.

**Direction: fail-closed.** The Go build kills x32 syscalls rather than judging
them; libseccomp applies the profile. Both kill x32 numbers when x32 is *not*
listed (`arch-no-x32` agrees exactly), so the difference is only for profiles
that ask for x32 -- which containerd's default profile does. The kernel used
here has `CONFIG_X86_X32_ABI` off, so the ABI is not usable anyway, but the
filter's answer is still observable.

### 7. An architecture libseccomp will not add is a hard failure for the cgo build

`buildFilter` adds every architecture in the profile with `filter.AddArch`, and
returns the error. libseccomp refuses to add an architecture whose **byte order
differs from the native one** (the filter cannot compare `seccomp_data` in both
orders), so on an amd64 host:

| architecture | libseccomp `AddArch` | Go compiler |
| --- | --- | --- |
| amd64, x86, x32, arm, arm64, mipsel, mipsel64, mipsel64n32, ppc64le, riscv64 | ok | ok |
| mips, mips64, ppc, ppc64, s390, s390x | `EDOM` | ok: a section is emitted and can never match on amd64 |
| mips64n32 | `EDOM` | ok: no table, so it is skipped with a warning |
| loongarch64 | not in libseccomp 2.5.5 | `unknown seccomp architecture` |

So a profile that lists, say, `SCMP_ARCH_S390X` alongside the native one -- a
plausible thing for a multi-architecture image's profile -- is **rejected
outright by the cgo build**: `InitSeccomp` returns an error and runc fails the
container. The Go build installs the filter and skips the architecture with a
warning.

| case | Go build | libseccomp build |
| --- | --- | --- |
| `arch-mips64n32-listed` (every probe) | filter installed, native rules enforced | `install-error: error adding architecture to seccomp filter: numerical argument out of domain` |

**Direction: availability, not enforcement.** The Go build is the more permissive
one here, and the extra section it emits for a big-endian architecture can never
match on a little-endian kernel, so the filter is equivalent in effect -- one
build just refuses to start.

*Not fixed here.* Closing it means deciding whether an unusable extra
architecture should be ignored (as the Go build does), rejected (as libseccomp
does), or rejected only when it is also the native one.

## What agrees

The other 942 measured pairs agree, which is worth recording because several of
them are the things that were most likely to be wrong:

- **Argument comparisons**, all seven operators, on 32-bit and 64-bit values,
  with the high half compared and `0x10000002a` not matching a rule for `42`.
  `SCMP_CMP_MASKED_EQ` with the mask in the high half, in the low half, spanning
  both, and against zero.
- **Argument indices** 0 and 5, two conditions on different arguments, and a
  rule whose argument conditions never hold.
- **Actions**: `ALLOW`, `LOG`, `ERRNO` with the default and with a per-rule
  errno, `KILL_THREAD`, `KILL_PROCESS`, `TRAP`, `TRACE`, and `NOTIFY`. The
  errno data bits come out identical. `TRAP` looks the same on both sides
  because the Go runtime turns the SIGSYS into a panic before either build's
  handler could see it.
- **`KILL_THREAD` really kills only the thread** and leaves a threaded process
  running, on both builds; `KILL_PROCESS` takes everything.
- **The bad-architecture action** is `KILL_THREAD` on both, for i386 and x32
  syscalls alike, when the profile lists no matching architecture.
- **The `-ENOSYS` stub is suppressed** when the default action is permissive
  (`ALLOW`, `LOG`, `TRACE`), on both.
- **`DefaultErrnoRet` quirks**: the early-return check compares against the
  *encoded* `SECCOMP_RET_ERRNO|ENOSYS` constant rather than the errno, so a
  `DefaultErrnoRet` of 38 does not suppress the stub. The Go port reproduces
  this exactly, including the fact that the encoded value does suppress it and
  that both then produce the same observable `ENOSYS`.
- **An unknown flag** is refused by both (the Go build has no libseccomp to
  probe, so it refuses at load time).
- **Listing the native architecture explicitly** (as containerd's default
  profile does) is accepted by both.

## Status after the fix

Divergences 1 and 2 are fixed. `libcontainer/seccomp/vmdiff/run.sh` was re-run on
the same kernel (Linux 6.8) and the same libseccomp (2.5.5), over the same 995
pairs, and reports **51** divergences:

| case | pairs | root cause |
| --- | --- | --- |
| `arch-mips64n32-listed` | 20 | 7, libseccomp refuses the architecture |
| `arch-x32-listed` | 3 | 6, x32 |
| `detect-x32-kill` | 1 | 6, x32 |
| `arg-same-index-twice` | 1 | 5, two conditions on one argument |
| `name-statmount-block` | 1 | 4, name coverage |
| `name-listmount-block` | 1 | 4, name coverage |
| `name-lsm-list-modules-block` | 1 | 4, name coverage |
| `name-uretprobe-block` | 1 | 4, name coverage |
| `redundant-argful-errno-rule` | 5 | 3, the `-ENOSYS` boundary (a `statmount` rule raises the Go boundary; libseccomp cannot resolve the name) |
| `stub-boundary-statmount` | 3 | 3 |
| `stub-boundary-redundant-rule` | 4 | 3 |
| `stub-boundary-libc-fallback` | 5 | 3 |
| `stub-with-exit-rules` | 5 | 3 |
| **total** | **51** | |

`arch-x86-listed` and `duplicate-rules-allow-then-errno` no longer appear: they
were the single pair each for divergences 1 and 2.

Every remaining pair is one of the five root causes the work list did not cover.
`libcontainer/seccomp/bpf_linux_divergence_test.go` pins each of the seven root
causes against the compiled program in the `x/net/bpf` interpreter -- the fixed
ones asserting the fixed behaviour, the rest asserting the measured one -- so a
change to any of them is caught in milliseconds without a VM.
`TestAgainstLibseccomp` is not weakened -- it skips nothing new -- and the
x86 argument-operator profile added with the low-word fix makes it compare every
operator on a 32-bit section as well as a 64-bit one.
`TestAgainstLibseccompPseudoSyscall` adds the multiplexor path to that comparison
explicitly. The differential grid already carries high-bit argument values, so a
return of the full-64-bit comparison on a 32-bit architecture is a test failure
and not a silent divergence.

The count is not zero, and the reason is not a compile bug: divergences 3-7 are
name-table and architecture-policy differences between `x/sys/unix` and
libseccomp 2.5.5. Closing 3 and 4 means making the two name tables agree, or
making an unresolvable name in a profile a hard error; closing 6 needs an x32
table; closing 7 needs a policy decision about an architecture whose byte order
differs from the native one; closing 5 needs a decision about whether two
conditions on one argument are an AND or two rules. None of those is a change to
how a rule is compiled, which is what this document set out to measure.

## What the harness cannot see

- **`SECCOMP_FILTER_FLAG_TSYNC` semantics.** The Go build maps the profile's
  `tsync` flag to `SECCOMP_FILTER_FLAG_TSYNC` and otherwise installs with
  `prctl(2)`, which filters only the calling thread; libseccomp always
  synchronises all threads. In runc's flow this does not matter -- the filter is
  installed in the init process and `execve` kills every other thread, leaving
  the filtered one -- but a *multi-threaded* process that installs a filter
  without the flag is filtered on every thread by libseccomp and on one thread
  by the Go build. The harness pins the probe to the installing thread, so it
  does not measure this. It is worth a separate test.
- **`SCMP_ACT_NOTIFY`.** Both install the listener and both block the notified
  syscall; the harness only confirms the two behave the same, not what an agent
  sees.
- **Kernel versions.** The name-table divergences (3 and 4) are a function of
  the kernel, `x/sys/unix` and libseccomp versions. This run is Linux 6.8 with
  libseccomp 2.5.5 and the `x/sys/unix` vendored in this checkout.
- **Other architectures.** Only amd64 (with i386 and x32 entry paths) is
  exercised; the multiplexing divergence (1) is reachable on i386, mips and ppc,
  and was observed through the i386 compat path.

## Reproducing

```
cd runc
libcontainer/seccomp/vmdiff/run.sh [kernel-image]

# a single case, and the full raw reports
VMDIFF_ONLY=duplicate-rules-allow-then-errno ./run.sh
VMDIFF_FULL=1 ./run.sh
```

The kernel image is fetched without root, the same way the project gets
`pahole`:

```
curl -O https://archive.ubuntu.com/ubuntu/pool/main/l/linux/linux-image-unsigned-6.8.0-146-generic_6.8.0-146.146_amd64.deb
dpkg-deb -x linux-image-unsigned-*.deb /tmp/kern
```

To see the two compiled programs for the profiles above, on the host, with no
filter installed:

```
VMDIFF_DIAG=1 CGO_ENABLED=1 go test -tags seccomp -run TestVMDiffDumpPrograms -v ./libcontainer/seccomp/
VMDIFF_DIAG=1 CGO_ENABLED=1 go test -tags seccomp -run TestVMDiffArchCompat -v ./libcontainer/seccomp/
```

The fast tests, which need no VM and no kernel image. The first runs the pins
for all seven root causes in the interpreter; the second adds the
comparison against libseccomp (and so needs libseccomp and its headers):

```
CGO_ENABLED=0 go test ./libcontainer/seccomp/
CGO_ENABLED=1 go test -tags seccomp ./libcontainer/seccomp/
```

And to regenerate the multiplexor table from libseccomp (it rewrites
`libcontainer/seccomp/pseudosyscalls_linux.go` in place):

```
CGO_ENABLED=1 go run -tags seccomp ./libcontainer/seccomp/internal/mkpseudosyscalls
```
