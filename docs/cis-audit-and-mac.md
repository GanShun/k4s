# auditd and MAC: what they are for, and whether this node needs either

**Subject:** the node image built by this repository — `tinyconfig`-based Linux
kernel plus a u-root initramfs carrying containerd, the pure-Go runc fork,
kubelet, flannel/Cilium and `cmd/uinit` as the bring-up program.
**Question:** the owner's, verbatim — *"Explore in detail what this is used for,
and if it even makes sense here. Is it a hard requirement?"*
**Companion:** `cis-level2-hardening.md` is the assessment; this file is the
argument behind two of its open decisions (§10 questions 4 and 5 there). Control
IDs, titles and the 17/5 status counts are taken from it; nothing here
re-assesses a control, and no code, fragment, build file or config was changed.

Evidence markers: **[verified]** — read in a file, a resolved config or a
command's output cited below; **[inferred]** — kernel or upstream default not
observed running; **[unmeasured]** — a cost I did not build or time;
**[unknown]** — stated without verification, or not obtainable here;
**[external]** — a fact about software not present in this tree.

---

## 1. The answer up front

| | auditd | MAC (SELinux / AppArmor) |
| --- | --- | --- |
| **What it is for** | A kernel-side record of syscalls, file access and security events, filtered by rules, carrying the login uid of the actor — so a privileged action can be attributed after the fact. Detection and forensics, not prevention. | A policy engine evaluated in the kernel *after* DAC and capabilities, so that a process with `CAP_DAC_OVERRIDE` is still told what it may open, execute, mount or signal. Prevention, not detection. |
| **Does it make sense here** | **No.** 7 of the benchmark's 10 audit-rule controls cannot produce a record on this node at all — 3 name objects that do not exist, and 4 filter on a login uid that this node never sets. The 3 that remain are file watches. | **SELinux: no** — it needs a labelled filesystem, and the rootfs is ramfs, which stores no extended attributes. **AppArmor: marginally**, and not for the CIS score; the fork already enforces profiles, but the value is defence-in-depth on a node whose real holes are elsewhere. |
| **Is it a hard requirement** | **No.** Nothing compels it. | **No.** Same. |

**"Useful" and "required" are different questions, and for both mechanisms the
answer to the first is weak and to the second is no.** CIS is a voluntary
benchmark: a profile someone else sells, not a regulation. Conformance is a
business decision. What would make either hard is a compliance regime or a
contract naming it (§4), not the benchmark.

**The strongest single finding is not a theme, it is an arithmetic one.** The
benchmark's own audit rules are written for a host with interactive logins: they
filter on `auid`, and `auid` is set only when a process logs in. This node has no
login program, no PAM, and an SSH server that authenticates a key and execs
`/bin/sh` without setting `loginuid`. So the record the rules ask for is
excluded by the rules themselves. See §2.2.1.

**What would change the answer:** a contract or auditor requiring host-level
audit (§4), and — for AppArmor only — a requirement to confine workloads beyond
capabilities plus seccomp. Neither exists today.

---

## 2. auditd

### 2.1 What it is, mechanically

| Piece | What it is | On this node |
| --- | --- | --- |
| Kernel subsystem | `CONFIG_AUDIT`, with system-call auditing as `CONFIG_AUDITSYSCALL` (`linux/init/Kconfig:539-554`) | `# CONFIG_AUDIT is not set` (`build/kernel/.config:66`); `CONFIG_HAVE_ARCH_AUDITSYSCALL=y` (`:67`) and `CONFIG_AUDIT_ARCH=y` (`:320`) mean the arch supports it, nothing is compiled in. |
| Record stream | Multicast netlink group; a userspace consumer subscribes. Any event nobody reads is queued and then dropped. | No consumer, no socket use. |
| Rule types | (a) syscall rules — `-a always,exit -S chmod -F auid>=500 …`; (b) file watches — `-w /etc/passwd -p wa`; (c) exclude rules — `-a never,…`. All keyed and filtered in the kernel. | None. There is no `/etc/audit/rules.d`; `/etc` is a tmpfs bind of `/tmp/etc` (`u-root/pkg/libinit/root_linux.go:152-153`), so rules would have to be written at boot. |
| Immutable mode | `-e 2` locks the rule set until reboot. | Nothing to lock. Fits this node's reboot model well if rules ever exist. |
| Enable switch | `audit_enabled` starts `AUDIT_OFF` (`linux/kernel/audit.c:76`); `audit=1` on the cmdline (`audit.c:1801`) or a userspace `auditctl` turns it on. | The test cmdlines are `console=ttyS0,115200 panic=-1 cgroup_no_v1=all` (`Makefile:45`) and the same plus `tsc=unstable` (`scripts/test-boot.sh:87`); neither carries `audit=1`. With `CONFIG_AUDIT` unset the `audit=` parameter is not even registered. |

**What it does not do** — these matter more here than what it does:

- **It does not capture what it has no rule for.** It is not a full syscall log;
  a boot with no rules produces almost nothing.
- **It does not refuse anything.** That is MAC's half (§3). Audit changes no
  outcome.
- **It does not identify a container or a pod.** A record carries pid, comm,
  ppid and uid/auid/gid, but not a container or pod identity; container syscalls
  appear in the host stream indistinguishable from host processes.
- **It does not survive its own backlog.** The kernel queue defaults to **64
  records** with a 60-second wait (`linux/kernel/audit.c:132-134`); when it
  fills, records are lost and a rate-limited `audit_lost=… audit_backlog_limit=…`
  warning is printed (`audit.c:417-420`). On a container host with permission
  rules, 64 records is a fraction of a second.
- **It does not record content, memory, or network payloads.** Only the fact of
  an access, and the path.

### 2.2 Do the objects the CIS audit controls name exist here?

This is the crux. Per control, from `cis-level2-hardening.md`, with the object
the control's rule actually names:

| Control | The object the rule names | On this node | Verdict |
| --- | --- | --- | --- |
| 4.1.1.1 | `max_log_file` in `/etc/audit/auditd.conf` | no auditd, no `/etc/audit`, no `/var/log/audit` **[verified]** (`cpio -it`, `build/kernel/.config:66`) | absent — daemon plumbing |
| 4.1.1.2 | `admin_space_left_action = halt` | as above | absent — and on tmpfs "halt when full" would be a self-inflicted outage |
| 4.1.1.3 | `max_log_file_action = keep_logs` | as above | absent — on tmpfs the log dies at reboot regardless |
| 4.1.2 | `auditd` (the InSpec check is `package(p)`, `4_1_configure_system_accounting_auditd.rb:87-96`) | no `audit*` binary or `bb` applet in the image; no package manager **[verified]** | absent — daemon |
| 4.1.3 | `service('auditd')` enabled and running (`:112-114`) | no service manager; the node role of `uinit` starts three daemons — sshd, containerd, kubelet (`cmd/uinit/main.go:84,131,139`) | absent — daemon |
| 4.1.4 | `audit=1` on the cmdline | not present; parameter unregistered without `CONFIG_AUDIT` **[verified]** | **restorable with one kernel symbol + one token** |
| 4.1.5 | `adjtimex`, `settimeofday`, `clock_settime`, `-w /etc/localtime` | syscalls exist; `/etc/localtime` is in the image (127 bytes); `date`, `hwclock`, `ntpdate` applets are in `bbin` **[verified]** | **real content** |
| 4.1.6 | `-w` on `/etc/passwd`, `/etc/group`, `/etc/shadow`, `/etc/gshadow`, `/etc/security/opasswd` | `passwd` and `group` exist, mode 0664, on the writable `/etc` tmpfs bind; the other three files do not; `useradd`/`usermod`/`groupadd`/`passwd` applets are **not** in the image **[verified]** | partly real — a watch fires only if node root edits by hand |
| 4.1.7 | `sethostname`/`setdomainname`, `/etc/hosts`, `/etc/resolv.conf`, `/etc/issue(.net)`, `/etc/sysconfig/network` | `hosts` + `resolv.conf` exist; `uinit` rewrites `resolv.conf` every boot (`cmd/uinit/main.go:79,168`); kubelet sets the hostname (`--hostname-override`, `main.go:139-143`); `issue*` and `/etc/sysconfig` do not exist **[verified]** | **real content** |
| 4.1.8 | `/etc/selinux`, `/usr/share/selinux`, `/etc/apparmor(.d)` | none exist (`build/kernel/.config:2660`) **[verified]** | void — already `not applicable` in the assessment |
| 4.1.9 | `/var/log/faillog`, `lastlog`, `tallylog` | none exist; there is no `login(1)`; u-root's sshd is key-only **[verified]** | void |
| 4.1.10 | `/var/run/utmp`, `/var/log/wtmp`, `/var/log/btmp` | none exist **[verified]** | void |
| 4.1.11 | chmod/chown/setxattr rules filtered `auid>=500` **and `auid!=4294967295`** (`4_1_…rb:273-280`) | the syscalls happen constantly under `/var/lib` and `/run`; the `auid` never matches | **inert** — see §2.2.1 |
| 4.1.12 | `open`/`openat` returning `EACCES`/`EPERM`, same filters (`:290-300`) | the syscalls happen; the `auid` never matches | **inert** |
| 4.1.13 | `-F path=` for every file `find / -perm -4000 -o -perm -2000` returns (`:337`) | `cpio -itv` shows no setuid or setgid file in the image, so the generated rule set is **empty** **[verified]** | **void** |
| 4.1.14 | `mount`, filters `auid>=500`, `auid!=4294967295` (`:355-360`) | mounts happen: `uinit` mounts cgroup2 and three tmpfs (`cmd/uinit/main.go:100-128`), containerd mounts per container | **inert** |
| 4.1.15 | `unlink`/`unlinkat`/`rename`/`renameat`, same filters (`:376-381`) | the syscalls happen | **inert** |
| 4.1.16 | `/etc/sudoers`, `/etc/sudoers.d` | no `sudo`, no such file, no `su` applet **[verified]** | void — already `not applicable` |
| 4.1.17 | `/var/log/sudo.log` | none | void — already `not applicable` |
| 4.1.18 | `init_module`, `finit_module`, `delete_module` | `# CONFIG_MODULES is not set` (`build/kernel/.config:771`) — the syscalls are not implemented | void — already `not applicable`, and stronger than a rule |
| 4.1.19 | `-e 2` in the rule file | no rules | becomes trivial once rules exist |

#### 2.2.1 Why four of the ten rule controls can never fire here

- The benchmark's permission, access, mount and delete rules all end in
  `-F auid!=4294967295` (`4_1_configure_system_accounting_auditd.rb:273-280`,
  `:290-300`, `:355-360`, `:376-381`). `4294967295` is the value of an unset
  login uid, excluded by design so that daemons do not flood the log.
- `auid` is `current->loginuid`. It is set by a write to `/proc/self/loginuid`
  (`audit_set_loginuid`, `linux/include/linux/audit.h:209`), which login/PAM/sshd
  do. Nothing in this image does: `grep -rn loginuid u-root/ cmd/` finds
  nothing; u-root's sshd authenticates a public key and execs `/bin/sh`
  (`u-root/cmds/core/sshd/sshd.go:175`, `const_unix.go:9`) with no PAM and no
  session setup.
- With audit compiled out, `loginuid` reads as `INVALID_UID`
  (`linux/include/linux/audit.h:285-288`). With it compiled in and never set, it
  is `4294967295`. The rule comparator is a plain unsigned compare
  (`linux/kernel/auditfilter.c:1231-1250`), so `auid != 4294967295` is false and
  the rule does not fire. **[verified by code reading, not by a boot]**
- Consequence: **even with `auditd` installed and the benchmark's rules applied
  verbatim, 4.1.11, 4.1.12, 4.1.14 and 4.1.15 would produce zero records on this
  node.** A bespoke rule set would have to drop those filters — at which point it
  is no longer the benchmark's rule set, and the noise becomes the problem
  (§2.4).

**Tally of the 17 `non-compliant` audit controls:** 6 are the daemon and its
configuration (4.1.1.1–4.1.1.3, 4.1.2, 4.1.3, 4.1.19); 1 is the kernel cmdline
(4.1.4); of the 10 rules, **3 are void** (4.1.9, 4.1.10, 4.1.13), **4 are inert**
(4.1.11, 4.1.12, 4.1.14, 4.1.15), and **3 have real content** (4.1.5, 4.1.6,
4.1.7). The substantive audit work available on this node is three file-watch
families and the time/hostname syscall rules — once a daemon and a destination
exist.

### 2.3 What auditd would buy against this node's plausible threats

| Threat | Covered? | Why |
| --- | --- | --- |
| Container escape | **Partly, after the fact.** | It is post-hoc: the escape has to happen, and a rule has to cover the syscall, and the record has to survive the reboot. The rules that would matter (`mount`, `unshare`, `setns`, `bpf`) are exactly the ones the benchmark filters on `auid`. A bespoke set could catch them; nothing prevents the escape. |
| Compromised workload | **Weakly.** | Its syscalls are host events, so they are visible. But a record carries pid/comm, not a pod or container id, so attribution means correlating with the kubelet/containerd logs by pid, and everything is lost at reboot unless shipped. |
| Compromised image at pull time | **No.** | The pull is HTTPS into tmpfs; the control that matters is image signature verification, which the roadmap already lists as an open risk. Audit would log file writes in `/var/lib/containerd` and nothing about provenance. |
| Build-supply-chain compromise | **No.** | That happens in CI, not on the node. |
| M3 model-weight exfiltration | **No.** | No `auid`, no content, and the copy is performed by a legitimately privileged process; the mechanisms that matter are egress control, the kill path and hardware trust. |
| Node root compromise (console shell, stolen SSH key) | **No.** | Root can read, stop or outwait the daemon, and can reboot the node. `-e 2` protects the rules, not the log or the boot. |

**In one line: auditd's genuine strengths — attribution to a person, and
tamper-resistance that survives the actor — both depend on there being a person
and a persistent log, and this node has neither by design.**

### 2.4 What it would cost

- **Kernel.** One line in `configs/k4s-tiny.config`: `CONFIG_AUDIT=y`.
  `CONFIG_AUDITSYSCALL` is `def_bool y` given `HAVE_ARCH_AUDITSYSCALL`
  (`linux/init/Kconfig:551-554`) and `select`s `FSNOTIFY`, so the second symbol
  is free. Size impact **[unmeasured]** — no kernel was built for this document;
  the current `build/kernel/arch/x86/boot/bzImage` is 4,469,760 bytes as the
  baseline.
- **Consumer.** `auditd` is `linux-audit/audit-userspace`: C, autotools
  **[external]**, not in this tree. Every executable in the image today is Go:
  four binaries — `bb`, `runc`, `kubelet`, `containerd-shim-runc-v2`
  (`DIT:191-211`), with the 121 `/bbin` names and the `/init`, `/bin/sh`,
  `/bin/defaultsh` entries being symlinks into `bb` — so `auditd` would be the first
  non-Go program in the userland, with its own config format and its own
  packaging problem (no package manager, no libc).
  A Go netlink client is the in-model alternative:
  `github.com/elastic/go-libaudit/v2` resolves on the module proxy (v2.6.2)
  **[verified]**, and whether it builds `CGO_ENABLED=0` against this `go.work`
  is **[unverified]**.
- **Rules, every boot.** There is no `/etc/audit/rules.d` and `/etc` is a tmpfs
  bind, so rules must be re-applied on every boot by `uinit` (one more `step()`
  call, or a rules file carried in the image and fed to the client).
- **Destination.** Every log on this node is a file under `/tmp`
  (`cmd/uinit/main.go:44-46`) and dies at reboot. Audit records would be the
  same until M2 log shipping exists (`docs/roadmap.md`, M2). Without it, the log
  is a within-boot artifact.
- **Backpressure.** Default queue 64 records, 60 s wait
  (`linux/kernel/audit.c:132-134`). With `chmod`/`open`-failure/`mount` rules on
  a container host the queue is permanently saturated, and the failure mode is
  *dropped records plus a rate-limited console warning*
  (`audit.c:417-420`) — i.e. silently incomplete, on a console nobody reads.
- **4.1.1.2 as written is a RAM-only trap.** "Halt when the audit log is full"
  becomes "halt when a tmpfs fills", which is a workload-triggered outage.

### 2.5 What is already available instead

| Mechanism | Status here **[verified]** | Would replace | Would not replace |
| --- | --- | --- | --- |
| Per-container seccomp filter | `CONFIG_SECCOMP(_FILTER)=y` (`configs/k4s-tiny.config:89-90`); kubelet `seccompDefault: true` (`configs/node/kubelet.yaml:15`); the fork compiles the profile to BPF in Go (`libcontainer/seccomp/bpf_linux.go`); the cluster test asserts `Seccomp: 2`. | Per-syscall *denial* for containers | Anything about the node's own daemons; anything about files |
| `SCMP_ACT_LOG` / `SECCOMP_RET_LOG` | The Go compiler maps it (`libcontainer/seccomp/bpf_linux.go:91,129`; cgo path `seccomp_linux.go:223`) — but the kernel routes it through `audit_seccomp()`, which is an empty stub when `CONFIG_AUDITSYSCALL` is off (`linux/include/linux/audit.h:648-650`, called from `linux/kernel/seccomp.c:1048`). **Today it logs nothing.** | A per-syscall audit trail *without a daemon*, if `CONFIG_AUDIT` were on | File watches; `auid` attribution |
| `fanotify` | `CONFIG_FANOTIFY=y`, `CONFIG_FANOTIFY_ACCESS_PERMISSIONS` **not set** (`build/kernel/.config:2525-2526`) | File-change notification for a Go watcher (needs `CAP_SYS_ADMIN`) | Kernel-side rule semantics; permission decisions |
| eBPF | `CONFIG_BPF_SYSCALL=y` (`:118`), `KPROBES=y`, `UPROBES=y`, `BPF_EVENTS=y`, `DEBUG_INFO_BTF=y` (`:3005`) — the whole kprobe+BTF stack a Tetragon-style tracer needs | Syscall and behaviour tracing, cheap, in Go/eBPF **[nothing of it is in the image]** | Nothing yet built |
| `dmesg` / printk | `CONFIG_PRINTK=y`; `bbin/dmesg`, `bbin/strace` present | Crash, OOM and driver evidence | A rule system; survives no reboot |
| containerd / kubelet logs | `/tmp/containerd.log`, `/tmp/kubelet.log`, `/tmp/sshd.log` (`cmd/uinit/main.go:44-46`) | Service-level record of what the runtime did | Survive no reboot; no shipping |
| **Kubernetes apiserver audit** | Not configured: the control plane's apiserver flags carry no `--audit-policy-file` or `--audit-log-path` (`cmd/uinit/main.go:190-204`) | "Who changed what" in the cluster — *the* artifact auditors of Kubernetes clusters ask for | Host-level syscall events |
| Log shipping (M2) | Planned, not built (`docs/roadmap.md`, "M2 — Ephemeral hygiene") | Makes any of the above survivable | — |

**The ordering this suggests:** ship logs off-box (M2) *first*. Every logging
mechanism on this node — audit or not — is worthless across a reboot without it,
and it is cheaper than the audit subsystem. This is the same conclusion
`cis-level2-hardening.md:2293` reaches from the scoring side.

---

## 3. MAC — SELinux and AppArmor

*Citations below beginning with `libcontainer/`, or naming `utils_linux.go`, are
paths in the sibling runc checkout `../runc`; the rest are in this repository.*

### 3.1 What confines a root process in a container here today

| Layer | Setting **[verified]** | What it actually stops |
| --- | --- | --- |
| Namespaces | pid, ipc, uts, mount, net (`containerd/pkg/oci/spec.go:136-156`); **no user namespace** | Seeing and affecting host processes, mounts, network, hostname. Not privilege. |
| Capabilities | 14 defaults — `CHOWN`, `DAC_OVERRIDE`, `FSETID`, `FOWNER`, `MKNOD`, `NET_RAW`, `SETGID`, `SETUID`, `SETFCAP`, `SETPCAP`, `NET_BIND_SERVICE`, `SYS_CHROOT`, `KILL`, `AUDIT_WRITE` (`containerd/pkg/oci/spec.go:118-133`) | No `CAP_SYS_ADMIN`, no `CAP_SYS_MODULE`, no `CAP_SYS_PTRACE`, no `CAP_SYS_BOOT`. **This is the real boundary.** |
| Seccomp | `RuntimeDefault`: deny-by-default with `ActErrno` (`containerd/contrib/seccomp/seccomp_default.go:502`), an allowlist that still permits `mount`, `unshare`, `setns`, `bpf`, `init_module`, `open_by_handle_at`, `perf_event_open`, `clone3` and `ptrace` (allowlist in the same file; `ptrace` is appended for kernels ≥ 4.8 at `:509-520`) | Only syscalls that would be dangerous *without* a capability check. It is a backstop against a missing/mis-scoped cap check, not a boundary of its own. |
| `no_new_privs` | Set only when the pod sets `allowPrivilegeEscalation: false` (`kubernetes/pkg/securitycontext/util.go:179-191` → `containerd/internal/cri/server/container_create.go:866-870` → `libcontainer/standard_init_linux.go:157`). **None of the example pods set it** (`examples/*.yaml`, no `securityContext.allowPrivilegeEscalation`) | Blocking setuid/file-capability regain. Today: not blocking anything. |
| Kernel surface | `# CONFIG_MODULES is not set` (`:771`), `# CONFIG_DEVMEM` (`:2010`), `# CONFIG_PROC_KCORE` (`:2564`); `/proc/sys` read-only and `/proc/kcore` masked in the container (`kubernetes/pkg/securitycontext/util.go:196-223`) | Module loading, `/dev/mem`, kcore. Real and free. |
| MAC | **Nothing.** `# CONFIG_SECURITY is not set` (`:2660`), which removes the LSM framework itself: no SELinux, AppArmor, Yama, Landlock, LoadPin. | Nothing. Every process on the node, host or container, is unconfined. |

**The question to test — "with root inside a container, what constrains it?"** —
answers: the capability set, then namespaces, then the kernel's own checks. Not
a policy layer. A container that obtains `CAP_SYS_ADMIN` (a `privileged: true`
pod, e.g. the flannel DaemonSet at `examples/flannel-ds.yaml:77`) is constrained
by nothing but seccomp's allowlist, which permits `mount`, `unshare`, `setns`
and `bpf`.

### 3.2 What MAC buys that this node does not have — and what it does not

**Buys:** a policy layer evaluated *after* DAC and capabilities, so it survives a
process gaining a capability. Path- or label-based rules can deny `mount`,
writes to `/sys` and `/proc/sys`, opening `/proc/*/mem`, executing files from a
world-writable tmpfs — for a root process that already holds the capability
that would otherwise allow it. It is the only layer listed in §3.1 that would
constrain a *host* daemon (containerd, kubelet, runc, sshd) as well as a
container.

**Does not buy:**

- **Escape prevention proper.** MAC is in the same kernel as the bug being
  exploited. It raises the cost of *post-compromise* action and cannot stop a
  memory-corruption exploit that reaches its own syscalls directly.
- **Anything for containers without a per-container profile.** A host-wide
  profile does not cover containers; containerd must pass a profile per pod
  (§3.4), so the work is per-workload, not per-node.
- **Detection or retention.** That is audit's half (§2), and there is no
  shipping.
- **Any of the CIS MAC score, cheaply.** 1.6.2.2 and 1.6.2.3 are SELinux-specific
  and unreachable here (§3.3); 1.6.1.1 asks for a distro *package* — its InSpec
  check is `package(p)` for `libselinux`, `libselinux1`, `apparmor`
  (`docs/cis/references/dev-sec-cis-dil-benchmark/controls/1_6_mandatory_access_control.rb:33-34`)
  — which an image with no package manager cannot satisfy in the benchmark's own
  terms; 1.6.3.2 ("all profiles
  enforcing") is vacuous until profiles exist; **1.6.2.6 ("no unconfined
  daemons") is the only one with real substance**, and today every daemon is
  unconfined.

### 3.3 SELinux: what it would take, and why it is out

- **Kernel:** `CONFIG_SECURITY=y` then `CONFIG_SECURITY_SELINUX=y`, which
  `depends on SECURITY_NETWORK && AUDIT && NET && INET`
  (`linux/security/selinux/Kconfig:2-4`) — so it drags in the whole audit
  subsystem as a dependency, plus `NETWORK_SECMARK`.
- **A labelled filesystem.** The Kconfig help says so in as many words ("you
  will also need a policy configuration and a labeled filesystem",
  `Kconfig:9`). This node's root is the initramfs `ramfs`, and **ramfs in this
  tree registers no extended-attribute handlers at all** — `grep -rn xattr
  linux/fs/ramfs/` returns nothing, and its inode operations are
  `setattr` only (`linux/fs/ramfs/file-mmu.c:52-53`). A file label cannot be
  stored, so `label.SetFileLabel` (`libcontainer/rootfs_linux.go:657`) has
  nowhere to put it. **[the exact failure mode — hard error or silent no-op —
  untested; that it cannot succeed is verified]**
- **And every boot re-unpacks the image**, so even on a label-capable filesystem
  every file would have to be relabelled at boot, before any labelled service
  starts.
- **Policy:** the reference policy is a large, distro-maintained artefact built
  with C/autotools tooling and a compiler **[external]**; nothing of it is in
  this tree and nothing of it is Go.
- **Verdict: not viable on this filesystem.** Closing 1.6.2.2/1.6.2.3 would mean
  replacing the root filesystem, which is a design change, not a hardening
  change.

### 3.4 AppArmor: what it would take — and the part that is already done

**Already done, in the fork, cgo-free [verified by code]:**

- `libcontainer/apparmor/apparmor_linux.go:30-58` reimplements libapparmor's
  `aa_change_onexec` in Go: it writes `exec <profile>` to
  `/proc/thread-self/attr/apparmor/exec` (falling back to the pre-`attr/apparmor/`
  path). No cgo, no `libapparmor`.
- It is applied to every process the runtime starts: the container init
  (`libcontainer/standard_init_linux.go:132`) and the exec path
  (`libcontainer/setns_init_linux.go:122`), so `runc exec` and lifecycle hooks
  are covered by the same call.
- The profile reaches it from the OCI spec's `process.apparmorProfile`:
  `utils_linux.go:50-64` (`AppArmorProfile: p.ApparmorProfile`) →
  `libcontainer/container_linux.go:736` (process overrides the container config).
  containerd sets exactly that field
  (`containerd/pkg/oci/spec_opts.go:1282-1285`) from the CRI security context
  (`containerd/internal/cri/server/container_create_linux.go:66-81`).
- **Nothing needs to be added to the fork for AppArmor enforcement.**
  **[code path verified; no container has ever run under a profile on this
  node]**

**What is missing, in three separate pieces:**

| Piece | What it needs | Cost / blocker |
| --- | --- | --- |
| Kernel | `CONFIG_SECURITY=y`, `CONFIG_SECURITY_APPARMOR=y`. The latter `select`s `AUDIT`, `SECURITY_PATH`, `SECURITYFS`, `SECURITY_NETWORK` (`linux/security/apparmor/Kconfig:2-8`) — **so adopting AppArmor enables the audit subsystem as a dependency, whether or not anything consumes it**. `CONFIG_LSM`'s default order already includes `apparmor` (`linux/security/Kconfig:275`), so no ordering work. `SECURITYFS` is not set today (`:2661`) but u-root already mounts securityfs at `/sys/kernel/security` (`u-root/pkg/libinit/root_linux.go:148`), so the mount point exists. Size **[unmeasured]**. |
| Loader | The kernel accepts only the **compiled** policy blob — a versioned binary format, interface v5–v9 (`linux/security/apparmor/policy_unpack.c:1435-1457`), written to `.load`/`.replace` in securityfs (`apparmorfs.c:2774-2786`). The compiler is `apparmor_parser`, C++ **[external]**, and containerd will not consider AppArmor enabled unless **`/sbin/apparmor_parser` exists** (`containerd/pkg/apparmor/apparmor_linux.go:38`) — because it expects to load profiles by name at container-create time. So either that binary ships (the first non-Go executable in the image), or containerd's check is patched and the image carries pre-compiled blobs written by a small Go program **[untested]**. |
| Profiles | The policy itself. A `docker-default`-equivalent for ordinary workloads, plus one per host daemon if 1.6.2.6 is the goal: `containerd`, `kubelet`, `runc` (which re-execs itself as the container init), `sshd`, `uinit`. Authoring and testing those is the real cost — larger than the kernel change. |

**Failure behaviour today is good news:** because AppArmor is absent, a pod that
asks for a profile fails loudly rather than silently running unconfined
(`containerd/internal/cri/sputil/apparmor_linux.go:41-51`), and no manifest in
`examples/` asks for one.

### 3.5 Does it make sense here — the honest judgement

Against the workloads that actually exist:

- `examples/smoke-pod.yaml` runs as **root** (no `runAsUser`), on the host
  network (`:14`), with a `hostPath` write (`:42`) and `RuntimeDefault` seccomp
  (`:19`). An AppArmor profile here would be the only thing between a
  compromised busybox and `/var/log` — but a profile per *test pod* is not a
  security model.
- `examples/flannel-ds.yaml` is `privileged: true` (`:77`) and must be: it writes
  the host routing table. **The workloads that would benefit most from a profile
  are the ones that need the privilege the profile would deny**, so a profile
  there is close to worthless.
- The node's own daemons are the interesting targets ("no unconfined daemons",
  1.6.2.6). Confining containerd or kubelet means writing a profile for two of
  the most privileged userspace programs on a Linux host, and then debugging
  every image pull failure against it.

**Judgement: the value is real but small, and it is in the wrong place relative
to this node's actual holes.** The two biggest findings in
`cis-level2-hardening.md` are not MAC-shaped: the serial console is an
unauthenticated root shell (`§4.5`), and nothing verifies the image at boot
(`§4.1`). Both are cheaper to fix and both dominate a profile for `busybox`.

### 3.6 Cheaper options that buy most of the practical benefit

| Option | Cost **[verified unless marked]** | What it buys |
| --- | --- | --- |
| **Yama** | `CONFIG_SECURITY=y`, `CONFIG_SECURITY_YAMA=y`; `ptrace_scope` defaults to `1` (relational) when built in (`linux/security/yama/yama_lsm.c:28`) — **no userspace, no profiles, no loader, no audit dependency** | Blocks non-ancestor `ptrace` and `/proc/pid/mem` across the node. Non-trivial here because the CRI default seccomp profile *allows* `ptrace` (`containerd/contrib/seccomp/seccomp_default.go:509-520`). Closes none of the CIS 1.6.x items — it is not "MAC" in the benchmark's sense. |
| **Per-pod hardening** | free: four lines per manifest | `allowPrivilegeEscalation: false` (→ `no_new_privs` for real), `capabilities.drop: ["ALL"]`, `readOnlyRootFilesystem: true`, `runAsNonRoot` where the image allows. **None of these are set in `examples/` today.** This is the 80% of "MAC-like" benefit available without a policy engine: it removes the capability that makes MAC necessary. |
| **tmpfs mount options** | free: one `-o` string per mount (`cmd/uinit/main.go:126-128`; `u-root/pkg/libinit/root_linux.go:129,139`) | `nodev,nosuid,noexec` closes 1.1.3–1.1.5 and 1.1.15–1.1.17 (six controls; `/var/tmp` does not exist, so 1.1.8–1.1.10 are untouched) and removes the "write a binary into a world-writable tmpfs and run it" path that an AppArmor profile would otherwise have to deny. |
| **Landlock** | `CONFIG_SECURITY_LANDLOCK=y` (`linux/security/landlock/Kconfig:3`) | Unprivileged *self*-restriction: the Go daemons could declare what they need and drop the rest, with no loader and no admin policy. Speculative; nothing implements it here. **[inferred]** |

---

## 4. Is it a hard requirement?

**No, not from CIS.** The CIS Distribution Independent Linux Benchmark is a
voluntary configuration baseline, published by a private body, adopted — or not
— by choice. Nothing in it is legally binding, and a node that ignores all 237
controls breaks no rule. "17 non-compliant audit controls" is a gap against a
benchmark someone chose to measure against, not a finding of legal exposure.

**What would make it hard is a compliance regime or a contract, not CIS.** The
usual candidates — PCI DSS, HIPAA, SOC 2, ISO/IEC 27001 — all have logging,
monitoring and access-control expectations, and a regulated environment
typically forces *something* in this area. **I have not verified any clause text
for any of them and I deliberately do not quote from memory: treat any specific
obligation as `[unknown]` until someone reads the current standard.** The shape
they generally have is: an audit trail exists, is retained, is protected, and is
reviewed — not "auditd runs on every Kubernetes worker".

**Two distinctions that matter more than the regime name:**

1. **Cluster audit ≠ host audit.** For Kubernetes workloads, the artefact
   auditors ask for is the **apiserver audit log** — who created, changed or
   read which object. This node cannot produce it (the control plane is a
   throwaway VM in the harness and its apiserver runs with
   `--authorization-mode=AlwaysAllow` and no audit flags,
   `cmd/uinit/main.go:190-204`), and a node is not where it belongs. Kernel
   audit on the worker is a different, weaker artefact.
2. **This node holds no data at rest** (`docs/roadmap.md`, "Threat model" and
   "Strict RAM-only"). Most audit-trail obligations are about data at rest and
   access to it; on a node that re-fetches everything into RAM on every boot,
   the obligation lands on the registry, the control plane and the log store,
   not here.

**So what *would* make it hard:** a customer contract, framework certification or
internal policy that names host-level audit or a MAC framework explicitly — or a
workload class (multi-tenant, untrusted third-party images) where confining
workloads beyond capabilities is a stated requirement. Absent one of those, both
decisions are documented exceptions with the reasoning above as their
justification, and the honest score impact is the one the assessment already
states (`cis-level2-hardening.md:2289-2300`).

---

## 5. Recommendation

| Mechanism | Decision | Reason |
| --- | --- | --- |
| **auditd** | **Do not adopt.** Record 4.1.1.1–4.1.7, 4.1.9–4.1.15, 4.1.19 as documented exceptions. | 7 of the 10 rule controls are void or inert on this node (§2.2, §2.2.1); the consumer is C in a Go userland; the log dies at reboot without M2; and the backlog default drops records silently. The kernel half is cheap but buys nothing on its own. |
| **SELinux** | **Never, on this filesystem.** 1.6.2.2, 1.6.2.3 stay exceptions. | Needs a labelled filesystem; ramfs stores no xattrs; every boot re-unpacks the image (§3.3). |
| **AppArmor** | **Adopt later, low priority — not for the CIS score.** | Enforcement is already in the fork, cgo-free (§3.4), so this is the only MAC with a credible cost path. But the loader is C++, the profiles are the real work, and §3.5 says the value is small next to the console and image-verification holes. Trigger to revisit: a requirement to confine workloads beyond capabilities, or a privileged-workload review. |
| **Cheapest real gains, now** | Yama; `allowPrivilegeEscalation: false` + `capabilities.drop: [ALL]` in `examples/`; `nodev,nosuid,noexec` on the tmpfs mounts. | §3.6. Each is a line or a symbol, none needs a daemon, a loader or a policy. If any hardening work happens before M2, it should be this, plus the console. |

**Cost table.** Size impacts are **[unmeasured]**: no kernel or image was built
for this document. The baselines are `bzImage` 4,469,760 bytes and
`initramfs.cpio` 237,828,452 bytes.

| Change | Kernel (fragment lines) | Userspace | Per-boot work | Closes |
| --- | --- | --- | --- | --- |
| `CONFIG_AUDIT=y` | 1 (`AUDITSYSCALL`, `FSNOTIFY` follow automatically) | none — and it records nothing until a consumer exists | none | 4.1.4 in substance; **no records** |
| + Go netlink consumer and ~5 bespoke rules | same | a small Go program (and a rules file in the image) | re-apply rules, then `-e 2` | 4.1.19 and the 3 substantive rule controls; the 4 inert ones only if the `auid` filters are dropped |
| + log shipping off-box (M2) | none | shipper | none | makes the above survivable; 4.2.1.5 |
| **AppArmor** | 2 (`SECURITY`, `SECURITY_APPARMOR`; brings `AUDIT`, `SECURITYFS`, `SECURITY_PATH`, `SECURITY_NETWORK` by `select`) | `apparmor_parser` (C++) or patched check + embedded blob; profiles for workloads and, if 1.6.2.6 is the goal, for `containerd`/`kubelet`/`runc`/`sshd`/`uinit` | load profiles before containers start | 1.6.1.1 and 1.6.3.2 in substance; 1.6.2.6 only with daemon profiles |
| **SELinux** | `SECURITY`, `SECURITY_SELINUX` (+ `AUDIT`, `SECURITY_NETWORK`) | policy build toolchain and policy — C/autotools, plus a policy author | relabel every file — impossible on ramfs | 1.6.2.2, 1.6.2.3 — **unreachable** |
| **Yama** | 2 (`SECURITY`, `SECURITY_YAMA`) | none | none | none of 1.6.x (it is not the benchmark's MAC) |

---

## 6. What I could not verify

1. **Any size or performance impact.** No kernel and no image were built
   (`make image`, `make kernel`, `make test*` and QEMU were out of scope). Every
   `[unmeasured]` above is exactly that.
2. **`CONFIG_AUDIT` behaviour on this workload.** The backlog and drop behaviour
   is read from `linux/kernel/audit.c:132-134,417-420`, not observed.
3. **Whether AppArmor enforcement works end to end.** The code path is verified
   from `utils_linux.go:50-64` through `container_linux.go:736` to
   `standard_init_linux.go:132`; no container has run under a profile here.
4. **Whether a pre-compiled AppArmor blob can be written to securityfs without
   `apparmor_parser`.** The kernel side takes a binary blob with a versioned
   header (`policy_unpack.c:1435-1457`); producing that blob without the C++
   compiler is untested.
5. **Whether `go-libaudit` builds `CGO_ENABLED=0` against this `go.work`.** The
   module resolves (v2.6.2 on `proxy.golang.org`); the build was not attempted.
6. **SELinux's exact failure on ramfs.** That ramfs has no xattr handlers is
   verified; whether `label.SetFileLabel` returns an error or is a silent no-op
   there was not run.
7. **Whether a pod requesting `appArmorProfile: RuntimeDefault` is rejected on
   this node.** The code says it would be, loudly
   (`containerd/internal/cri/sputil/apparmor_linux.go:41-51`), and the check
   depends on `/sbin/apparmor_parser` existing
   (`containerd/pkg/apparmor/apparmor_linux.go:38`); not exercised.
8. **Regulatory clause text.** Deliberately not quoted (§4).
9. **Whether a statically linked `auditd` is practical here.** It is a
   C/autotools program **[external]**, out of model for this userland; no build
   was attempted.

---

## 7. Questions for the owner

1. **Is any compliance regime or contract actually in force for this node?**
   (PCI DSS, HIPAA, SOC 2, ISO 27001, or a customer's own control list.) If the
   answer is "no", auditd and MAC are documented exceptions and §2–§4 are their
   rationale. If it is "yes", the specific clause decides which of the two is
   negotiable. **Blocks:** the adopt/exception decision for both mechanisms, and
   whether this file is a rationale or a work order.
2. **Does M2 log shipping exist yet, and where does it send logs?** Nothing
   produced by either mechanism survives a reboot without it, and the 64-record
   audit backlog makes shipping a prerequisite rather than a nicety.
   **Blocks:** whether a narrow audit rule set is worth designing at all.
3. **Will any workload on this node be untrusted — multi-tenant, third-party
   images, or data worth stealing (M3)?** If yes, confinement beyond
   capabilities plus seccomp becomes a requirement and AppArmor's cost is
   justified. If every workload is first-party, `allowPrivilegeEscalation:
   false` plus a capability drop buys more than a profile. **Blocks:** AppArmor
   step one (profiles and loader) versus sticking with the current stack.
4. **Is the serial console staying an unauthenticated root shell?** It is the
   largest hole in the assessment (`cis-level2-hardening.md` §4.5), it defeats
   both mechanisms (root can read, stop or reboot), and it is cheaper to fix
   than either. **Blocks:** priority — until it is decided, audit and MAC are
   decoration.
5. **Should the cheap items in §3.6 be scheduled as a separate task?** Yama,
   the pod security settings in `examples/`, and the tmpfs mount options are a
   handful of lines, close six CIS controls outright, and need no decision
   beyond "yes". **Blocks:** nothing here — it is the work this analysis says is
   worth doing first.
