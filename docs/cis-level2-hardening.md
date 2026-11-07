# CIS hardening: the k4s node assessed against the Linux and Kubernetes benchmarks

**Subject:** the node image built by this repository — a `tinyconfig`-based Linux
kernel plus a u-root initramfs carrying containerd, the pure-Go runc fork,
kubelet, flannel/Cilium and `cmd/uinit`.
**Benchmarks:** two, both the benchmark of record (D1 below). The host is
assessed against the CIS Distribution Independent Linux Benchmark **v2.0.0,
2019-07-16** — the latest edition of that benchmark I could establish, and the
edition the independently maintained InSpec profile implements. The node's
Kubernetes surface is assessed against the **CIS Kubernetes Benchmark v2.0.1** —
the newest edition whose control text is obtainable, v2.1.0 being newer still —
worker-node sections only (§11).
**Scope of this document:** assessment only. No code, build file, kernel fragment
or config was changed by the work that produced it.

---

## Adopted decisions

Three decisions the owner has taken since the first edition of this assessment.
They are recorded ahead of the assessment because they fix the frame the rest of
the document is read in. **None of them changes a control's status.** A decision
that has not been implemented does not make a control pass, and the code as it
stands is what every `**Status.**` line in §5 and §11 describes.

### D1 — Benchmark of record: both benchmarks

The host is assessed against **CIS Distribution Independent Linux Benchmark
v2.0.0 (2019-07-16), Level 2 - Server** (§5, 237 controls), and the node's
Kubernetes surface against the **CIS Kubernetes Benchmark v2.0.1**, worker-node
sections only (§11, 27 controls). v2.0.1 is not the newest Kubernetes edition —
v2.1.0 is (2026-09-30) — but it is the newest one whose control text is
obtainable and the one that maps to this node's Kubernetes version (§11.1).

**Effect.** The two are enumerated, tallied and reported **separately**; there is
no combined score (D3). The DIL table and its tally are below; the Kubernetes
table and its tally are §11.3. What §11 excludes, and why, is §11.2 — including
its control plane, which is the throwaway VM of §4.8 rather than a deployed
component.

### D2 — sshd is a test instrument, not a production service

`uinit` starts sshd unconditionally (`cmd/uinit/main.go:84-85`). It listens on
`0.0.0.0:2022`, has no user model, and grants a root shell to any key in
`/etc/ssh/authorized_keys` (§4.5). The decision is that **sshd is test-only**: it
is gated behind an explicit build flag, or behind the presence of the spliced key
material, so that a production image starts no sshd at all. Gating it behind
`/etc/k4s/role` alone would not work — the harness boots the same `node` role
(`cmd/uinit/main.go:56`) — so the gate has to be something only the harness
provides, and `/etc/ssh/authorized_keys`, which only
`scripts/test-cluster.sh:448-450` splices in, is exactly that.

**Implemented? No.** The decision is recorded, the code is unchanged, and every
5.2.x status below describes today's unconditional sshd. Nothing in this
document is marked `comply` on the strength of the gate.

**Projection — not applied.** If the gate lands, the controls whose subject is
the sshd service stop having a subject in production. Projected status only; the
tally in the summary below is the current one and is unaffected:

| Control | Now | Projected | Why |
| --- | --- | --- | --- |
| 1.7.1.3 | `non-compliant` | `not applicable` | no remote login to warn |
| 5.2.7, 5.2.10, 5.2.16, 5.2.17, 5.2.18, 5.2.19, 5.2.22, 5.2.23 | `non-compliant` | `not applicable` | no sshd to configure |
| 5.2.2, 5.2.5, 5.2.13, 5.2.14, 5.2.15 | `partial` | `not applicable` | ditto |
| 5.2.4, 5.2.6, 5.2.8, 5.2.9, 5.2.11, 5.2.12, 5.2.21 | `comply` | `not applicable` | ditto |
| 5.2.1, 5.2.3, 5.2.20 | `not applicable` | no change | already void |

Projected DIL tally: 79 `comply`, 4 `partial`, 67 `non-compliant`, 80 `not
applicable`, 7 `infeasible by design` — still 237 controls, and **not** what the
tables in this document currently say. The projection does not touch the console
root shell (§4.5, question 8), which is a larger finding than any 5.2 control.

### D3 — Conformance is reported as five statuses, never one number

The five statuses of §3 — `comply`, `partial`, `non-compliant`, `not applicable`,
`infeasible by design` — **are** the report. There is no single percentage and no
headline score, for either benchmark. A percentage over a profile in which 59 of
237 controls have no subject on this system measures the distance between a
diskful systemd host and a diskless node, not the node's security posture. Where
a control is `not applicable`, the entry says why; where it is `infeasible by
design`, it names the locked decision it conflicts with.

**Effect.** §10's question 11 is answered and withdrawn. Two tallies, two
benchmarks, five statuses each: anyone quoting this assessment quotes the five
counts with the benchmark and profile they belong to.

---

## Summary: every control and its status

All 237 controls of the Level 2 - Server profile, in benchmark order. The
detailed entry for each is in §5; this table exists so the shape is visible in
one screen. `L1` items are required by the Level 2 profile because Level 2
extends Level 1. This table is the **Distribution Independent Linux** benchmark
only.

<!-- SUMMARY-TABLE-START -->
| ID | Control | Level | Status |
| --- | --- | --- | --- |
| 1.1.1.1 | Ensure mounting of cramfs filesystems is disabled | L1 | `comply` |
| 1.1.1.2 | Ensure mounting of freevxfs filesystems is disabled | L1 | `comply` |
| 1.1.1.3 | Ensure mounting of jffs2 filesystems is disabled | L1 | `comply` |
| 1.1.1.4 | Ensure mounting of hfs filesystems is disabled | L1 | `comply` |
| 1.1.1.5 | Ensure mounting of hfsplus filesystems is disabled | L1 | `comply` |
| 1.1.1.6 | Ensure mounting of squashfs filesystems is disabled | L1 | `comply` |
| 1.1.1.7 | Ensure mounting of udf filesystems is disabled | L1 | `comply` |
| 1.1.1.8 | Ensure mounting of FAT filesystems is limited | L2 | `comply` |
| 1.1.2 | Ensure /tmp is configured | L1 | `comply` |
| 1.1.3 | Ensure nodev option set on /tmp partition | L1 | `non-compliant` |
| 1.1.4 | Ensure nosuid option set on /tmp partition | L1 | `non-compliant` |
| 1.1.5 | Ensure noexec option set on /tmp partition | L1 | `non-compliant` |
| 1.1.6 | Ensure separate partition exists for /var | L2 | `infeasible by design` |
| 1.1.7 | Ensure separate partition exists for /var/tmp | L2 | `infeasible by design` |
| 1.1.8 | Ensure nodev option set on /var/tmp partition | L1 | `non-compliant` |
| 1.1.9 | Ensure nosuid option set on /var/tmp partition | L1 | `non-compliant` |
| 1.1.10 | Ensure noexec option set on /var/tmp partition | L1 | `non-compliant` |
| 1.1.11 | Ensure separate partition exists for /var/log | L2 | `infeasible by design` |
| 1.1.12 | Ensure separate partition exists for /var/log/audit | L2 | `infeasible by design` |
| 1.1.13 | Ensure separate partition exists for /home | L2 | `infeasible by design` |
| 1.1.14 | Ensure nodev option set on /home partition | L1 | `not applicable` |
| 1.1.15 | Ensure nodev option set on /dev/shm partition | L1 | `non-compliant` |
| 1.1.16 | Ensure nosuid option set on /dev/shm partition | L1 | `non-compliant` |
| 1.1.17 | Ensure noexec option set on /dev/shm partition | L1 | `non-compliant` |
| 1.1.18 | Ensure nodev option set on removable media partitions | L1 | `not applicable` |
| 1.1.19 | Ensure nosuid option set on removable media partitions | L1 | `not applicable` |
| 1.1.20 | Ensure noexec option set on removable media partitions | L1 | `not applicable` |
| 1.1.21 | Ensure sticky bit is set on all world-writable directories | L1 | `non-compliant` |
| 1.1.22 | Disable Automounting | L1 | `comply` |
| 1.1.23 | Disable USB Storage | L1 | `comply` |
| 1.2.1 | Ensure package manager repositories are configured | L1 | `not applicable` |
| 1.2.2 | Ensure GPG keys are configured | L1 | `not applicable` |
| 1.3.1 | Ensure AIDE is installed | L1 | `non-compliant` |
| 1.3.2 | Ensure filesystem integrity is regularly checked | L1 | `partial` |
| 1.4.1 | Ensure permissions on bootloader config are configured | L1 | `not applicable` |
| 1.4.2 | Ensure bootloader password is set | L1 | `not applicable` |
| 1.4.3 | Ensure authentication required for single user mode | L1 | `non-compliant` |
| 1.4.4 | Ensure interactive boot is not enabled | L1 | `not applicable` |
| 1.5.1 | Ensure core dumps are restricted | L1 | `comply` |
| 1.5.2 | Ensure XD/NX support is enabled | L1 | `comply` |
| 1.5.3 | Ensure address space layout randomization (ASLR) is enabled | L1 | `comply` |
| 1.5.4 | Ensure prelink is disabled | L1 | `comply` |
| 1.6.1.1 | Ensure SELinux or AppArmor are installed | L2 | `non-compliant` |
| 1.6.2.1 | Ensure SELinux is not disabled in bootloader configuration | L2 | `not applicable` |
| 1.6.2.2 | Ensure the SELinux state is enforcing | L2 | `non-compliant` |
| 1.6.2.3 | Ensure SELinux policy is configured | L2 | `non-compliant` |
| 1.6.2.4 | Ensure SETroubleshoot is not installed | L2 | `comply` |
| 1.6.2.5 | Ensure the MCS Translation Service (mcstrans) is not installed | L2 | `comply` |
| 1.6.2.6 | Ensure no unconfined daemons exist | L2 | `non-compliant` |
| 1.6.3.1 | Ensure AppArmor is not disabled in bootloader configuration | L2 | `not applicable` |
| 1.6.3.2 | Ensure all AppArmor Profiles are enforcing | L2 | `non-compliant` |
| 1.7.1.1 | Ensure message of the day is configured properly | L1 | `non-compliant` |
| 1.7.1.2 | Ensure local login warning banner is configured properly | L1 | `non-compliant` |
| 1.7.1.3 | Ensure remote login warning banner is configured properly | L1 | `non-compliant` |
| 1.7.1.4 | Ensure permissions on /etc/motd are configured | L1 | `not applicable` |
| 1.7.1.5 | Ensure permissions on /etc/issue are configured | L1 | `not applicable` |
| 1.7.1.6 | Ensure permissions on /etc/issue.net are configured | L1 | `not applicable` |
| 1.7.2 | Ensure GDM login banner is configured | L1 | `not applicable` |
| 1.8 | Ensure updates, patches, and additional security software are installed | L1 | `partial` |
| 2.1.1 | Ensure chargen services are not enabled | L1 | `comply` |
| 2.1.2 | Ensure daytime services are not enabled | L1 | `comply` |
| 2.1.3 | Ensure discard services are not enabled | L1 | `comply` |
| 2.1.4 | Ensure echo services are not enabled | L1 | `comply` |
| 2.1.5 | Ensure time services are not enabled | L1 | `comply` |
| 2.1.6 | Ensure rsh server is not enabled | L1 | `comply` |
| 2.1.7 | Ensure talk server is not enabled | L1 | `comply` |
| 2.1.8 | Ensure telnet server is not enabled | L1 | `comply` |
| 2.1.9 | Ensure tftp server is not enabled | L1 | `comply` |
| 2.1.10 | Ensure xinetd is not enabled | L1 | `comply` |
| 2.2.1.1 | Ensure time synchronization is in use | L1 | `non-compliant` |
| 2.2.1.2 | Ensure ntp is configured | L1 | `not applicable` |
| 2.2.1.3 | Ensure chrony is configured | L1 | `not applicable` |
| 2.2.1.4 | Ensure systemd-timesyncd is configured | L1 | `not applicable` |
| 2.2.2 | Ensure X Window System is not installed | L1 | `comply` |
| 2.2.3 | Ensure Avahi Server is not enabled | L1 | `comply` |
| 2.2.4 | Ensure CUPS is not enabled | L1 | `comply` |
| 2.2.5 | Ensure DHCP Server is not enabled | L1 | `comply` |
| 2.2.6 | Ensure LDAP server is not enabled | L1 | `comply` |
| 2.2.7 | Ensure NFS and RPC are not enabled | L1 | `comply` |
| 2.2.8 | Ensure DNS Server is not enabled | L1 | `comply` |
| 2.2.9 | Ensure FTP Server is not enabled | L1 | `comply` |
| 2.2.10 | Ensure HTTP server is not enabled | L1 | `comply` |
| 2.2.11 | Ensure IMAP and POP3 server is not enabled | L1 | `comply` |
| 2.2.12 | Ensure Samba is not enabled | L1 | `comply` |
| 2.2.13 | Ensure HTTP Proxy Server is not enabled | L1 | `comply` |
| 2.2.14 | Ensure SNMP Server is not enabled | L1 | `comply` |
| 2.2.15 | Ensure mail transfer agent is configured for local-only mode | L1 | `comply` |
| 2.2.16 | Ensure rsync service is not enabled | L1 | `comply` |
| 2.2.17 | Ensure NIS Server is not enabled | L1 | `comply` |
| 2.3.1 | Ensure NIS Client is not installed | L1 | `comply` |
| 2.3.2 | Ensure rsh client is not installed | L1 | `comply` |
| 2.3.3 | Ensure talk client is not installed | L1 | `comply` |
| 2.3.4 | Ensure telnet client is not installed | L1 | `comply` |
| 2.3.5 | Ensure LDAP client is not installed | L1 | `comply` |
| 3.1.1 | Ensure IP forwarding is disabled | L1 | `comply` |
| 3.1.2 | Ensure packet redirect sending is disabled | L1 | `non-compliant` |
| 3.2.1 | Ensure source routed packets are not accepted | L1 | `comply` |
| 3.2.2 | Ensure ICMP redirects are not accepted | L1 | `non-compliant` |
| 3.2.3 | Ensure secure ICMP redirects are not accepted | L1 | `non-compliant` |
| 3.2.4 | Ensure suspicious packets are logged | L1 | `non-compliant` |
| 3.2.5 | Ensure broadcast ICMP requests are ignored | L1 | `comply` |
| 3.2.6 | Ensure bogus ICMP responses are ignored | L1 | `comply` |
| 3.2.7 | Ensure Reverse Path Filtering is enabled | L1 | `non-compliant` |
| 3.2.8 | Ensure TCP SYN Cookies is enabled | L1 | `non-compliant` |
| 3.2.9 | Ensure IPv6 router advertisements are not accepted | L1 | `non-compliant` |
| 3.3.1 | Ensure TCP Wrappers is installed | L1 | `not applicable` |
| 3.3.2 | Ensure /etc/hosts.allow is configured | L1 | `not applicable` |
| 3.3.3 | Ensure /etc/hosts.deny is configured | L1 | `not applicable` |
| 3.3.4 | Ensure permissions on /etc/hosts.allow are configured | L1 | `not applicable` |
| 3.3.5 | Ensure permissions on /etc/hosts.deny are configured | L1 | `not applicable` |
| 3.4.1 | Ensure DCCP is disabled | L2 | `comply` |
| 3.4.2 | Ensure SCTP is disabled | L2 | `comply` |
| 3.4.3 | Ensure RDS is disabled | L2 | `comply` |
| 3.4.4 | Ensure TIPC is disabled | L2 | `comply` |
| 3.5.1.1 | Ensure IPv6 default deny firewall policy | L1 | `non-compliant` |
| 3.5.1.2 | Ensure IPv6 loopback traffic is configured | L1 | `non-compliant` |
| 3.5.1.3 | Ensure IPv6 outbound and established connections are configured | L1 | `non-compliant` |
| 3.5.1.4 | Ensure IPv6 firewall rules exist for all open ports | L1 | `non-compliant` |
| 3.5.2.1 | Ensure default deny firewall policy | L1 | `non-compliant` |
| 3.5.2.2 | Ensure loopback traffic is configured | L1 | `non-compliant` |
| 3.5.2.3 | Ensure outbound and established connections are configured | L1 | `non-compliant` |
| 3.5.2.4 | Ensure firewall rules exist for all open ports | L1 | `non-compliant` |
| 3.5.3 | Ensure iptables is installed | L1 | `non-compliant` |
| 3.6 | Ensure wireless interfaces are disabled | L1 | `comply` |
| 3.7 | Disable IPv6 | L2 | `non-compliant` |
| 4.1.1.1 | Ensure audit log storage size is configured | L2 | `non-compliant` |
| 4.1.1.2 | Ensure system is disabled when audit logs are full | L2 | `non-compliant` |
| 4.1.1.3 | Ensure audit logs are not automatically deleted | L2 | `non-compliant` |
| 4.1.2 | Ensure auditd is installed | L2 | `non-compliant` |
| 4.1.3 | Ensure auditd service is enabled | L2 | `non-compliant` |
| 4.1.4 | Ensure auditing for processes that start prior to auditd is enabled | L2 | `non-compliant` |
| 4.1.5 | Ensure events that modify date and time information are collected | L2 | `non-compliant` |
| 4.1.6 | Ensure events that modify user/group information are collected | L2 | `non-compliant` |
| 4.1.7 | Ensure events that modify the system's network environment are collected | L2 | `non-compliant` |
| 4.1.8 | Ensure events that modify the system's Mandatory Access Controls are collected | L2 | `not applicable` |
| 4.1.9 | Ensure login and logout events are collected | L2 | `non-compliant` |
| 4.1.10 | Ensure session initiation information is collected | L2 | `non-compliant` |
| 4.1.11 | Ensure discretionary access control permission modification events are collected | L2 | `non-compliant` |
| 4.1.12 | Ensure unsuccessful unauthorized file access attempts are collected | L2 | `non-compliant` |
| 4.1.13 | Ensure use of privileged commands is collected | L2 | `non-compliant` |
| 4.1.14 | Ensure successful file system mounts are collected | L2 | `non-compliant` |
| 4.1.15 | Ensure file deletion events by users are collected | L2 | `non-compliant` |
| 4.1.16 | Ensure changes to system administration scope (sudoers) is collected | L2 | `not applicable` |
| 4.1.17 | Ensure system administrator actions (sudolog) are collected | L2 | `not applicable` |
| 4.1.18 | Ensure kernel module loading and unloading is collected | L2 | `not applicable` |
| 4.1.19 | Ensure the audit configuration is immutable | L2 | `non-compliant` |
| 4.2.1.1 | Ensure rsyslog is installed | L1 | `non-compliant` |
| 4.2.1.2 | Ensure rsyslog Service is enabled | L1 | `non-compliant` |
| 4.2.1.3 | Ensure logging is configured | L1 | `partial` |
| 4.2.1.4 | Ensure rsyslog default file permissions configured | L1 | `not applicable` |
| 4.2.1.5 | Ensure rsyslog is configured to send logs to a remote log host | L1 | `non-compliant` |
| 4.2.1.6 | Ensure remote rsyslog messages are only accepted on designated log hosts. | L1 | `not applicable` |
| 4.2.2.1 | Ensure journald is configured to send logs to rsyslog | L1 | `not applicable` |
| 4.2.2.2 | Ensure journald is configured to compress large log files | L1 | `not applicable` |
| 4.2.2.3 | Ensure journald is configured to write logfiles to persistent disk | L1 | `infeasible by design` |
| 4.2.3 | Ensure permissions on all logfiles are configured | L1 | `non-compliant` |
| 4.3 | Ensure logrotate is configured | L1 | `not applicable` |
| 5.1.1 | Ensure cron daemon is enabled | L1 | `not applicable` |
| 5.1.2 | Ensure permissions on /etc/crontab are configured | L1 | `not applicable` |
| 5.1.3 | Ensure permissions on /etc/cron.hourly are configured | L1 | `not applicable` |
| 5.1.4 | Ensure permissions on /etc/cron.daily are configured | L1 | `not applicable` |
| 5.1.5 | Ensure permissions on /etc/cron.weekly are configured | L1 | `not applicable` |
| 5.1.6 | Ensure permissions on /etc/cron.monthly are configured | L1 | `not applicable` |
| 5.1.7 | Ensure permissions on /etc/cron.d are configured | L1 | `not applicable` |
| 5.1.8 | Ensure at/cron is restricted to authorized users | L1 | `not applicable` |
| 5.2.1 | Ensure permissions on /etc/ssh/sshd_config are configured | L1 | `not applicable` |
| 5.2.2 | Ensure permissions on SSH private host key files are configured | L1 | `partial` |
| 5.2.3 | Ensure permissions on SSH public host key files are configured | L1 | `not applicable` |
| 5.2.4 | Ensure SSH Protocol is set to 2 | L1 | `comply` |
| 5.2.5 | Ensure SSH LogLevel is appropriate | L1 | `partial` |
| 5.2.6 | Ensure SSH X11 forwarding is disabled | L2 | `comply` |
| 5.2.7 | Ensure SSH MaxAuthTries is set to 4 or less | L1 | `non-compliant` |
| 5.2.8 | Ensure SSH IgnoreRhosts is enabled | L1 | `comply` |
| 5.2.9 | Ensure SSH HostbasedAuthentication is disabled | L1 | `comply` |
| 5.2.10 | Ensure SSH root login is disabled | L1 | `non-compliant` |
| 5.2.11 | Ensure SSH PermitEmptyPasswords is disabled | L1 | `comply` |
| 5.2.12 | Ensure SSH PermitUserEnvironment is disabled | L1 | `comply` |
| 5.2.13 | Ensure only strong Ciphers are used | L1 | `partial` |
| 5.2.14 | Ensure only strong MAC algorithms are used | L1 | `partial` |
| 5.2.15 | Ensure only strong Key Exchange algorithms are used | L1 | `partial` |
| 5.2.16 | Ensure SSH Idle Timeout Interval is configured | L1 | `non-compliant` |
| 5.2.17 | Ensure SSH LoginGraceTime is set to one minute or less | L1 | `non-compliant` |
| 5.2.18 | Ensure SSH access is limited | L1 | `non-compliant` |
| 5.2.19 | Ensure SSH warning banner is configured | L1 | `non-compliant` |
| 5.2.20 | Ensure SSH PAM is enabled | L1 | `not applicable` |
| 5.2.21 | Ensure SSH AllowTcpForwarding is disabled | L2 | `comply` |
| 5.2.22 | Ensure SSH MaxStartups is configured | L1 | `non-compliant` |
| 5.2.23 | Ensure SSH MaxSessions is set to 4 or less | L1 | `non-compliant` |
| 5.3.1 | Ensure password creation requirements are configured | L1 | `not applicable` |
| 5.3.2 | Ensure lockout for failed password attempts is configured | L1 | `not applicable` |
| 5.3.3 | Ensure password reuse is limited | L1 | `not applicable` |
| 5.3.4 | Ensure password hashing algorithm is SHA-512 | L1 | `not applicable` |
| 5.4.1.1 | Ensure password expiration is 365 days or less | L1 | `not applicable` |
| 5.4.1.2 | Ensure minimum days between password changes is 7 or more | L1 | `not applicable` |
| 5.4.1.3 | Ensure password expiration warning days is 7 or more | L1 | `not applicable` |
| 5.4.1.4 | Ensure inactive password lock is 30 days or less | L1 | `not applicable` |
| 5.4.1.5 | Ensure all users last password change date is in the past | L1 | `not applicable` |
| 5.4.2 | Ensure system accounts are secured | L1 | `comply` |
| 5.4.3 | Ensure default group for the root account is GID 0 | L1 | `comply` |
| 5.4.4 | Ensure default user umask is 027 or more restrictive | L1 | `non-compliant` |
| 5.4.5 | Ensure default user shell timeout is 900 seconds or less | L2 | `non-compliant` |
| 5.5 | Ensure root login is restricted to system console | L1 | `non-compliant` |
| 5.6 | Ensure access to the su command is restricted | L1 | `comply` |
| 6.1.1 | Audit system file permissions | L2 | `infeasible by design` |
| 6.1.2 | Ensure permissions on /etc/passwd are configured | L1 | `non-compliant` |
| 6.1.3 | Ensure permissions on /etc/shadow are configured | L1 | `not applicable` |
| 6.1.4 | Ensure permissions on /etc/group are configured | L1 | `non-compliant` |
| 6.1.5 | Ensure permissions on /etc/gshadow are configured | L1 | `not applicable` |
| 6.1.6 | Ensure permissions on /etc/passwd- are configured | L1 | `not applicable` |
| 6.1.7 | Ensure permissions on /etc/shadow- are configured | L1 | `not applicable` |
| 6.1.8 | Ensure permissions on /etc/group- are configured | L1 | `not applicable` |
| 6.1.9 | Ensure permissions on /etc/gshadow- are configured | L1 | `not applicable` |
| 6.1.10 | Ensure no world writable files exist | L1 | `partial` |
| 6.1.11 | Ensure no unowned files or directories exist | L1 | `comply` |
| 6.1.12 | Ensure no ungrouped files or directories exist | L1 | `comply` |
| 6.1.13 | Audit SUID executables | L1 | `comply` |
| 6.1.14 | Audit SGID executables | L1 | `comply` |
| 6.2.1 | Ensure password fields are not empty | L1 | `comply` |
| 6.2.2 | Ensure no legacy "+" entries exist in /etc/passwd | L1 | `comply` |
| 6.2.3 | Ensure no legacy "+" entries exist in /etc/shadow | L1 | `comply` |
| 6.2.4 | Ensure no legacy "+" entries exist in /etc/group | L1 | `comply` |
| 6.2.5 | Ensure root is the only UID 0 account | L1 | `comply` |
| 6.2.6 | Ensure root PATH Integrity | L1 | `non-compliant` |
| 6.2.7 | Ensure all users' home directories exist | L1 | `non-compliant` |
| 6.2.8 | Ensure users' home directories permissions are 750 or more restrictive | L1 | `non-compliant` |
| 6.2.9 | Ensure users own their home directories | L1 | `non-compliant` |
| 6.2.10 | Ensure users' dot files are not group or world writable | L1 | `not applicable` |
| 6.2.11 | Ensure no users have .forward files | L1 | `comply` |
| 6.2.12 | Ensure no users have .netrc files | L1 | `comply` |
| 6.2.13 | Ensure users' .netrc Files are not group or world accessible | L1 | `comply` |
| 6.2.14 | Ensure no users have .rhosts files | L1 | `comply` |
| 6.2.15 | Ensure all groups in /etc/passwd exist in /etc/group | L1 | `comply` |
| 6.2.16 | Ensure no duplicate UIDs exist | L1 | `comply` |
| 6.2.17 | Ensure no duplicate GIDs exist | L1 | `comply` |
| 6.2.18 | Ensure no duplicate user names exist | L1 | `comply` |
| 6.2.19 | Ensure no duplicate group names exist | L1 | `comply` |
| 6.2.20 | Ensure shadow group is empty | L1 | `comply` |

**237 controls, all in the Level 2 - Server profile** (192 Level 1 items and 45 Level 2 items).

| Status | Count |
| --- | --- |
| `comply` | 86 |
| `partial` | 9 |
| `non-compliant` | 76 |
| `not applicable` | 59 |
| `infeasible by design` | 7 |
| **total** | **237** |
<!-- SUMMARY-TABLE-END -->

The second benchmark's table and separate tally — 27 controls, never added to
this one — are in §11.3.

---

## 1. Why this document exists, and what it is not

The CIS Distribution Independent Linux benchmark is written for a *diskful,
package-managed, systemd-managed Linux host*. This node is none of those:

- there is no disk and no persistent state — the image is the node;
- there is no package manager, no `/etc` package database and no patch level;
- there is no systemd, no PAM, no auditd, no syslog daemon, no cron, no LSM;
- the only interactive access paths are the serial console (an unauthenticated
  root shell) and a Go SSH server that exists for the test harness;
- there is no control plane in the node — the apiserver/etcd the tests use is a
  throwaway VM in the harness, and is out of scope here.

A mechanical mapping of the 237 controls would therefore produce a page of
"non-compliant" that says nothing. This document instead does three things for
every control: states what the control actually asks for, states whether the
*mechanism* or the *property* is present, and prices the gap. Some controls are
satisfied more strongly than on a diskful host (unused filesystems not compiled
in at all); some are void (separate partitions on a machine with no disk); some
are real gaps that are cheap to close (sysctls, mount options, file modes); and
some are expensive but possible (auditd, an LSM).

**It is not a compliance certificate.** Where the answer could not be determined
without booting the image or making a scope decision, the entry says so and the
decision is listed in §10.

## 2. How the benchmark was enumerated

The full control inventory — 237 controls — was extracted from the benchmark
PDF's own body text and reconciled against its summary table and against
`dev-sec/cis-dil-benchmark` (an Apache-2.0 InSpec profile implementing the same
edition). The three agree: 237 controls, 192 Level 1 - Server and 45 Level 2 -
Server items.

**Every one of the 237 controls is in the Level 2 - Server profile**, because
Level 2 extends Level 1. The 45 `L2` items below are the ones the benchmark marks
Level 2 only; the 192 `L1` items are still required by a Level 2 assessment and
are assessed with the same rigour. Workstation-only applicability is out of
scope; exactly two controls are server-only (1.6.2.4 and 2.2.2) and are assessed
like any other.

Provenance, licences, hashes and what could not be obtained (the official CIS
PDFs are behind an interactive gate; the copy used is a third-party mirror,
labelled as such) are in `cis/SOURCES.md`. The derived inventory is
`cis/dil-2.0.0-controls.tsv`. Control identifiers, titles and levels are recorded
there from the benchmark; the benchmark's body text is not reproduced.

**What was verified, and how.** Evidence in this document comes from: the
resolved kernel config (`build/kernel/.config`, produced by `make kernel` from the
two fragments); the fragments themselves; the built `initramfs.cpio` (its file
list and modes, read with `cpio -itv`, not inferred from the build script); the
source in this repository; and the u-root checkout in this tree (`u-root/`, reused by `DIT` as it stands)
for the behaviour of init and sshd. Anything not verified that way is labelled
**(inferred)** — chiefly kernel *defaults* that only a boot could confirm. §11's
Kubernetes controls are evidenced the same way, plus the pinned `kubernetes/`
checkout for the kubelet defaults they turn on; §11.1 describes how the
Kubernetes edition was established and where its enumerating text came from.

## 3. Status values

Exactly one per control:

| Status | Meaning |
| --- | --- |
| `comply` | The control's property holds, with a file/symbol/command as evidence. |
| `partial` | The property holds in part, or holds by a different mechanism than the control names, or the control's mechanism exists but is incomplete. |
| `non-compliant` | The property does not hold and nothing equivalent does. |
| `not applicable` | The control's subject does not exist on this system (no systemd, no PAM, no bootloader, no removable media) and creating it would be wrong or meaningless. An auditor running the benchmark's literal audit would still score it as a failure; that distinction is stated where it matters. |
| `infeasible by design` | The control's goal conflicts with a locked decision (strict RAM-only, no package manager, no persistent state). |

`Cost` is one of **trivial** (a line in an existing file), **cheap** (a small,
local change), **moderate** (a new component or a change to a cloned dependency),
**large** (a new subsystem, kernel option set plus userspace), or **conflicts
with the design** (cannot be had without giving up strict RAM-only or
immutability).

---

## 4. The structural mismatches, before the control-by-control assessment

These are the findings that matter more than any individual control, because they
explain whole families of entries below.

### 4.1 The image is the integrity statement, and nothing verifies it

`DIT` assembles one cpio. Every file in it is a build output of a branch that
`DIT` printed the revision of (`DIT:97` and `DIT:116-118`). There is no `dpkg`/`rpm`
database, so a "verify installed files" control has no baseline to check
against — but the whole image hash is a *stronger* baseline than a package DB,
if it is checked. It is not: the roadmap lists "iPXE HTTPS trust model and image
signature verification" as an open risk, and there is no boot-time hash or
signature check in `cmd/uinit`. So the controls that ask for file-integrity
monitoring land on `partial`/`infeasible by design`, and the compensating
control that *would* make them moot does not exist yet.

### 4.2 No systemd means service controls land on `uinit`, and `uinit` starts four things

`cmd/uinit/main.go` is the entire service manager: network via `dhclient`, sshd,
containerd, kubelet — plus, for the control-plane role, etcd and the three
Kubernetes control-plane binaries. There are no unit files, no service accounts,
no `ProtectSystem=`-style hardening, and no dependency ordering beyond
`waitFor` polls. The benchmark's "ensure service X is not enabled" items are
therefore satisfied *by omission* (the service is not in the image) rather than by
disabling it, which is the stronger form. The items that ask for a service to be
*enabled and hardened* (auditd, rsyslog, cron) have no landing place at all.

### 4.3 No auditd, and the kernel cannot grow one without a decision

`CONFIG_AUDIT` is **not set** in the resolved config (`build/kernel/.config`).
`CONFIG_AUDITSYSCALL` does not exist without it. That makes the audit family
(4.1.x, 21 controls) turn on a concrete, costed prerequisite rather than an
opinion (four of the 21 are `not applicable` for their object: no MAC, no sudo,
no modules): turn on `CONFIG_AUDIT`/`CONFIG_AUDITSYSCALL`, then add a userspace
audit daemon — which is C, not Go, and is not in the image or the u-root applet
set. There is also no
persistent `/var/log/audit` to write to, by design. Whether auditd is a hard
requirement for this node, and what it would buy, is the subject of
`cis-audit-and-mac.md`; the entries below point at it rather than guess.

### 4.4 No LSM at all — but confinement is not absent

`CONFIG_SECURITY` is **not set**. That is stronger than "SELinux is disabled": no
LSM framework, so no SELinux, no AppArmor, no Yama, no Landlock, no LoadPin. The
L2 MAC family (1.6.x) is therefore non-compliant at the framework level.

What the node *does* have is real, and the assessment must not conflate the two:

- **seccomp**: `CONFIG_SECCOMP=y`, `CONFIG_SECCOMP_FILTER=y`
  (`configs/k4s-tiny.config:89-90`), and kubelet's `seccompDefault: true`
  (`configs/node/kubelet.yaml:15`) means pods get `RuntimeDefault`. The runc fork
  compiles the profile to BPF in Go, and the cluster test asserts the container
  reports `Seccomp: 2`.
- **namespaces and cgroups**: `CONFIG_NAMESPACES`, the per-namespace symbols and
  the cgroup v2 controllers in `configs/k4s-tiny.config:67-86`.
- **no MAC**: nothing constrains what a root process may do beyond seccomp and
  namespaces. Every process is unconfined.

Which LSM, if any, is worth adopting here, and what it would buy over seccomp plus
namespaces, is analysed in `cis-audit-and-mac.md`; the 1.6.x entries point at it
rather than repeat it.

### 4.5 There is no authentication path, and the console is a root shell

`configs/node/passwd` has two entries, both with `x` in the password field, and
there is **no `/etc/shadow`** in the image. There is no PAM, no `login`, no
`getty`, no `su`, no `sudo`. So the password, account-aging and PAM controls
(5.3.x, 5.4.1.x, 5.6, 5.2.20) are `not applicable` — not because the node is
hardened, but because there is no local authentication to configure.

That is not the same as "no access". Two paths exist:

1. **The serial console.** u-root's init runs, in order, `/bbin/uinit` and then
   `/bin/defaultsh` and `/bin/sh` (`u-root/cmds/core/init/init.go:11-12`,
   `u-root/pkg/libinit/proc_linux.go:93`). When `uinit` returns, PID 1 starts an
   interactive **root shell with no authentication** on `console=ttyS0,115200`.
   The QEMU cmdline in `Makefile:45` is the test's; production iPXE would carry a
   console too. This is a bigger finding than any single banner control.
2. **sshd.** `uinit` always starts it (`cmd/uinit/main.go:84-85`) with
   `-keys /etc/ssh/authorized_keys -privatekey /etc/ssh/host_rsa`. The base image
   contains neither file; `scripts/test-cluster.sh:181-191` generates a throwaway
   RSA key pair and `:448-450` splices them in. u-root's sshd authenticates a
   **public key, not a user** (`u-root/cmds/core/sshd/sshd.go:267-280`), ignores
   the requested username, and runs `/bin/sh` as root (`u-root/cmds/core/sshd/const_unix.go:9`). It
   listens on `0.0.0.0:2022` unless told otherwise. In production the key files
   are absent, so sshd exits at startup — but the service is on the production
   bring-up path, and the test path grants root to anyone holding the key.

### 4.6 No disk, so "separate partition" controls are void and mount options are not

Every filesystem is initramfs/ramfs or tmpfs. `1.1.6`, `1.1.7`, `1.1.11`,
`1.1.12`, `1.1.13` (separate partitions for `/var`, `/var/tmp`, `/var/log`,
`/var/log/audit`, `/home`) cannot be satisfied and must not be: strict RAM-only is
a locked decision (`docs/roadmap.md`, "Decisions (locked)"). `/home` and
`/var/tmp` do not exist at all.

But the *mount-option* controls are a different matter, and they are the single
best value in this document. u-root mounts tmpfs on `/tmp` and `/dev/shm` with no
options (`u-root/pkg/libinit/root_linux.go:129,144`), and `uinit` mounts tmpfs on
`/var/lib/containerd`, `/var/lib/kubelet` and `/var/log/pods` the same way
(`cmd/uinit/main.go:126-128`). `nodev,nosuid,noexec` are one `-o` string each.

### 4.7 The sysctl family is the cheapest real hardening available

There is **no sysctl configuration anywhere** in this repository or image: no
`/etc/sysctl.d`, no `/etc/sysctl.conf`, no writes to `/proc/sys`. Every network
control in §3.1–3.2 therefore runs on the kernel's compiled defaults. Several of
those defaults are insecure and are a few lines from being fixed:

| sysctl | kernel default | evidence |
| --- | --- | --- |
| `net.ipv4.conf.all.send_redirects` | 1 | `linux/net/ipv4/devinet.c:74` |
| `net.ipv4.conf.all.accept_redirects` | 1 | `linux/net/ipv4/devinet.c:73` |
| `net.ipv4.conf.all.secure_redirects` | 1 | `linux/net/ipv4/devinet.c:75` |
| `net.ipv4.conf.all.log_martians` | 0 | `linux/net/ipv4/devinet.c` devconf defaults |
| `net.ipv4.conf.all.rp_filter` | 0 | `linux/net/ipv4/devinet.c` devconf defaults |
| `net.ipv6.conf.all.accept_ra` | 1 | `linux/net/ipv6/addrconf.c:185,250` |
| `net.ipv4.tcp_syncookies` | **absent** | `CONFIG_SYN_COOKIES` not set |

`uinit` already has the right helper: `write(path, content)` at
`cmd/uinit/main.go:335`. Seven controls close with one loop over
`/proc/sys/net/...`; an eighth needs one kernel-fragment line.

### 4.8 The control plane is out of scope

The benchmark's control-plane-adjacent items (anything about a service exposing
the apiserver, etcd's data directory, kubelet's kubeconfig) are not host CIS
controls, and the apiserver/etcd in this project live in a **throwaway VM** in
`scripts/test-cluster.sh`, started by `cmd/uinit`'s `control-plane` role with
`--authorization-mode=AlwaysAllow` (`cmd/uinit/main.go:203`). That VM is a test
fixture, not a deployed component; nothing in this document assesses it. The
Kubernetes-specific benchmark that would assess a node is §11 of this document,
and it assesses the node only.

---

## 5. Requirement-by-requirement assessment

Order is the benchmark's own. Each entry gives what the control requires, the
status, the evidence, and what closing it would take. `L1` items are part of the
Level 2 profile; `L2` marks the Level 2-only additions. The audit (4.1.x) and MAC
(1.6.x) entries carry a fifth line pointing at `cis-audit-and-mac.md`, which
analyses what auditd and an LSM would actually buy and whether either is a hard
requirement; those entries do not duplicate it.

### 1 Initial Setup

#### 1.1.1.1 Ensure mounting of cramfs filesystems is disabled — `L1`, scored

**Requires.** The audit checks `modprobe -n -v cramfs` reports `install /bin/true` and that the module is not loaded; remediation is a `modprobe.d` blacklist.
**Status.** `comply` — by construction, and more strongly than the control asks.
**Evidence (verified).** `CONFIG_CRAMFS` is absent from `build/kernel/.config`, so cramfs support does not exist to mount. `CONFIG_MODULES` is also not set, so `modprobe` cannot succeed: the benchmark's audit command cannot even be run here.
**Cost.** none. The control's *audit procedure* is unsatisfiable (no modprobe); its *property* is absolute.

#### 1.1.1.2 Ensure mounting of freevxfs filesystems is disabled — `L1`, scored

**Requires.** Same shape: blacklist the `freevxfs` module and do not load it.
**Status.** `comply`.
**Evidence (verified).** `CONFIG_FREEVXFS` absent from the resolved config; no module loading (`CONFIG_MODULES` unset).
**Cost.** none.

#### 1.1.1.3 Ensure mounting of jffs2 filesystems is disabled — `L1`, scored

**Requires.** Blacklist `jffs2`, ensure it is not loaded.
**Status.** `comply`.
**Evidence (verified).** `CONFIG_JFFS2_FS` absent from the resolved config.
**Cost.** none.

#### 1.1.1.4 Ensure mounting of hfs filesystems is disabled — `L1`, scored

**Requires.** Blacklist `hfs`, ensure it is not loaded.
**Status.** `comply`.
**Evidence (verified).** `CONFIG_HFS_FS` absent from the resolved config.
**Cost.** none.

#### 1.1.1.5 Ensure mounting of hfsplus filesystems is disabled — `L1`, scored

**Requires.** Blacklist `hfsplus`, ensure it is not loaded.
**Status.** `comply`.
**Evidence (verified).** `CONFIG_HFSPLUS_FS` absent from the resolved config.
**Cost.** none.

#### 1.1.1.6 Ensure mounting of squashfs filesystems is disabled — `L1`, scored

**Requires.** Blacklist `squashfs`, ensure it is not loaded.
**Status.** `comply`.
**Evidence (verified).** `CONFIG_SQUASHFS` absent from the resolved config. Note this is also why the image cannot be a squashfs: the initramfs is a plain cpio.
**Cost.** none.

#### 1.1.1.7 Ensure mounting of udf filesystems is disabled — `L1`, scored

**Requires.** Blacklist `udf`, ensure it is not loaded.
**Status.** `comply`.
**Evidence (verified).** `# CONFIG_UDF_FS is not set` in the resolved config.
**Cost.** none.

#### 1.1.1.8 Ensure mounting of FAT filesystems is limited — `L2`, not scored

**Requires.** FAT support should be absent, or if present, explicitly limited to the mount points that need it.
**Status.** `comply` — there is no FAT support at all.
**Evidence (verified).** `CONFIG_FAT_FS` absent, `# CONFIG_VFAT_FS is not set`, `# CONFIG_MSDOS_FS is not set`; no block-device drivers either (`CONFIG_ATA`, `CONFIG_SCSI`, `CONFIG_USB` unset), so there is no medium to mount.
**Cost.** none.

#### 1.1.2 Ensure /tmp is configured — `L1`, scored

**Requires.** `/tmp` is a separate, configured filesystem (the audit checks `fstab`/`systemd`/mount).
**Status.** `comply` — `/tmp` is its own tmpfs mount, created by u-root's init.
**Evidence (verified).** `u-root/pkg/libinit/root_linux.go:117` creates `/tmp` (0777) and `:129` mounts `tmpfs` on it; the mount exists before `uinit` runs. The tmpfs root is `0777|S_ISVTX` by kernel default (`linux/mm/shmem.c:5264`), so `/tmp` is sticky.
**Cost.** none.

#### 1.1.3 Ensure nodev option set on /tmp partition — `L1`, scored

**Requires.** `/tmp` mounted with `nodev`.
**Status.** `non-compliant`.
**Evidence (verified).** `u-root/pkg/libinit/root_linux.go:129` mounts `tmpfs` on `/tmp` with `Opts` empty — no `nodev`, `nosuid` or `noexec`.
**Cost.** trivial — one `mount -o remount,nodev,nosuid,noexec /tmp` in `cmd/uinit/main.go`'s `node()`.

#### 1.1.4 Ensure nosuid option set on /tmp partition — `L1`, scored

**Requires.** `/tmp` mounted with `nosuid`.
**Status.** `non-compliant`.
**Evidence (verified).** Same mount, same absence of options (root_linux.go:129).
**Cost.** trivial — same remount as 1.1.3.

#### 1.1.5 Ensure noexec option set on /tmp partition — `L1`, scored

**Requires.** `/tmp` mounted with `noexec`.
**Status.** `non-compliant`.
**Evidence (verified).** Same mount, same absence of options (root_linux.go:129).
**Cost.** trivial, with one caveat worth stating: `noexec` on `/tmp` would break any workload that unpacks and runs a binary from `/tmp`. Nothing in the image or the test examples does, but a GPU node's setup scripts might; that is a policy question for the owner, not a technical obstacle.

#### 1.1.6 Ensure separate partition exists for /var — `L2`, scored

**Requires.** `/var` on its own partition.
**Status.** `infeasible by design`.
**Evidence (verified).** There are no partitions, no block device and no disk: `CONFIG_ATA`, `CONFIG_SCSI` and `CONFIG_VIRTIO_BLK` exist only as the QEMU test device and nothing is mounted from it. `/var` is a directory on the initramfs root. Strict RAM-only is a locked decision (`docs/roadmap.md`, "Decisions (locked)").
**Cost.** **conflicts with the design.** A partition requires a disk. The RAM-native equivalent — tmpfs with a size limit — is possible, and is what `/var/lib/containerd`, `/var/lib/kubelet` and `/var/log/pods` already do (`cmd/uinit/main.go:126-128`).

#### 1.1.7 Ensure separate partition exists for /var/tmp — `L2`, scored

**Requires.** `/var/tmp` on its own partition.
**Status.** `infeasible by design`.
**Evidence (verified).** `/var/tmp` does not exist in the image at all (the cpio contains `var/lock` and `var/log` only), and there is no disk to put a partition on.
**Cost.** **conflicts with the design**, as 1.1.6. A tmpfs `/var/tmp` would satisfy 1.1.8–1.1.10 but not the word "partition".

#### 1.1.8 Ensure nodev option set on /var/tmp partition — `L1`, scored

**Requires.** `nodev` on `/var/tmp`.
**Status.** `non-compliant` — there is no `/var/tmp` mount to carry the option.
**Evidence (verified).** `/var/tmp` absent from the image (cpio listing); no mount in `cmd/uinit/main.go`.
**Cost.** cheap — create `/var/tmp` and mount tmpfs with `nodev,nosuid,noexec`. The mount is trivial; only the "partition" framing is impossible.

#### 1.1.9 Ensure nosuid option set on /var/tmp partition — `L1`, scored

**Requires.** `nosuid` on `/var/tmp`.
**Status.** `non-compliant`.
**Evidence (verified).** No `/var/tmp` mount exists.
**Cost.** cheap, as 1.1.8.

#### 1.1.10 Ensure noexec option set on /var/tmp partition — `L1`, scored

**Requires.** `noexec` on `/var/tmp`.
**Status.** `non-compliant`.
**Evidence (verified).** No `/var/tmp` mount exists.
**Cost.** cheap, as 1.1.8.

#### 1.1.11 Ensure separate partition exists for /var/log — `L2`, scored

**Requires.** `/var/log` on its own partition.
**Status.** `infeasible by design`.
**Evidence (verified).** `/var/log` is a 0777 directory on the initramfs root (`u-root/pkg/libinit/root_linux.go:122`); pod logs get a tmpfs at `/var/log/pods` (`cmd/uinit/main.go:128`). Nothing survives a reboot, by design — the roadmap's M2 is log *shipping*, not log *storage*.
**Cost.** **conflicts with the design.** A tmpfs mount on `/var/log` with `nodev,nosuid,noexec` is the RAM-native improvement and is cheap; a partition is not.

#### 1.1.12 Ensure separate partition exists for /var/log/audit — `L2`, scored

**Requires.** `/var/log/audit` on its own partition.
**Status.** `infeasible by design` — for two independent reasons.
**Evidence (verified).** No `/var/log/audit` exists; `CONFIG_AUDIT` is not set, so there is no audit record stream to store; and there is no disk.
**Cost.** **conflicts with the design**, and is downstream of the auditd decision (4.1.x).

#### 1.1.13 Ensure separate partition exists for /home — `L2`, scored

**Requires.** `/home` on its own partition.
**Status.** `infeasible by design`.
**Evidence (verified).** `/home` does not exist; the image has two accounts, root and `nobody`, with `/root` and `/nonexistent` (also absent) as homes (`configs/node/passwd:1-2`).
**Cost.** **conflicts with the design.** There are no users and no home data to isolate.

#### 1.1.14 Ensure nodev option set on /home partition — `L1`, scored

**Requires.** `nodev` on `/home`.
**Status.** `not applicable`.
**Evidence (verified).** No `/home` directory and no `/home` mount exist.
**Cost.** none. Creating `/home` to set an option on it would be compliance theatre.

#### 1.1.15 Ensure nodev option set on /dev/shm partition — `L1`, scored

**Requires.** `nodev` on `/dev/shm`.
**Status.** `non-compliant`.
**Evidence (verified).** `u-root/pkg/libinit/root_linux.go:143-144` creates `/dev/shm` 0777 and mounts tmpfs with no options.
**Cost.** trivial — add the option to the remount in `uinit` (the mount is created before `uinit` runs).

#### 1.1.16 Ensure nosuid option set on /dev/shm partition — `L1`, scored

**Requires.** `nosuid` on `/dev/shm`.
**Status.** `non-compliant`.
**Evidence (verified).** Same mount, no options (root_linux.go:144).
**Cost.** trivial.

#### 1.1.17 Ensure noexec option set on /dev/shm partition — `L1`, scored

**Requires.** `noexec` on `/dev/shm`.
**Status.** `non-compliant`.
**Evidence (verified).** Same mount, no options (root_linux.go:144).
**Cost.** trivial. Note: each pod sandbox gets its own `/dev/shm` from containerd; this is the host-side mount only.

#### 1.1.18 Ensure nodev option set on removable media partitions — `L1`, not scored

**Requires.** `nodev` on any removable-media mount.
**Status.** `not applicable`.
**Evidence (verified).** There are no removable media and no drivers for any: `CONFIG_USB` absent, `CONFIG_SCSI` and `CONFIG_ATA` unset. The only block device is the QEMU virtio disk, and nothing mounts it.
**Cost.** none.

#### 1.1.19 Ensure nosuid option set on removable media partitions — `L1`, not scored

**Requires.** `nosuid` on removable media.
**Status.** `not applicable`.
**Evidence (verified).** As 1.1.18.
**Cost.** none.

#### 1.1.20 Ensure noexec option set on removable media partitions — `L1`, not scored

**Requires.** `noexec` on removable media.
**Status.** `not applicable`.
**Evidence (verified).** As 1.1.18.
**Cost.** none.

#### 1.1.21 Ensure sticky bit is set on all world-writable directories — `L1`, scored

**Requires.** No world-writable directory without the sticky bit (excluding `/tmp` and other documented exceptions).
**Status.** `non-compliant` — not for `/tmp`, but for the directories u-root's init creates at the root.
**Evidence (verified).** `/tmp` and `/dev/shm` are tmpfs roots, which the kernel creates `0777|S_ISVTX` (`linux/mm/shmem.c:5264`), so those are sticky. But `u-root/pkg/libinit/root_linux.go:115-122` creates `/buildbin`, `/ubin`, `/env`, `/tcz`, `/lib`, `/usr/lib` and `/var/log` with mode `0o777` on the ramfs/tmpfs root, where the sticky bit is *not* implied. Those are world-writable directories without it.
**Cost.** trivial — `chmod 1777` for the genuinely shared ones, `0755` for `/lib`, `/usr/lib`, `/var/log`; either in `uinit` or by changing u-root's modes.

#### 1.1.22 Disable Automounting — `L1`, scored

**Requires.** No automounter running or installable.
**Status.** `comply`.
**Evidence (verified).** `# CONFIG_AUTOFS_FS is not set` in the resolved config; there is no `automount`, `autofs` or `systemd` in the image.
**Cost.** none.

#### 1.1.23 Disable USB Storage — `L1`, scored

**Requires.** The `usb-storage` module is not loaded/available.
**Status.** `comply`.
**Evidence (verified).** `CONFIG_USB` is absent from the resolved config, so there is no USB stack at all, let alone storage.
**Cost.** none. This is the M3 problem in advance: a GPU node that needs USB anything would have to add the subsystem back.

### 1.2 Configure Software Updates

#### 1.2.1 Ensure package manager repositories are configured — `L1`, not scored

**Requires.** The distribution's package manager has configured, reachable repositories.
**Status.** `not applicable` — there is no package manager.
**Evidence (verified).** The image contains no `apt`, `dpkg`, `rpm`, `yum`, `dnf`, `apk`, `pacman` or package database (cpio listing, 172 entries). Software arrives by rebuilding: `DIT` clones eight component branches over HTTPS, builds them, and assembles one cpio (`DIT:101-118`, `DIT:191-213`).
**Cost.** none. The control's *intent* — that software comes from a known source and can be updated — is met by the build, and the build is recorded in `DIT` and the image's file list. It is not met by an in-place update mechanism, because the design forbids one.

#### 1.2.2 Ensure GPG keys are configured — `L1`, not scored

**Requires.** The package manager's repository signing keys are installed and correct.
**Status.** `not applicable` — no package manager, so no repository keys.
**Evidence (verified).** As 1.2.1. What *is* present is a TLS trust store: `etc/ssl/certs/ca-certificates.crt` (182,140 bytes) is baked in by `DIT:195` so image pulls can use HTTPS.
**Cost.** none for the control as written. The analogous control that matters here is image provenance (1.3.2): the cpio is unhashed and unsigned at boot, and the roadmap names "iPXE HTTPS trust model and image signature verification" as an open risk.

### 1.3 Filesystem Integrity Checking

#### 1.3.1 Ensure AIDE is installed — `L1`, scored

**Requires.** A file-integrity tool (AIDE) is installed, with a baseline database.
**Status.** `non-compliant`.
**Evidence (verified).** AIDE is not in the image (cpio listing: no `aide`, no `/etc/aide`), is not in the u-root applet set, and cannot be installed without a package manager. There is also no persistent filesystem on which a baseline could meaningfully change between boots.
**Cost.** large — build AIDE (C) statically, generate a baseline at image-build time, and run the check at boot. It would detect modification of *runtime* files under `/tmp`, `/var`, which is the only thing that can change. That is a narrow benefit; see 1.3.2 for the better-shaped alternative.

#### 1.3.2 Ensure filesystem integrity is regularly checked — `L1`, scored

**Requires.** A scheduled integrity check against the baseline.
**Status.** `partial` — the property is achievable and the mechanism is absent.
**Evidence (verified).** Nothing runs an integrity check: `cmd/uinit/main.go` has no hash or signature step, and the console logs only what it starts. The *strong* form of this control for this system is available and unbuilt: the image is a fixed cpio whose SHA-256 is a complete integrity statement, and the boot protocol (iPXE) is where it should be checked before the kernel is loaded. `docs/roadmap.md` lists exactly that under "Open risks".
**Cost.** moderate — hash and/or sign `initramfs.cpio` at build time, verify in the iPXE script (the boot path that does not exist yet) or in a tiny pre-`uinit` check. This is worth doing; AIDE is not.

### 1.4 Secure Boot Settings

#### 1.4.1 Ensure permissions on bootloader config are configured — `L1`, scored

**Requires.** The bootloader configuration (e.g. `grub.cfg`) is mode 0400 and owned by root.
**Status.** `not applicable` — there is no bootloader.
**Evidence (verified).** The image is booted with QEMU `-kernel ... -initrd ...` (`Makefile:44-45`); there is no GRUB, no `grub.cfg`, no `extlinux`, no `bootloader` directory in the image. Production is intended to be iPXE chainload (`docs/roadmap.md`, "Decisions (locked)"), which has a script rather than a bootloader config.
**Cost.** none as written. The equivalent control for iPXE is that its script is served over authenticated HTTPS with an embedded CA — an open risk, not a built feature.

#### 1.4.2 Ensure bootloader password is set — `L1`, scored

**Requires.** A bootloader password restricts editing of kernel parameters.
**Status.** `not applicable` — no bootloader, no interactive boot menu.
**Evidence (verified).** As 1.4.1. The kernel cmdline is fixed by the boot protocol (`Makefile:45`: `console=ttyS0,115200 panic=-1 cgroup_no_v1=all`); there is no menu to edit it in.
**Cost.** none. The real control for this system is who may serve the cmdline and the image — the same boot-channel trust question.

#### 1.4.3 Ensure authentication required for single user mode — `L1`, scored

**Requires.** Booting into single-user/rescue mode requires the root password.
**Status.** `non-compliant` — not because a single-user mode is unprotected, but because the console *is* an unauthenticated root shell.
**Evidence (verified).** u-root's init runs `/bbin/uinit`, then `/bin/defaultsh`, then `/bin/sh` (`u-root/cmds/core/init/init.go:11-12`; `u-root/pkg/libinit/proc_linux.go:93` waits for each). `/bin/sh` exists in the image, so PID 1 ends in an interactive root shell on `ttyS0` with no authentication. `cmd/uinit/main.go:13-15` documents this fall-through. There is no `sulogin`, no `login`, no `/etc/securetty`.
**Cost.** moderate, and it is a design question rather than a patch: stop init from running a shell, or make the console output-only. That means either changing u-root's init (a cloned dependency) or replacing it with a small init of our own that runs `uinit` and nothing else. **It does not conflict with strict RAM-only**; it conflicts with u-root's convenience behaviour.

#### 1.4.4 Ensure interactive boot is not enabled — `L1`, not scored

**Requires.** The bootloader is not set to prompt for confirmation.
**Status.** `not applicable` — no bootloader, no prompt.
**Evidence (verified).** As 1.4.1.
**Cost.** none.

### 1.5 Additional Process Hardening

#### 1.5.1 Ensure core dumps are restricted — `L1`, scored

**Requires.** `hard core dumps = 0` in `limits.conf` and `fs.suid_dumpable = 0`.
**Status.** `comply` — stronger than the control: the kernel cannot write a core file at all.
**Evidence (verified).** `CONFIG_COREDUMP` is not set in the resolved config, so `do_coredump` does not exist; `ulimit -c` and `fs.suid_dumpable` have nothing to govern. There is also no `/etc/security/limits.conf` and no PAM to read one.
**Cost.** none. Do not enable `CONFIG_COREDUMP` without deciding where cores would go (there is no disk) and who could read them.

#### 1.5.2 Ensure XD/NX support is enabled — `L1`, scored

**Requires.** The CPU's NX/XD bit is in use (audit: `dmesg | grep NX`, or `cpuinfo`).
**Status.** `comply` — **(inferred)** from the architecture and config, not from a boot.
**Evidence (inferred).** `CONFIG_X86_64=y` in the resolved config; NX is architectural on x86-64 and the kernel enables it whenever the CPU reports it. `CONFIG_IA32_EMULATION` is not set, so there are no 32-bit userspace mappings to worry about either.
**Cost.** none.

#### 1.5.3 Ensure address space layout randomization (ASLR) is enabled — `L1`, scored

**Requires.** `kernel.randomize_va_space = 2`.
**Status.** `comply` — **(inferred)** from the kernel's compiled default.
**Evidence (inferred).** `linux/mm/memory.c:121-125`: `randomize_va_space` is initialised to `1` under `CONFIG_COMPAT_BRK` and to `2` otherwise; `# CONFIG_COMPAT_BRK is not set` in the resolved config. `CONFIG_SYSCTL=y` exposes the knob, and nothing writes it. A boot would settle it; the source and config together are strong.
**Cost.** none. Note `CONFIG_RANDOMIZE_BASE` is *not* set, so the *kernel* image is not KASLR'd; this control is about userspace and is satisfied.

#### 1.5.4 Ensure prelink is disabled — `L1`, scored

**Requires.** `prelink` is not installed and `/etc/prelink.conf` does not exist.
**Status.** `comply`.
**Evidence (verified).** No `prelink` in the image, no `/etc/prelink.conf`, and no dynamic linker: every binary is static (`DIT:142-150` builds runc, kubelet and the shim with `CGO_ENABLED=0`; u-root builds `bb` statically), and `/lib64` and `/usr/lib` in the image are empty directories.
**Cost.** none.

### 1.6 Mandatory Access Control

#### 1.6.1.1 Ensure SELinux or AppArmor are installed — `L2`, scored

**Requires.** A MAC framework is present in the kernel and in userspace.
**Status.** `non-compliant` — there is no MAC framework at all.
**Evidence (verified).** `# CONFIG_SECURITY is not set` in `build/kernel/.config`. That removes the LSM framework itself, so `CONFIG_SECURITY_SELINUX`, `CONFIG_SECURITY_APPARMOR`, Yama, Landlock and LoadPin do not exist as options. There is no SELinux or AppArmor userspace in the image either.
**Cost.** large — `CONFIG_SECURITY` plus one LSM, policy authoring, and a userspace policy loader. See the structural note in §4.4: seccomp and namespaces already confine containers; what an LSM would add is confinement of *the node's own* root processes.
**Appendix.** What a MAC would and would not buy here, and whether either is a hard requirement, is analysed in `cis-audit-and-mac.md`.

#### 1.6.2.1 Ensure SELinux is not disabled in bootloader configuration — `L2`, scored

**Requires.** The kernel cmdline does not contain `selinux=0` / `enforcing=0`.
**Status.** `not applicable` — there is no SELinux and no bootloader.
**Evidence (verified).** As 1.6.1.1 and 1.4.1. The cmdline (`Makefile:45`) contains no SELinux parameter, but that is because there is nothing to parameterise.
**Cost.** none.
**Appendix.** What a MAC would and would not buy here, and whether either is a hard requirement, is analysed in `cis-audit-and-mac.md`.

#### 1.6.2.2 Ensure the SELinux state is enforcing — `L2`, scored

**Requires.** `getenforce` reports `Enforcing`.
**Status.** `non-compliant`.
**Evidence (verified).** No SELinux in the kernel (`CONFIG_SECURITY` unset) and no `getenforce`/`setenforce` or policy in the image.
**Cost.** large, as 1.6.1.1.
**Appendix.** What a MAC would and would not buy here, and whether either is a hard requirement, is analysed in `cis-audit-and-mac.md`.

#### 1.6.2.3 Ensure SELinux policy is configured — `L2`, scored

**Requires.** `/etc/selinux/config` selects a policy (`SELINUXTYPE=targeted` or similar).
**Status.** `non-compliant`.
**Evidence (verified).** No `/etc/selinux` in the image; no policy files.
**Cost.** large. A policy for this node would be small in principle — `uinit`, `containerd`, `kubelet`, `runc`, `sshd` — but it is still policy engineering plus a userspace loader and a relabel step.
**Appendix.** What a MAC would and would not buy here, and whether either is a hard requirement, is analysed in `cis-audit-and-mac.md`.

#### 1.6.2.4 Ensure SETroubleshoot is not installed — `L2`, scored

**Requires.** `setroubleshoot` is not installed.
**Status.** `comply`.
**Evidence (verified).** Not in the image (cpio listing); there is no SELinux for it to troubleshoot.
**Cost.** none.
**Appendix.** What a MAC would and would not buy here, and whether either is a hard requirement, is analysed in `cis-audit-and-mac.md`.

#### 1.6.2.5 Ensure the MCS Translation Service (mcstrans) is not installed — `L2`, scored

**Requires.** `mcstrans` is not installed.
**Status.** `comply`.
**Evidence (verified).** Not in the image (cpio listing).
**Cost.** none.
**Appendix.** What a MAC would and would not buy here, and whether either is a hard requirement, is analysed in `cis-audit-and-mac.md`.

#### 1.6.2.6 Ensure no unconfined daemons exist — `L2`, scored

**Requires.** No process runs outside the MAC policy.
**Status.** `non-compliant` — every process is unconfined.
**Evidence (verified).** With `CONFIG_SECURITY` unset there is no policy to be confined by. `containerd`, `kubelet`, `runc`, `sshd` and `uinit` all run as root with full capabilities (`cmd/uinit/main.go:294-320` starts them with no credential or capability change).
**Cost.** large — the same work as 1.6.1.1, and it is the item that makes the MAC family worth doing or not.
**Appendix.** What a MAC would and would not buy here, and whether either is a hard requirement, is analysed in `cis-audit-and-mac.md`.

#### 1.6.3.1 Ensure AppArmor is not disabled in bootloader configuration — `L2`, scored

**Requires.** The cmdline does not disable AppArmor.
**Status.** `not applicable` — no AppArmor, no bootloader.
**Evidence (verified).** As 1.6.1.1 and 1.4.1.
**Cost.** none.
**Appendix.** What a MAC would and would not buy here, and whether either is a hard requirement, is analysed in `cis-audit-and-mac.md`.

#### 1.6.3.2 Ensure all AppArmor Profiles are enforcing — `L2`, scored

**Requires.** Every loaded AppArmor profile is in enforce mode.
**Status.** `non-compliant`.
**Evidence (verified).** No AppArmor in kernel or userspace.
**Cost.** large. If a MAC is chosen, AppArmor is plausibly the cheaper of the two for this node (path-based profiles, no relabel, no policy compiler needed at runtime), but it is still a new subsystem plus profiles.
**Appendix.** What a MAC would and would not buy here, and whether either is a hard requirement, is analysed in `cis-audit-and-mac.md`.

### 1.7 Warning Banners

#### 1.7.1.1 Ensure message of the day is configured properly — `L1`, scored

**Requires.** `/etc/motd` exists with the site's banner and no OS information.
**Status.** `non-compliant`.
**Evidence (verified).** No `/etc/motd` in the image (cpio listing). Nothing prints a banner: the console shell is `bb`'s `gosh` via `/bin/sh`, and u-root's sshd has no banner support.
**Cost.** cheap to create the file, but there is no login program that would display it. Low value; see 1.7.1.3 for the one that would matter.

#### 1.7.1.2 Ensure local login warning banner is configured properly — `L1`, scored

**Requires.** `/etc/issue` contains the warning banner.
**Status.** `non-compliant`.
**Evidence (verified).** No `/etc/issue`; no `getty`/`login`/`agetty` in the image to read one.
**Cost.** trivial to create the file; there is no local login path, so it would never be shown. The console is a shell, not a login prompt.

#### 1.7.1.3 Ensure remote login warning banner is configured properly — `L1`, scored

**Requires.** `/etc/issue.net` contains the banner and `sshd` is configured with `Banner /etc/issue.net`.
**Status.** `non-compliant`.
**Evidence (verified).** No `/etc/issue.net`, and u-root's sshd has no `Banner` option — its flags are `-keys`, `-privatekey`, `-ip`, `-port`, `-d` only (`u-root/cmds/core/sshd/sshd.go:41-48`), and no `sshd_config` is read.
**Cost.** moderate — would require a change to u-root's sshd (a cloned dependency) or replacing sshd. Only worth it if sshd survives into production at all (see §10, question 2).

#### 1.7.1.4 Ensure permissions on /etc/motd are configured — `L1`, scored

**Requires.** `/etc/motd` is 0644 or more restrictive.
**Status.** `not applicable` — the file does not exist.
**Evidence (verified).** No `/etc/motd`.
**Cost.** none.

#### 1.7.1.5 Ensure permissions on /etc/issue are configured — `L1`, scored

**Requires.** `/etc/issue` is 0644 or more restrictive.
**Status.** `not applicable` — the file does not exist.
**Evidence (verified).** No `/etc/issue`.
**Cost.** none.

#### 1.7.1.6 Ensure permissions on /etc/issue.net are configured — `L1`, scored

**Requires.** `/etc/issue.net` is 0644 or more restrictive.
**Status.** `not applicable` — the file does not exist.
**Evidence (verified).** No `/etc/issue.net`.
**Cost.** none.

#### 1.7.2 Ensure GDM login banner is configured — `L1`, scored

**Requires.** If GDM is installed, its login banner is configured.
**Status.** `not applicable`.
**Evidence (verified).** No X server, no GDM, no display manager in the image.
**Cost.** none.

### 1.8 Ensure patches are installed

#### 1.8 Ensure updates, patches, and additional security software are installed — `L1`, not scored

**Requires.** The system has the latest patches, per the package manager.
**Status.** `partial` — patches arrive by rebuilding, and nothing records or checks what was built.
**Evidence (verified).** `DIT:101-118` fetches each component's upstream branch over HTTPS and prints the revision it built; the image is reassembled on every build, so a rebuild *is* a patch event. But there is no package database, no pinned revision in the image, no SBOM, no CVE scan and no recorded build provenance in the artifact. The branch-tracking decision is recorded in `CLAUDE.md` and `DIT`'s header and is deliberate; the missing part is the record, not the fetch.
**Cost.** moderate, and compatible with the design: emit the printed revisions plus the component SBOM into the image (or alongside it) and scan them in CI. Re-pinning to SHAs would conflict with the recorded decision; recording what was built would not.

### 2 Services

The image's complete contents are 172 cpio entries: the `bb` applet set from
`u-root/cmds/core/*`, the four standalone binaries (`containerd-shim-runc-v2`,
`runc`, `kubelet`), the CNI plugins, the node config files and the CA bundle
(`DIT:191-213`; verified with `cpio -itv`). None of the services named in §2.1–
2.3 is among them. For "service X is not enabled" controls, **not shipping it is a
stronger guarantee than disabling it**, and that is the basis for the `comply`
entries below rather than a guess.

#### 2.1.1 Ensure chargen services are not enabled — `L1`, scored

**Requires.** No `chargen` inetd service.
**Status.** `comply`.
**Evidence (verified).** No `inetd`, no `xinetd`, no `/etc/inetd.conf` in the image; no `chargen` applet.
**Cost.** none.

#### 2.1.2 Ensure daytime services are not enabled — `L1`, scored

**Requires.** No `daytime` inetd service.
**Status.** `comply`.
**Evidence (verified).** As 2.1.1.
**Cost.** none.

#### 2.1.3 Ensure discard services are not enabled — `L1`, scored

**Requires.** No `discard` inetd service.
**Status.** `comply`.
**Evidence (verified).** As 2.1.1.
**Cost.** none.

#### 2.1.4 Ensure echo services are not enabled — `L1`, scored

**Requires.** No `echo` inetd service.
**Status.** `comply`.
**Evidence (verified).** `bb` has an `echo` applet, but it is a local command, not a network service; there is no inetd to expose it.
**Cost.** none.

#### 2.1.5 Ensure time services are not enabled — `L1`, scored

**Requires.** No `time` inetd service.
**Status.** `comply`.
**Evidence (verified).** As 2.1.1.
**Cost.** none.

#### 2.1.6 Ensure rsh server is not enabled — `L1`, scored

**Requires.** No `rshd`/`rlogind`/`rexecd`.
**Status.** `comply`.
**Evidence (verified).** No rsh server binaries in the image.
**Cost.** none.

#### 2.1.7 Ensure talk server is not enabled — `L1`, scored

**Requires.** No `talkd`/`ntalkd`.
**Status.** `comply`.
**Evidence (verified).** No talk server in the image.
**Cost.** none.

#### 2.1.8 Ensure telnet server is not enabled — `L1`, scored

**Requires.** No `telnetd`.
**Status.** `comply`.
**Evidence (verified).** No telnet server in the image.
**Cost.** none.

#### 2.1.9 Ensure tftp server is not enabled — `L1`, scored

**Requires.** No `tftpd`.
**Status.** `comply`.
**Evidence (verified).** No tftp server in the image. (iPXE will *pull* over the network; nothing TFTP-serves from the node.)
**Cost.** none.

#### 2.1.10 Ensure xinetd is not enabled — `L1`, scored

**Requires.** `xinetd` is not running.
**Status.** `comply`.
**Evidence (verified).** `xinetd` is not in the image.
**Cost.** none.

#### 2.2.1.1 Ensure time synchronization is in use — `L1`, not scored

**Requires.** One of `ntp`, `chrony` or `systemd-timesyncd` is installed and running.
**Status.** `non-compliant` — the node has no time synchronization at all.
**Evidence (verified).** `cmd/uinit/main.go` does no time step: the node's steps are link-up, `dhclient`, `resolv.conf`, sshd, mounts, cgroups, containerd, kubelet. No `ntpd`, `chronyd` or `systemd-timesyncd` is in the image. `bb` carries an `ntpdate` applet, but nothing invokes it.
**Cost.** cheap to moderate — one `ntpdate` call in `uinit` against a configured server (or DHCP option 42) is enough for a node whose clock only needs to be close for TLS and log correlation. A continuously-running NTP client is not needed on a machine that reboots into a fresh clock. This one is worth doing: kubelet certificate validation and log timestamps both care.

#### 2.2.1.2 Ensure ntp is configured — `L1`, scored

**Requires.** If `ntp` is in use, `/etc/ntp.conf` restricts queries and names servers.
**Status.** `not applicable` — no ntp daemon is installed (see 2.2.1.1).
**Evidence (verified).** No `ntpd`, no `/etc/ntp.conf`.
**Cost.** none unless 2.2.1.1 is closed with ntpd; a single `ntpdate` would not create the config this control audits. An auditor would record this as a fail because the daemon is absent, which is why 2.2.1.1 is the item that matters.

#### 2.2.1.3 Ensure chrony is configured — `L1`, scored

**Requires.** If chrony is in use, `/etc/chrony.conf` names servers and restricts access.
**Status.** `not applicable` — no chrony.
**Evidence (verified).** No `chronyd`, no `/etc/chrony.conf`.
**Cost.** none, as 2.2.1.2.

#### 2.2.1.4 Ensure systemd-timesyncd is configured — `L1`, scored

**Requires.** If systemd-timesyncd is in use, it is configured.
**Status.** `not applicable` — there is no systemd.
**Evidence (verified).** No `systemd`, no `timesyncd`, no `timedatectl` in the image.
**Cost.** none.

#### 2.2.2 Ensure X Window System is not installed — `L1`, scored

**Requires.** No X server packages.
**Status.** `comply`.
**Evidence (verified).** No X server, no X libraries, no `/usr/bin/X` in the image.
**Cost.** none.

#### 2.2.3 Ensure Avahi Server is not enabled — `L1`, scored

**Requires.** `avahi-daemon` is not running.
**Status.** `comply`.
**Evidence (verified).** No avahi in the image.
**Cost.** none.

#### 2.2.4 Ensure CUPS is not enabled — `L1`, scored

**Requires.** `cups` is not running.
**Status.** `comply`.
**Evidence (verified).** No CUPS in the image.
**Cost.** none.

#### 2.2.5 Ensure DHCP Server is not enabled — `L1`, scored

**Requires.** No DHCP server is running.
**Status.** `comply`.
**Evidence (verified).** `bb` has `dhclient` (a client, used at `cmd/uinit/main.go:76,166`), not `dhcpd`. No DHCP server in the image.
**Cost.** none.

#### 2.2.6 Ensure LDAP server is not enabled — `L1`, scored

**Requires.** No `slapd`.
**Status.** `comply`.
**Evidence (verified).** No LDAP server in the image.
**Cost.** none.

#### 2.2.7 Ensure NFS and RPC are not enabled — `L1`, scored

**Requires.** No NFS server or rpcbind.
**Status.** `comply`.
**Evidence (verified).** No NFS server, no `rpcbind`, no `rpc.statd`; `CONFIG_NFS_FS` is also not set, so the kernel cannot even be an NFS client.
**Cost.** none.

#### 2.2.8 Ensure DNS Server is not enabled — `L1`, scored

**Requires.** No DNS server is exposed by the host.
**Status.** `comply`.
**Evidence (verified).** `coredns` is in the image (`DIT:211`), but nothing starts it and it is not a host service — it is there so a cluster can run it. No listener is configured by `uinit`.
**Cost.** none.

#### 2.2.9 Ensure FTP Server is not enabled — `L1`, scored

**Requires.** No FTP server.
**Status.** `comply`.
**Evidence (verified).** None in the image.
**Cost.** none.

#### 2.2.10 Ensure HTTP server is not enabled — `L1`, scored

**Requires.** No HTTP server.
**Status.** `comply`.
**Evidence (verified).** No HTTP server in the image. The only HTTP client is `uinit`'s readiness probe (`cmd/uinit/main.go:381-398`) and `bb`'s `wget`, neither of which listens.
**Cost.** none.

#### 2.2.11 Ensure IMAP and POP3 server is not enabled — `L1`, scored

**Requires.** No IMAP/POP3 server.
**Status.** `comply`.
**Evidence (verified).** None in the image.
**Cost.** none.

#### 2.2.12 Ensure Samba is not enabled — `L1`, scored

**Requires.** No Samba.
**Status.** `comply`.
**Evidence (verified).** None in the image.
**Cost.** none.

#### 2.2.13 Ensure HTTP Proxy Server is not enabled — `L1`, scored

**Requires.** No proxy server.
**Status.** `comply`.
**Evidence (verified).** None in the image.
**Cost.** none.

#### 2.2.14 Ensure SNMP Server is not enabled — `L1`, scored

**Requires.** No SNMP daemon.
**Status.** `comply`.
**Evidence (verified).** None in the image.
**Cost.** none.

#### 2.2.15 Ensure mail transfer agent is configured for local-only mode — `L1`, scored

**Requires.** An MTA, if present, does not listen on non-loopback interfaces.
**Status.** `comply` — there is no MTA.
**Evidence (verified).** No `sendmail`, `postfix`, `exim` or `msmtp` in the image; nothing binds port 25.
**Cost.** none.

#### 2.2.16 Ensure rsync service is not enabled — `L1`, scored

**Requires.** No rsync daemon.
**Status.** `comply`.
**Evidence (verified).** No rsync in the image.
**Cost.** none.

#### 2.2.17 Ensure NIS Server is not enabled — `L1`, scored

**Requires.** No NIS server.
**Status.** `comply`.
**Evidence (verified).** No `ypserv` in the image.
**Cost.** none.

#### 2.3.1 Ensure NIS Client is not installed — `L1`, scored

**Requires.** No NIS client packages.
**Status.** `comply`.
**Evidence (verified).** Not in the image.
**Cost.** none.

#### 2.3.2 Ensure rsh client is not installed — `L1`, scored

**Requires.** No `rsh`/`rcp`/`rlogin`.
**Status.** `comply`.
**Evidence (verified).** Not in the image. Note `bb` does ship `scp`, which is SSH-based; that is not the legacy rsh.
**Cost.** none.

#### 2.3.3 Ensure talk client is not installed — `L1`, scored

**Requires.** No `talk` client.
**Status.** `comply`.
**Evidence (verified).** Not in the image.
**Cost.** none.

#### 2.3.4 Ensure telnet client is not installed — `L1`, scored

**Requires.** No `telnet` client.
**Status.** `comply`.
**Evidence (verified).** Not in the image.
**Cost.** none.

#### 2.3.5 Ensure LDAP client is not installed — `L1`, scored

**Requires.** No LDAP client.
**Status.** `comply`.
**Evidence (verified).** Not in the image.
**Cost.** none.

### 3 Network Configuration

There is no sysctl configuration in this repository or image: no `/etc/sysctl.conf`,
no `/etc/sysctl.d`, and no write to `/proc/sys` in `cmd/uinit/main.go`. Every
control in §3.1–3.2 therefore reflects a **compiled kernel default**, quoted from
the kernel source in `linux/`. `CONFIG_SYSCTL=y`
(`configs/k4s-tiny.config:47`) means each of them is one `write()` away from
being fixed — `uinit` already has the helper (`cmd/uinit/main.go:335`).

#### 3.1.1 Ensure IP forwarding is disabled — `L1`, scored

**Requires.** `net.ipv4.ip_forward = 0` (the benchmark's "host only" profile).
**Status.** `comply` as built — with a structural caveat that matters more than the status.
**Evidence (verified).** The kernel's IPv4 devconf defaults do not enable forwarding (`linux/net/ipv4/devinet.c:60-80`), and nothing in the image writes `/proc/sys/net/ipv4/ip_forward`. Under `K4S_CNI=cilium`, the agent sets it to 1 at runtime; under flannel host-gw nothing does, which is why the current single-node test passes while cross-node pod traffic would not.
**Cost.** none to keep it disabled, but **this control conflicts with the product**: a Kubernetes worker that forwards pod traffic across nodes needs `ip_forward=1`. The right answer is a documented exception for 3.1.1 (and 3.1.2 is the one to fix), not compliance. See §10, question 3.

#### 3.1.2 Ensure packet redirect sending is disabled — `L1`, scored

**Requires.** `net.ipv4.conf.all.send_redirects = 0` and `.../default/send_redirects = 0`.
**Status.** `non-compliant`.
**Evidence (verified).** Kernel default is `1` (`linux/net/ipv4/devinet.c:74`); nothing overrides it.
**Cost.** trivial — two writes in `uinit`. Also worth writing the per-interface value, since the benchmark checks both.

#### 3.2.1 Ensure source routed packets are not accepted — `L1`, scored

**Requires.** `accept_source_route = 0` on all and default.
**Status.** `comply`.
**Evidence (verified).** `IPV4_DEVCONF_ACCEPT_SOURCE_ROUTE` is not among the devconf defaults that are set to 1 (`linux/net/ipv4/devinet.c:60-80`), so it is 0.
**Cost.** none. Cheap to make explicit anyway, which is worth doing because "default 0" is not a documented guarantee.

#### 3.2.2 Ensure ICMP redirects are not accepted — `L1`, scored

**Requires.** `accept_redirects = 0` on all and default.
**Status.** `non-compliant`.
**Evidence (verified).** Kernel default is `1` (`linux/net/ipv4/devinet.c:73`).
**Cost.** trivial.

#### 3.2.3 Ensure secure ICMP redirects are not accepted — `L1`, scored

**Requires.** `secure_redirects = 0` on all and default.
**Status.** `non-compliant`.
**Evidence (verified).** Kernel default is `1` (`linux/net/ipv4/devinet.c:75`).
**Cost.** trivial.

#### 3.2.4 Ensure suspicious packets are logged — `L1`, scored

**Requires.** `log_martians = 1` on all and default.
**Status.** `non-compliant`.
**Evidence (verified).** `log_martians` is not set in the devconf defaults, so it is `0`. Separately, `CONFIG_NETFILTER_XT_TARGET_LOG` is not set, so an iptables `LOG` rule would also fail — but this control is the sysctl.
**Cost.** trivial. Note that the log destination is the kernel ring buffer and then the serial console; with no syslog daemon (4.2.1.x) the records are not persisted. Still worth having, because the console is captured.

#### 3.2.5 Ensure broadcast ICMP requests are ignored — `L1`, scored

**Requires.** `icmp_echo_ignore_broadcasts = 1`.
**Status.** `comply`.
**Evidence (verified).** Kernel sets it to `1` per network namespace (`linux/net/ipv4/icmp.c:1724`).
**Cost.** none.

#### 3.2.6 Ensure bogus ICMP responses are ignored — `L1`, scored

**Requires.** `icmp_ignore_bogus_error_responses = 1`.
**Status.** `comply`.
**Evidence (verified).** Kernel sets it to `1` (`linux/net/ipv4/icmp.c:1727`).
**Cost.** none.

#### 3.2.7 Ensure Reverse Path Filtering is enabled — `L1`, scored

**Requires.** `rp_filter = 1` on all and default.
**Status.** `non-compliant`.
**Evidence (verified).** Kernel default is `0` (not set in `linux/net/ipv4/devinet.c:60-80`).
**Cost.** trivial, with a CNI caveat: strict rp_filter (`1`) can drop legitimate pod traffic on multi-homed nodes; loose mode (`2`) is the usual compromise. The benchmark asks for `1`.

#### 3.2.8 Ensure TCP SYN Cookies is enabled — `L1`, scored

**Requires.** `net.ipv4.tcp_syncookies = 1`.
**Status.** `non-compliant` — and the sysctl does not exist.
**Evidence (verified).** `# CONFIG_SYN_COOKIES is not set` in the resolved config; the sysctl table entry is compiled only under that symbol (`linux/net/ipv4/sysctl_net_ipv4.c:1038`).
**Cost.** cheap — one line in `configs/k4s-tiny.config` plus one `write()` in `uinit`. This is the only control in §3.2 that needs a kernel change, and it is the cheapest kernel change in this document.

#### 3.2.9 Ensure IPv6 router advertisements are not accepted — `L1`, scored

**Requires.** `net.ipv6.conf.all.accept_ra = 0` and `.../default/accept_ra = 0`.
**Status.** `non-compliant`.
**Evidence (verified).** Kernel default is `1` (`linux/net/ipv6/addrconf.c:185,250`). `uinit` brings `eth0` up and runs `dhclient -ipv6=false` (`cmd/uinit/main.go:75-76`), so no IPv6 address is configured, but the interface still accepts router advertisements.
**Cost.** trivial. If 3.7 (disable IPv6) is taken, this becomes moot.

#### 3.3.1 Ensure TCP Wrappers is installed — `L1`, not scored

**Requires.** `libwrap`/`tcpd` is installed.
**Status.** `not applicable` — TCP Wrappers is a libc/inetd-era mechanism with nothing to wrap here.
**Evidence (verified).** No `tcpd`, no `libwrap`, no `inetd`, no `xinetd`; the only network listener the node starts is u-root's Go sshd, which does not use libwrap.
**Cost.** none. Adding libwrap would not affect the Go sshd.

#### 3.3.2 Ensure /etc/hosts.allow is configured — `L1`, not scored

**Requires.** `/etc/hosts.allow` restricts access.
**Status.** `not applicable` — no libwrap consumer.
**Evidence (verified).** File absent from the image.
**Cost.** none.

#### 3.3.3 Ensure /etc/hosts.deny is configured — `L1`, not scored

**Requires.** `/etc/hosts.deny` denies by default.
**Status.** `not applicable`.
**Evidence (verified).** File absent.
**Cost.** none.

#### 3.3.4 Ensure permissions on /etc/hosts.allow are configured — `L1`, scored

**Requires.** The file is 0644 or more restrictive.
**Status.** `not applicable` — the file does not exist.
**Evidence (verified).** File absent.
**Cost.** none.

#### 3.3.5 Ensure permissions on /etc/hosts.deny are configured — `L1`, scored

**Requires.** The file is 0644 or more restrictive.
**Status.** `not applicable` — the file does not exist.
**Evidence (verified).** File absent.
**Cost.** none.

#### 3.4.1 Ensure DCCP is disabled — `L2`, scored

**Requires.** The `dccp` module is not available/loaded.
**Status.** `comply`.
**Evidence (verified).** `CONFIG_DCCP` is absent from the resolved config.
**Cost.** none. One of the cheapest Level 2 items in the benchmark.

#### 3.4.2 Ensure SCTP is disabled — `L2`, scored

**Requires.** The `sctp` module is not available/loaded.
**Status.** `comply`.
**Evidence (verified).** `# CONFIG_IP_SCTP is not set`.
**Cost.** none.

#### 3.4.3 Ensure RDS is disabled — `L2`, scored

**Requires.** The `rds` module is not available/loaded.
**Status.** `comply`.
**Evidence (verified).** `# CONFIG_RDS is not set`.
**Cost.** none.

#### 3.4.4 Ensure TIPC is disabled — `L2`, scored

**Requires.** The `tipc` module is not available/loaded.
**Status.** `comply`.
**Evidence (verified).** `# CONFIG_TIPC is not set`.
**Cost.** none.

#### 3.5.1.1 Ensure IPv6 default deny firewall policy — `L1`, scored

**Requires.** An IPv6 firewall with a default-deny policy on input, output and forward.
**Status.** `non-compliant`.
**Evidence (verified).** No `ip6tables`, `nft` or `iptables` binary in the image. `CONFIG_IP6_NF_IPTABLES` is not set, so the legacy IPv6 tables do not exist; `CONFIG_NF_TABLES_IPV6=y` (`configs/k4s-cni.config:136`) means an nftables-based tool *could* work, but none is shipped and no rules are loaded.
**Cost.** moderate — ship an nftables or iptables-nft binary and load a policy in `uinit`. It also raises an ownership question: the CNI (especially Cilium) manages firewall state, and a node-level policy can conflict with it.

#### 3.5.1.2 Ensure IPv6 loopback traffic is configured — `L1`, scored

**Requires.** Loopback interface traffic is allowed by the IPv6 policy.
**Status.** `non-compliant` — there is no policy.
**Evidence (verified).** As 3.5.1.1.
**Cost.** moderate, and only meaningful once a policy exists.

#### 3.5.1.3 Ensure IPv6 outbound and established connections are configured — `L1`, not scored

**Requires.** The policy allows outbound and established flows.
**Status.** `non-compliant` — there is no policy.
**Evidence (verified).** As 3.5.1.1.
**Cost.** moderate, downstream of 3.5.1.1.

#### 3.5.1.4 Ensure IPv6 firewall rules exist for all open ports — `L1`, not scored

**Requires.** Every listening port has an explicit rule.
**Status.** `non-compliant`.
**Evidence (verified).** No firewall binary or rules. The node's listeners would be sshd (2022) and kubelet (10250).
**Cost.** moderate, downstream of 3.5.1.1.

#### 3.5.2.1 Ensure default deny firewall policy — `L1`, scored

**Requires.** An IPv4 firewall with a default-deny policy.
**Status.** `non-compliant`.
**Evidence (verified).** No `iptables`/`nft` binary in the image (cpio listing). The kernel does have the tables — `CONFIG_IP_NF_FILTER=y` and `CONFIG_IP_NF_NAT=y` (`configs/k4s-cni.config:93-94`), added for Cilium — but no rules are installed by the node.
**Cost.** moderate. The roadmap records that "masquerade and port mappings are off: no iptables binary"; adding one is a deliberate reversal of that, and it must not fight the CNI.

#### 3.5.2.2 Ensure loopback traffic is configured — `L1`, scored

**Requires.** Loopback is allowed by the IPv4 policy.
**Status.** `non-compliant` — there is no policy.
**Evidence (verified).** As 3.5.2.1.
**Cost.** moderate, downstream of 3.5.2.1.

#### 3.5.2.3 Ensure outbound and established connections are configured — `L1`, not scored

**Requires.** The policy allows outbound and established flows.
**Status.** `non-compliant` — there is no policy.
**Evidence (verified).** As 3.5.2.1.
**Cost.** moderate, downstream of 3.5.2.1.

#### 3.5.2.4 Ensure firewall rules exist for all open ports — `L1`, scored

**Requires.** Every listening port has an explicit rule.
**Status.** `non-compliant`.
**Evidence (verified).** No firewall binary or rules.
**Cost.** moderate, downstream of 3.5.2.1.

#### 3.5.3 Ensure iptables is installed — `L1`, scored

**Requires.** An `iptables` binary is present.
**Status.** `non-compliant`.
**Evidence (verified).** No `iptables` in the image (cpio listing). `bb` does not provide one. The Cilium agent image carries its own `iptables`, but that runs inside a pod and is not the node's.
**Cost.** moderate — build or ship `iptables-nft` or `nftables`. Note `CONFIG_NETFILTER_XT_TARGET_LOG` is unset, so `LOG` rules would still fail without another kernel fragment line.

#### 3.6 Ensure wireless interfaces are disabled — `L1`, not scored

**Requires.** No wireless interfaces, or they are disabled.
**Status.** `comply`.
**Evidence (verified).** `# CONFIG_CFG80211 is not set` and no wireless driver in the resolved config; the QEMU VM has no wireless device; the image has no `iw`/`wpa_supplicant`.
**Cost.** none.

#### 3.7 Disable IPv6 — `L2`, not scored

**Requires.** IPv6 is disabled (the benchmark suggests `net.ipv6.conf.all.disable_ipv6 = 1` and disabling the module).
**Status.** `non-compliant`.
**Evidence (verified).** `CONFIG_IPV6=y` (selected by other options; it is not in either fragment), the stack is up on `eth0`, and nothing writes `disable_ipv6`. `dhclient` is run with `-ipv6=false` (`cmd/uinit/main.go:76`), so no global address is configured, but link-local and the stack remain.
**Cost.** cheap (a few sysctls), but **it conflicts with a recorded direction**: `configs/k4s-cni.config:136` deliberately enables `CONFIG_NF_TABLES_IPV6` for Cilium, and Cilium is evaluated as a real CNI option. Disabling IPv6 would make that fragment pointless. This is a policy decision, not a technical one — see §10, question 3.

### 4 Logging and Auditing

#### 4.1.1.1 Ensure audit log storage size is configured — `L2`, scored

**Requires.** `auditd` is configured with a maximum log file size (`max_log_file`).
**Status.** `non-compliant` — there is no audit subsystem.
**Evidence (verified).** `# CONFIG_AUDIT is not set` in `build/kernel/.config`; no `auditd`, no `/etc/audit/auditd.conf`, no `/var/log/audit` in the image. `CONFIG_AUDITSYSCALL` does not exist without `CONFIG_AUDIT`.
**Cost.** large — kernel options, then a userspace audit daemon (C, not in the u-root applet set), then a log destination. The RAM-only design makes "log storage size" a tmpfs size, not a disk quota.
**Appendix.** What auditd would and would not buy here, and whether it is a hard requirement, is analysed in `cis-audit-and-mac.md`.

#### 4.1.1.2 Ensure system is disabled when audit logs are full — `L2`, scored

**Requires.** `auditd` is configured to halt (or go single-user) when the log is full.
**Status.** `non-compliant`.
**Evidence (verified).** As 4.1.1.1: no auditd, no audit configuration.
**Cost.** large, and it interacts badly with RAM-only: a full tmpfs would halt the node, which is a denial-of-service vector. If audit is adopted, the fail-closed policy needs a considered answer here.
**Appendix.** What auditd would and would not buy here, and whether it is a hard requirement, is analysed in `cis-audit-and-mac.md`.

#### 4.1.1.3 Ensure audit logs are not automatically deleted — `L2`, scored

**Requires.** `max_log_file_action = keep_logs`.
**Status.** `non-compliant`.
**Evidence (verified).** As 4.1.1.1.
**Cost.** large, downstream of auditd. On tmpfs the logs vanish on reboot regardless, so "not automatically deleted" is only meaningful while the node is up.
**Appendix.** What auditd would and would not buy here, and whether it is a hard requirement, is analysed in `cis-audit-and-mac.md`.

#### 4.1.2 Ensure auditd is installed — `L2`, scored

**Requires.** The `auditd` package/binary is installed.
**Status.** `non-compliant`.
**Evidence (verified).** Not in the image (cpio listing), not an applet, and no package manager to install it. The kernel side is missing too (`CONFIG_AUDIT` unset).
**Cost.** large.
**Appendix.** What auditd would and would not buy here, and whether it is a hard requirement, is analysed in `cis-audit-and-mac.md`.

#### 4.1.3 Ensure auditd service is enabled — `L2`, scored

**Requires.** auditd starts at boot and is enabled.
**Status.** `non-compliant`.
**Evidence (verified).** Nothing in `cmd/uinit/main.go` starts an audit daemon; there is none to start.
**Cost.** large, downstream of 4.1.2. The landing place would be one more `background()` call in `uinit`.
**Appendix.** What auditd would and would not buy here, and whether it is a hard requirement, is analysed in `cis-audit-and-mac.md`.

#### 4.1.4 Ensure auditing for processes that start prior to auditd is enabled — `L2`, scored

**Requires.** `audit=1` on the kernel cmdline.
**Status.** `non-compliant` — and the parameter would be inert.
**Evidence (verified).** The cmdline is `console=ttyS0,115200 panic=-1 cgroup_no_v1=all` (`Makefile:45`); no `audit=1`. With `CONFIG_AUDIT` unset the audit code is not compiled in, so `audit=1` has no effect (the parameter is not even registered).
**Cost.** cheap once `CONFIG_AUDIT` exists (one cmdline token); large as a whole, because the kernel option must come first.
**Appendix.** What auditd would and would not buy here, and whether it is a hard requirement, is analysed in `cis-audit-and-mac.md`.

#### 4.1.5 Ensure events that modify date and time information are collected — `L2`, scored

**Requires.** Audit rules for `adjtimex`, `settimeofday`, `clock_settime`, and changes to `/etc/localtime`.
**Status.** `non-compliant`.
**Evidence (verified).** No audit rules exist (no auditd, no `/etc/audit/rules.d`). `/etc/localtime` is in the image (127 bytes) and is not watched.
**Cost.** large, downstream of auditd.
**Appendix.** What auditd would and would not buy here, and whether it is a hard requirement, is analysed in `cis-audit-and-mac.md`.

#### 4.1.6 Ensure events that modify user/group information are collected — `L2`, scored

**Requires.** Audit rules watching `/etc/passwd`, `/etc/group`, `/etc/shadow`, `/etc/gshadow` and their backups.
**Status.** `non-compliant`.
**Evidence (verified).** No audit rules. The files that exist (`/etc/passwd`, `/etc/group`, modes 0664) are on a tmpfs bind of `/tmp/etc` (`u-root/pkg/libinit/root_linux.go:151-153`), so runtime changes are possible and unwatched.
**Cost.** large, downstream of auditd. Of all the audit rules, this family and 4.1.7 are the ones with the most real content on this node.
**Appendix.** What auditd would and would not buy here, and whether it is a hard requirement, is analysed in `cis-audit-and-mac.md`.

#### 4.1.7 Ensure events that modify the system's network environment are collected — `L2`, scored

**Requires.** Audit rules watching `/etc/hosts`, `/etc/resolv.conf`, `sethostname`/`setdomainname`.
**Status.** `non-compliant`.
**Evidence (verified).** No audit rules. `uinit` rewrites `/etc/resolv.conf` at every boot (`cmd/uinit/main.go:79,168`) and kubelet sets the hostname, so these events genuinely happen.
**Cost.** large, downstream of auditd.
**Appendix.** What auditd would and would not buy here, and whether it is a hard requirement, is analysed in `cis-audit-and-mac.md`.

#### 4.1.8 Ensure events that modify the system's Mandatory Access Controls are collected — `L2`, scored

**Requires.** Audit rules watching `/etc/selinux`, `/etc/apparmor`, and MAC policy load events.
**Status.** `not applicable` — there is no MAC policy to modify.
**Evidence (verified).** `CONFIG_SECURITY` is not set and no SELinux/AppArmor userspace exists (see 1.6.1.1); there is no `/etc/selinux` or `/etc/apparmor.d`.
**Cost.** none as written; it would become live only if the LSM work in §1.6 is done, and then it is downstream of auditd too.
**Appendix.** What auditd would and would not buy here, and whether it is a hard requirement, is analysed in `cis-audit-and-mac.md`.

#### 4.1.9 Ensure login and logout events are collected — `L2`, scored

**Requires.** Audit rules matching `/var/log/lastlog`, `/var/log/btmp`, `/var/log/wtmp`.
**Status.** `non-compliant`.
**Evidence (verified).** No audit rules, and none of those files exist: there is no `login`/`getty`, and u-root's sshd logs to `/tmp/sshd.log` (`cmd/uinit/main.go:44,84`), not to wtmp/lastlog.
**Cost.** large, downstream of auditd. A smaller equivalent would be to make sshd log authentications to a shipped stream (M2).
**Appendix.** What auditd would and would not buy here, and whether it is a hard requirement, is analysed in `cis-audit-and-mac.md`.

#### 4.1.10 Ensure session initiation information is collected — `L2`, scored

**Requires.** Audit rules matching `/var/run/utmp`, `/var/log/wtmp`, `/var/log/btmp`.
**Status.** `non-compliant`.
**Evidence (verified).** No audit rules and none of those files exist.
**Cost.** large, downstream of auditd.
**Appendix.** What auditd would and would not buy here, and whether it is a hard requirement, is analysed in `cis-audit-and-mac.md`.

#### 4.1.11 Ensure discretionary access control permission modification events are collected — `L2`, scored

**Requires.** Audit rules for `chmod`, `chown`, `fchmod*`, `setxattr` etc.
**Status.** `non-compliant`.
**Evidence (verified).** No audit rules. These syscalls are available and used (containerd, kubelet and runc chmod/chown constantly under `/var/lib` and `/run`).
**Cost.** large, downstream of auditd. Be aware that auditing every DAC change on a container host is extremely noisy; the benchmark's rule set is written for a general-purpose host.
**Appendix.** What auditd would and would not buy here, and whether it is a hard requirement, is analysed in `cis-audit-and-mac.md`.

#### 4.1.12 Ensure unsuccessful unauthorized file access attempts are collected — `L2`, scored

**Requires.** Audit rules for `EACCES`/`EPERM` on file access.
**Status.** `non-compliant`.
**Evidence (verified).** No audit rules.
**Cost.** large, downstream of auditd, and noisy on this workload.
**Appendix.** What auditd would and would not buy here, and whether it is a hard requirement, is analysed in `cis-audit-and-mac.md`.

#### 4.1.13 Ensure use of privileged commands is collected — `L2`, scored

**Requires.** Audit rules for every SUID/SGID executable.
**Status.** `non-compliant` — no audit rules; the rule set would be empty here.
**Evidence (verified).** There are no SUID/SGID files in the image (`cpio -itv` shows no `s`/`S` bits; see 6.1.13/6.1.14), so a generated rule set would contain nothing to watch.
**Cost.** large as a whole (auditd), but the control's content is void for this image.
**Appendix.** What auditd would and would not buy here, and whether it is a hard requirement, is analysed in `cis-audit-and-mac.md`.

#### 4.1.14 Ensure successful file system mounts are collected — `L2`, scored

**Requires.** Audit rules for `mount`/`umount`.
**Status.** `non-compliant`.
**Evidence (verified).** No audit rules. Mounts genuinely happen: `uinit` mounts the cgroup2 hierarchy and three tmpfs mounts (`cmd/uinit/main.go:100-128`), and containerd mounts per container.
**Cost.** large, downstream of auditd.
**Appendix.** What auditd would and would not buy here, and whether it is a hard requirement, is analysed in `cis-audit-and-mac.md`.

#### 4.1.15 Ensure file deletion events by users are collected — `L2`, scored

**Requires.** Audit rules for `unlink`, `unlinkat`, `rename`, `renameat`.
**Status.** `non-compliant`.
**Evidence (verified).** No audit rules.
**Cost.** large, downstream of auditd, and noisy on a container host.
**Appendix.** What auditd would and would not buy here, and whether it is a hard requirement, is analysed in `cis-audit-and-mac.md`.

#### 4.1.16 Ensure changes to system administration scope (sudoers) is collected — `L2`, scored

**Requires.** Audit rules watching `/etc/sudoers` and `/etc/sudoers.d`.
**Status.** `not applicable` — there is no `sudo` and no sudoers file.
**Evidence (verified).** No `sudo`, no `/etc/sudoers`, no `/etc/sudoers.d` in the image.
**Cost.** none as written. There are no privilege-escalation paths from a non-root user because there are no non-root users who can log in.
**Appendix.** What auditd would and would not buy here, and whether it is a hard requirement, is analysed in `cis-audit-and-mac.md`.

#### 4.1.17 Ensure system administrator actions (sudolog) are collected — `L2`, scored

**Requires.** Audit rules watching `/var/log/sudo.log`.
**Status.** `not applicable` — no sudo, no sudo log.
**Evidence (verified).** As 4.1.16.
**Cost.** none as written.
**Appendix.** What auditd would and would not buy here, and whether it is a hard requirement, is analysed in `cis-audit-and-mac.md`.

#### 4.1.18 Ensure kernel module loading and unloading is collected — `L2`, scored

**Requires.** Audit rules for `init_module`, `delete_module`, `finit_module`.
**Status.** `not applicable` — modules cannot be loaded.
**Evidence (verified).** `# CONFIG_MODULES is not set` in the resolved config, so the syscalls are not implemented and `modprobe`/`insmod` cannot work (the `bb` applets exist but would fail).
**Cost.** none. This is a case where "not applicable" is a stronger guarantee than a rule.
**Appendix.** What auditd would and would not buy here, and whether it is a hard requirement, is analysed in `cis-audit-and-mac.md`.

#### 4.1.19 Ensure the audit configuration is immutable — `L2`, scored

**Requires.** `-e 2` at the end of the audit rules, making the configuration immutable until reboot.
**Status.** `non-compliant` — there is no audit configuration to make immutable.
**Evidence (verified).** As 4.1.1.1.
**Cost.** large, downstream of auditd. If auditd is adopted, `-e 2` is trivial and fits the reboot-every-boot model well.
**Appendix.** What auditd would and would not buy here, and whether it is a hard requirement, is analysed in `cis-audit-and-mac.md`.

#### 4.2.1.1 Ensure rsyslog is installed — `L1`, scored

**Requires.** `rsyslog` is installed.
**Status.** `non-compliant`.
**Evidence (verified).** No `rsyslog`, no `syslogd`, no `journald` in the image; no package manager to install one.
**Cost.** moderate — rsyslog is C and would need a static build, or a Go syslog client could cover the shipping half. M2 already plans log shipping (`docs/roadmap.md`, M2), so the decision is which component, not whether.

#### 4.2.1.2 Ensure rsyslog Service is enabled — `L1`, scored

**Requires.** rsyslog runs at boot.
**Status.** `non-compliant`.
**Evidence (verified).** Nothing starts a log daemon; `uinit` redirects each daemon's stdout/stderr to a file under `/tmp` (`cmd/uinit/main.go:300-312`).
**Cost.** moderate, downstream of 4.2.1.1: one `background()` call.

#### 4.2.1.3 Ensure logging is configured — `L1`, not scored

**Requires.** `/etc/rsyslog.conf` and `/etc/rsyslog.d/*.conf` capture auth, cron, mail, kern and other facilities with a suitable retention.
**Status.** `partial` — there is logging, but not syslog-configured logging.
**Evidence (verified).** `uinit` writes `sshd.log`, `containerd.log` and `kubelet.log` under `/tmp` (`cmd/uinit/main.go:44-46,300`), the kernel console goes to the serial port, and the test harness captures it. There is no facility selection, no rotation and no persistence; on reboot every log is gone by design.
**Cost.** moderate. A Go log shipper in `uinit` (or a small sidecar) would cover the intent without rsyslog; that is M2's shape.

#### 4.2.1.4 Ensure rsyslog default file permissions configured — `L1`, scored

**Requires.** `$FileCreateMode 0640` or more restrictive in rsyslog configuration.
**Status.** `not applicable` — no rsyslog.
**Evidence (verified).** No rsyslog configuration exists.
**Cost.** none as written; the actual log-file permission problem is 4.2.3.

#### 4.2.1.5 Ensure rsyslog is configured to send logs to a remote log host — `L1`, scored

**Requires.** A remote log host (`*.* @@host`) is configured.
**Status.** `non-compliant`.
**Evidence (verified).** No syslog client and no remote destination anywhere in the image or `uinit`. `docs/roadmap.md` M2 lists "log shipping" as planned and unbuilt ("Logs on tmpfs are lost on reboot unless shipped off-box with buffering").
**Cost.** moderate — the highest-value logging item for this design, because it is the only way a node's logs survive the reboot that is guaranteed to happen. It is already on the roadmap.

#### 4.2.1.6 Ensure remote rsyslog messages are only accepted on designated log hosts. — `L1`, not scored

**Requires.** `$ModLoad imtcp`/`imudp` are not enabled unless the host is a log host.
**Status.** `not applicable` — no rsyslog, and the node must never be a log host.
**Evidence (verified).** No rsyslog.
**Cost.** none.

#### 4.2.2.1 Ensure journald is configured to send logs to rsyslog — `L1`, scored

**Requires.** `ForwardToSyslog=yes` in `journald.conf`.
**Status.** `not applicable` — there is no systemd and no journald.
**Evidence (verified).** No `systemd-journald`, no `/etc/systemd/journald.conf`.
**Cost.** none.

#### 4.2.2.2 Ensure journald is configured to compress large log files — `L1`, scored

**Requires.** `Compress=yes`.
**Status.** `not applicable` — no journald.
**Evidence (verified).** As 4.2.2.1.
**Cost.** none.

#### 4.2.2.3 Ensure journald is configured to write logfiles to persistent disk — `L1`, scored

**Requires.** `Storage=persistent`.
**Status.** `infeasible by design` — there is no persistent disk, and no journald.
**Evidence (verified).** As 4.2.2.1; strict RAM-only forbids the persistent store this control asks for.
**Cost.** **conflicts with the design.** The correct replacement is remote shipping (4.2.1.5).

#### 4.2.3 Ensure permissions on all logfiles are configured — `L1`, scored

**Requires.** Log files are mode 0640 or more restrictive and not world-readable.
**Status.** `non-compliant`.
**Evidence (verified).** `uinit` creates each daemon log with `os.Create` (`cmd/uinit/main.go:300`), i.e. mode 0666 masked by the inherited umask `0022` (`linux/fs/fs_struct.c:151-156`), which yields **0644 — world-readable**. `/var/log` itself is created 0777 by u-root (`u-root/pkg/libinit/root_linux.go:122`). The pod-log tmpfs at `/var/log/pods` (`cmd/uinit/main.go:128`) is mounted by `uinit` and then filled by kubelet and containerd, so its contents are not under the node's file-mode control.
**Cost.** trivial — `os.OpenFile(path, O_CREATE|O_WRONLY|O_TRUNC, 0o640)` and a `syscall.Umask(0o027)` in `uinit`.

#### 4.3 Ensure logrotate is configured — `L1`, not scored

**Requires.** `logrotate` is installed and configured (or log rotation is otherwise handled).
**Status.** `not applicable` — with no persistent log store, there is nothing to rotate between boots.
**Evidence (verified).** No `logrotate` in the image; logs live under `/tmp` on tmpfs and are discarded on reboot.
**Cost.** none. On a long-running node, unbounded `/tmp` logs are a real exhaustion risk, but the answer is size-capped tmpfs or shipping, not logrotate. Worth noting under M2.

### 5 Access, Authentication and Authorization

The §5.2 entries all turn on one fact: **there is no `sshd_config`**. u-root's sshd
is a Go program configured only by four flags (`u-root/cmds/core/sshd/sshd.go:41-48`)
and it reads no configuration file. Where a control's property happens to hold, it
holds because of how that program is written, and the entry says so; where it does
not, closing it means changing u-root (a cloned dependency) or replacing sshd.

The §5.3–5.4 password entries all turn on another: **there is no `/etc/shadow`**,
no PAM and no local login. Those controls are `not applicable` — the node has no
password authentication to configure, not a hardened one.

#### 5.1.1 Ensure cron daemon is enabled — `L1`, scored

**Requires.** `cron`/`crond` is installed and running.
**Status.** `not applicable` — there is no cron and no scheduled work.
**Evidence (verified).** No `cron`, `crond`, `atd` or `systemd-timers` in the image; no `/etc/crontab` or `/etc/cron.*`.
**Cost.** none. Adding cron to a diskless node would create a persistence mechanism for no task; if a periodic job is ever needed, the right home is `uinit` or a DaemonSet.

#### 5.1.2 Ensure permissions on /etc/crontab are configured — `L1`, scored

**Requires.** `/etc/crontab` is 0600 root:root.
**Status.** `not applicable` — the file does not exist.
**Evidence (verified).** Absent from the image.
**Cost.** none.

#### 5.1.3 Ensure permissions on /etc/cron.hourly are configured — `L1`, scored

**Requires.** The directory is 0700 root:root.
**Status.** `not applicable` — absent.
**Evidence (verified).** Absent from the image.
**Cost.** none.

#### 5.1.4 Ensure permissions on /etc/cron.daily are configured — `L1`, scored

**Requires.** 0700 root:root.
**Status.** `not applicable` — absent.
**Evidence (verified).** Absent from the image.
**Cost.** none.

#### 5.1.5 Ensure permissions on /etc/cron.weekly are configured — `L1`, scored

**Requires.** 0700 root:root.
**Status.** `not applicable` — absent.
**Evidence (verified).** Absent from the image.
**Cost.** none.

#### 5.1.6 Ensure permissions on /etc/cron.monthly are configured — `L1`, scored

**Requires.** 0700 root:root.
**Status.** `not applicable` — absent.
**Evidence (verified).** Absent from the image.
**Cost.** none.

#### 5.1.7 Ensure permissions on /etc/cron.d are configured — `L1`, scored

**Requires.** 0700 root:root.
**Status.** `not applicable` — absent.
**Evidence (verified).** Absent from the image.
**Cost.** none.

#### 5.1.8 Ensure at/cron is restricted to authorized users — `L1`, scored

**Requires.** `/etc/cron.allow` exists (or `at.allow`), and `cron.deny`/`at.deny` are empty/absent.
**Status.** `not applicable` — neither `at` nor `cron` is installed.
**Evidence (verified).** No `at`, `atd`, `cron` or allow/deny files in the image.
**Cost.** none.

#### 5.2.1 Ensure permissions on /etc/ssh/sshd_config are configured — `L1`, scored

**Requires.** `sshd_config` is 0600 root:root.
**Status.** `not applicable` — the file does not exist, because sshd has no configuration file.
**Evidence (verified).** No `/etc/ssh` in the base image at all; the harness splices only `authorized_keys` and `host_rsa` (`scripts/test-cluster.sh:448-450`). u-root's sshd takes `-keys`, `-privatekey`, `-ip`, `-port`, `-d` and reads nothing else (`u-root/cmds/core/sshd/sshd.go:41-48`).
**Cost.** none for *this* control, but the absence is the reason 5.2.5–5.2.23 are what they are. An auditor would score it a fail; the substantive finding is "no sshd_config exists".

#### 5.2.2 Ensure permissions on SSH private host key files are configured — `L1`, scored

**Requires.** Private host keys are 0600 root:root.
**Status.** `partial` — true for the test harness keys, and there is no production path.
**Evidence (verified).** The base image contains no host key. `scripts/test-cluster.sh:188` runs `ssh-keygen -q -t rsa -b 2048 -N '' -f "$SSH/host_rsa"`, which creates it mode 0600, and `:450` splices it to `/etc/ssh/host_rsa`; `uinit` starts sshd with that path (`cmd/uinit/main.go:84-85`). In production the file is absent, so sshd exits — there is no key-generation step and no key-rotation story.
**Cost.** moderate — generate a per-boot host key in `uinit` (trivial) and decide whether sshd belongs in production at all (§10, question 2). A per-boot key also removes host-key persistence, which is the right shape here.

#### 5.2.3 Ensure permissions on SSH public host key files are configured — `L1`, scored

**Requires.** Public host keys are 0644 root:root.
**Status.** `not applicable` — no `.pub` file is placed in the guest.
**Evidence (verified).** `ssh-keygen` writes `host_rsa.pub` in the harness work directory, but only `host_rsa` is spliced (`scripts/test-cluster.sh:448-450`); u-root's sshd derives the public key from the private key and never reads a `.pub`.
**Cost.** none.

#### 5.2.4 Ensure SSH Protocol is set to 2 — `L1`, scored

**Requires.** `Protocol 2`.
**Status.** `comply` — by construction.
**Evidence (verified).** u-root's sshd is built on `golang.org/x/crypto/ssh` (`sshd.go:20`), which implements SSH-2 only; there is no protocol-1 code to enable.
**Cost.** none.

#### 5.2.5 Ensure SSH LogLevel is appropriate — `L1`, scored

**Requires.** `LogLevel INFO` or `VERBOSE`, so authentication events are recorded.
**Status.** `partial` — authentication events are logged, but there is no level and no configuration.
**Evidence (verified).** `sshd.go` logs handshake failures (`log.Printf("failed to handshake: %v", err)`) and successful logins with the key fingerprint (`sshd.go:314`), to the file `uinit` redirects it to (`/tmp/sshd.log`, `cmd/uinit/main.go:44,84`). There is no `-T` output and no log level to audit.
**Cost.** cheap to call this satisfied in substance; making it auditable would need a change to u-root's sshd. The bigger gap is that the log is on tmpfs (4.2.1.5).

#### 5.2.6 Ensure SSH X11 forwarding is disabled — `L2`, scored

**Requires.** `X11Forwarding no`.
**Status.** `comply` — by construction.
**Evidence (verified).** `session()` accepts only channel type `session` and rejects everything else (`sshd.go:157-159`); there is no X11 channel handler and no `xauth` in the image.
**Cost.** none.

#### 5.2.7 Ensure SSH MaxAuthTries is set to 4 or less — `L1`, scored

**Requires.** `MaxAuthTries 4`.
**Status.** `non-compliant` — the effective value is the library default, 6.
**Evidence (verified).** `sshd.go:267-280` constructs `ssh.ServerConfig` without setting `MaxAuthTries`; `vendor/golang.org/x/crypto/ssh/server.go:261-262` sets it to 6 when zero.
**Cost.** cheap but invasive — one field in u-root's sshd, i.e. a patch to a cloned dependency. Worth folding into a fork if sshd stays.

#### 5.2.8 Ensure SSH IgnoreRhosts is enabled — `L1`, scored

**Requires.** `IgnoreRhosts yes`.
**Status.** `comply` — by construction.
**Evidence (verified).** No rhosts or shosts authentication is implemented; the only auth callback is `PublicKeyCallback` (`sshd.go:267-280`).
**Cost.** none.

#### 5.2.9 Ensure SSH HostbasedAuthentication is disabled — `L1`, scored

**Requires.** `HostbasedAuthentication no`.
**Status.** `comply` — by construction.
**Evidence (verified).** As 5.2.8; there is no hostbased auth method in the server.
**Cost.** none.

#### 5.2.10 Ensure SSH root login is disabled — `L1`, scored

**Requires.** `PermitRootLogin no`.
**Status.** `non-compliant` — and worse than "enabled": every session is root regardless of the username presented.
**Evidence (verified).** The `PublicKeyCallback` checks the key against `authorized_keys` and returns permissions without ever comparing `c.User()` (`sshd.go:267-280`); commands run as `/bin/sh` (`const_unix.go:9`), and the daemon runs as root. There is no user model in the server.
**Cost.** moderate — a real user check, or a non-root sshd, is a change to u-root. The cheaper and better answer is not to run sshd in production.

#### 5.2.11 Ensure SSH PermitEmptyPasswords is disabled — `L1`, scored

**Requires.** `PermitEmptyPasswords no`.
**Status.** `comply` — by construction.
**Evidence (verified).** Password authentication is not configured at all: `ServerConfig` has only a `PublicKeyCallback`, so password auth is unavailable rather than merely restricted (`sshd.go:267-280`).
**Cost.** none.

#### 5.2.12 Ensure SSH PermitUserEnvironment is disabled — `L1`, scored

**Requires.** `PermitUserEnvironment no`.
**Status.** `comply` — by construction.
**Evidence (verified).** `env` requests fall through to the default branch and are rejected (`sshd.go:167-196`), so a client cannot set environment variables.
**Cost.** none.

#### 5.2.13 Ensure only strong Ciphers are used — `L1`, scored

**Requires.** Only strong ciphers (the benchmark lists AES-GCM/ChaCha20 families, no CBC/3DES/RC4).
**Status.** `partial` — the library defaults are strong; there is no configuration to audit or pin.
**Evidence (verified).** `sshd.go:267` sets no `CipherSuites`, so `golang.org/x/crypto/ssh` uses its default preference list (AEAD ciphers: AES-GCM and ChaCha20-Poly1305), which excludes CBC and RC4. There is no `sshd_config` to check and no way to restrict further without patching u-root.
**Cost.** cheap if an explicit list is wanted (a few fields in u-root); none otherwise. Note that "the defaults are good" is a property of the Go library version pinned in `u-root/go.mod`, not a decision this project controls.

#### 5.2.14 Ensure only strong MAC algorithms are used — `L1`, scored

**Requires.** Only strong MACs (HMAC-SHA2, EtM; no MD5/SHA1/umac-64).
**Status.** `partial` — library defaults, no configuration.
**Evidence (verified).** As 5.2.13: no `MACs` field is set, so the x/crypto default list (Encrypt-then-MAC with SHA-2) applies.
**Cost.** as 5.2.13.

#### 5.2.15 Ensure only strong Key Exchange algorithms are used — `L1`, scored

**Requires.** Only strong KEX (curve25519, ECDH, DH group14+; no group1/group1024).
**Status.** `partial` — library defaults, no configuration.
**Evidence (verified).** As 5.2.13: no `KeyExchanges` field is set; x/crypto's default list is curve25519, NIST ECDH and DH group14-sha256.
**Cost.** as 5.2.13.

#### 5.2.16 Ensure SSH Idle Timeout Interval is configured — `L1`, scored

**Requires.** `ClientAliveInterval`/`ClientAliveCountMax` close idle sessions.
**Status.** `non-compliant`.
**Evidence (verified).** u-root's sshd has no keepalive or idle handling — the `session` goroutine has no timers and no deadline (`sshd.go:149-199`).
**Cost.** moderate — a change to u-root, or accept it because sessions are root shells on a trusted test harness. Interacts with 5.4.5, which is the same problem from the shell side.

#### 5.2.17 Ensure SSH LoginGraceTime is set to one minute or less — `L1`, scored

**Requires.** `LoginGraceTime 60`.
**Status.** `non-compliant`.
**Evidence (verified).** There is no handshake deadline: `ssh.NewServerConn` is called synchronously in the accept loop with no `SetDeadline` (`sshd.go:300-313`), so a client can hold a pre-auth connection open indefinitely.
**Cost.** moderate — a deadline around the handshake in u-root. This one is a genuine, cheap-ish robustness fix even for the test path.

#### 5.2.18 Ensure SSH access is limited — `L1`, scored

**Requires.** `AllowUsers`/`AllowGroups`/`DenyUsers`/`DenyGroups` restrict who may log in.
**Status.** `non-compliant`.
**Evidence (verified).** No allow/deny logic exists; any key in `authorized_keys` authenticates, under any requested username (`sshd.go:267-280`).
**Cost.** moderate — a change to u-root, or the better answer: one authorized key per test run and no sshd in production.

#### 5.2.19 Ensure SSH warning banner is configured — `L1`, scored

**Requires.** `Banner /etc/issue.net`.
**Status.** `non-compliant`.
**Evidence (verified).** No banner option in sshd and no `/etc/issue.net` in the image (`sshd.go:41-48`).
**Cost.** moderate (u-root change) and low value for a machine whose only SSH client is the test harness.

#### 5.2.20 Ensure SSH PAM is enabled — `L1`, scored

**Requires.** `UsePAM yes`.
**Status.** `not applicable` — there is no PAM and no password authentication.
**Evidence (verified).** No `/etc/pam.d`, no `libpam`, no `sshd_config`; the only auth method is public key (`sshd.go:267-280`).
**Cost.** none.

#### 5.2.21 Ensure SSH AllowTcpForwarding is disabled — `L2`, scored

**Requires.** `AllowTcpForwarding no`.
**Status.** `comply` — by construction.
**Evidence (verified).** Channel types other than `session` are rejected (`sshd.go:157-159`), so `direct-tcpip` and `forwarded-tcpip` cannot be opened; global requests are discarded (`sshd.go:317`). SFTP is served as a session subsystem, not as forwarding.
**Cost.** none.

#### 5.2.22 Ensure SSH MaxStartups is configured — `L1`, scored

**Requires.** `MaxStartups 10:30:60` or similar.
**Status.** `non-compliant` — no limit exists.
**Evidence (verified).** The accept loop accepts and handshakes connections without any concurrency cap (`sshd.go:300-319`); there is no `MaxStartups` equivalent.
**Cost.** moderate (u-root change). Low priority for a test-only service; relevant if sshd stays in production, together with 5.2.17.

#### 5.2.23 Ensure SSH MaxSessions is set to 4 or less — `L1`, scored

**Requires.** `MaxSessions 4`.
**Status.** `non-compliant`.
**Evidence (verified).** `session()` spawns a goroutine per channel with no count limit (`sshd.go:149-199`).
**Cost.** moderate (u-root change).

#### 5.3.1 Ensure password creation requirements are configured — `L1`, scored

**Requires.** `pwquality`/PAM enforces length and complexity.
**Status.** `not applicable` — there is no PAM and no password authentication.
**Evidence (verified).** No `/etc/pam.d`, no `/etc/security/pwquality.conf`, no `libpwquality` in the image; `/etc/passwd` has two entries with `x` placeholders and there is no `/etc/shadow`.
**Cost.** none. Creating a password policy for accounts that cannot authenticate would be theatre.

#### 5.3.2 Ensure lockout for failed password attempts is configured — `L1`, not scored

**Requires.** `pam_faillock`/`pam_tally2` locks accounts after failures.
**Status.** `not applicable` — no password authentication.
**Evidence (verified).** As 5.3.1.
**Cost.** none.

#### 5.3.3 Ensure password reuse is limited — `L1`, not scored

**Requires.** `pam_pwhistory` remembers previous passwords.
**Status.** `not applicable` — no passwords.
**Evidence (verified).** As 5.3.1.
**Cost.** none.

#### 5.3.4 Ensure password hashing algorithm is SHA-512 — `L1`, not scored

**Requires.** `ENCRYPT_METHOD SHA512` in `login.defs`/PAM.
**Status.** `not applicable` — no passwords exist to hash.
**Evidence (verified).** No `/etc/login.defs`, no `/etc/shadow`; the `x` in `configs/node/passwd` is a placeholder, not a hash.
**Cost.** none.

#### 5.4.1.1 Ensure password expiration is 365 days or less — `L1`, scored

**Requires.** `PASS_MAX_DAYS 365` and per-account aging.
**Status.** `not applicable` — no `/etc/shadow`, no aging metadata.
**Evidence (verified).** No `/etc/shadow` in the image; `chage -l` has nothing to read.
**Cost.** none.

#### 5.4.1.2 Ensure minimum days between password changes is 7 or more — `L1`, scored

**Requires.** `PASS_MIN_DAYS 7`.
**Status.** `not applicable` — no shadow file.
**Evidence (verified).** As 5.4.1.1.
**Cost.** none.

#### 5.4.1.3 Ensure password expiration warning days is 7 or more — `L1`, scored

**Requires.** `PASS_WARN_AGE 7`.
**Status.** `not applicable` — no shadow file.
**Evidence (verified).** As 5.4.1.1.
**Cost.** none.

#### 5.4.1.4 Ensure inactive password lock is 30 days or less — `L1`, scored

**Requires.** `INACTIVE 30` / `useradd -f 30`.
**Status.** `not applicable` — no shadow file.
**Evidence (verified).** As 5.4.1.1.
**Cost.** none.

#### 5.4.1.5 Ensure all users last password change date is in the past — `L1`, scored

**Requires.** No account has a future last-change date.
**Status.** `not applicable` — no shadow file.
**Evidence (verified).** As 5.4.1.1.
**Cost.** none.

#### 5.4.2 Ensure system accounts are secured — `L1`, scored

**Requires.** System accounts (UID < 1000, other than root) have no login shell and are locked.
**Status.** `comply` — by construction.
**Evidence (verified).** `configs/node/passwd` has exactly two entries: `root` (UID 0, `/bin/sh`) and `nobody` (UID 65534, `/bin/false`, `/nonexistent`); `configs/node/group` has `root` and `nobody`. There are no other accounts and no `/etc/shadow` to lock.
**Cost.** none.

#### 5.4.3 Ensure default group for the root account is GID 0 — `L1`, scored

**Requires.** root's primary group is GID 0.
**Status.** `comply`.
**Evidence (verified).** `configs/node/passwd:1` is `root:x:0:0:...` and `configs/node/group:1` is `root:x:0:`.
**Cost.** none.

#### 5.4.4 Ensure default user umask is 027 or more restrictive — `L1`, scored

**Requires.** The default umask for interactive and daemon contexts is 027.
**Status.** `non-compliant`.
**Evidence (verified).** The kernel starts PID 1 with `umask 0022` (`linux/fs/fs_struct.c:151-156`); u-root raises it to 0 only while creating device nodes and restores it (`u-root/pkg/libinit/root_linux.go:192-194`); nothing sets 027. There is no `/etc/profile` or `/etc/login.defs` to read one.
**Cost.** trivial — `syscall.Umask(0o027)` at the top of `uinit`'s `node()` and `controlPlane()`. Worth doing: it affects every file containerd, kubelet and runc create under `/var/lib` and `/var/log`.

#### 5.4.5 Ensure default user shell timeout is 900 seconds or less — `L2`, scored

**Requires.** `TMOUT=900` (or equivalent) closes idle shells.
**Status.** `non-compliant`.
**Evidence (verified).** There is no `/etc/profile`, `/etc/bashrc` or shell startup file at all, and `bb`'s `gosh` has no timeout. The console root shell (see 1.4.3) therefore never times out.
**Cost.** moderate — the shell is started by u-root's init, not by a profile, so this cannot be fixed with an `export TMOUT`. It needs either a different init behaviour or a wrapper shell. Low priority compared with deciding whether that shell should exist.

#### 5.5 Ensure root login is restricted to system console — `L1`, not scored

**Requires.** Root may only log in on the system console (`/etc/securetty`), not remotely.
**Status.** `non-compliant` — root is reachable over the network.
**Evidence (verified).** u-root's sshd authenticates a key and runs `/bin/sh` as root (`sshd.go:267-280`, `const_unix.go:9`), and `uinit` starts it unconditionally (`cmd/uinit/main.go:84-85`). There is no `/etc/securetty` and no login program. (The *console* half of the control is satisfied in the worst way: the console is already an unauthenticated root shell — 1.4.3.)
**Cost.** moderate, and it is the same decision as 5.2.10 and §10 question 2. If sshd is a test-only service, the honest fix is to start it only when a test key is present, or not at all in production.

#### 5.6 Ensure access to the su command is restricted — `L1`, scored

**Requires.** `/etc/pam.d/su` uses `pam_wheel.so`, and the `wheel` group is empty.
**Status.** `comply` — by construction: there is no `su`.
**Evidence (verified).** No `su`, no `sudo`, no `/etc/pam.d` in the image (cpio listing). There is no way to change user identity.
**Cost.** none.

### 6 System Maintenance

#### 6.1.1 Audit system file permissions — `L2`, not scored

**Requires.** The package manager's file-permission database is verified (`rpm -Va`, `dpkg --verify`).
**Status.** `infeasible by design` — there is no package database to verify against.
**Evidence (verified).** No `dpkg`/`rpm` and no package database in the image (see 1.2.1). The equivalent baseline is the image itself: every file in the cpio has a mode and owner and is a build output (`DIT:191-213`). Nothing records or checks that baseline at boot — see 1.3.2, which is the real gap.
**Cost.** **conflicts with the design** as written. The RAM-native equivalent — hash the cpio, compare at boot — is moderate and belongs with 1.3.2.

#### 6.1.2 Ensure permissions on /etc/passwd are configured — `L1`, scored

**Requires.** `/etc/passwd` is 0644 or more restrictive, root:root.
**Status.** `non-compliant` — it is 0664 (group-writable).
**Evidence (verified).** `cpio -itv` reports `-rw-rw-r-- root root etc/passwd`. The mode comes from the checked-out file: `u-root -files` preserves it (`DIT:198`), and git does not store group-write bits, so the image's mode depends on the builder's umask. Owner and group are correct.
**Cost.** trivial — `chmod 0644 configs/node/passwd` and the same for the other spliced files, or set modes explicitly in `DIT`. Also fixes 6.1.4 and tightens `/etc/kubernetes/kubelet.yaml` and the CNI conflist, which are 0664 too.

#### 6.1.3 Ensure permissions on /etc/shadow are configured — `L1`, scored

**Requires.** `/etc/shadow` is 0000/0600, root:shadow.
**Status.** `not applicable` — the file does not exist.
**Evidence (verified).** No `/etc/shadow` in the image.
**Cost.** none. Note that the *absence* of a shadow file is a security property here: the `x` placeholders in `passwd` cannot be resolved, so no password can authenticate.

#### 6.1.4 Ensure permissions on /etc/group are configured — `L1`, scored

**Requires.** `/etc/group` is 0644 or more restrictive, root:root.
**Status.** `non-compliant` — it is 0664.
**Evidence (verified).** `cpio -itv`: `-rw-rw-r-- root root etc/group`, from the same mechanism as 6.1.2 (`DIT:199`).
**Cost.** trivial, same change as 6.1.2.

#### 6.1.5 Ensure permissions on /etc/gshadow are configured — `L1`, scored

**Requires.** `/etc/gshadow` is 0000/0640.
**Status.** `not applicable` — the file does not exist.
**Evidence (verified).** No `/etc/gshadow` in the image.
**Cost.** none.

#### 6.1.6 Ensure permissions on /etc/passwd- are configured — `L1`, scored

**Requires.** The backup file is 0644 or more restrictive.
**Status.** `not applicable` — the backup does not exist (and would not survive a reboot).
**Evidence (verified).** No `/etc/passwd-` in the image.
**Cost.** none.

#### 6.1.7 Ensure permissions on /etc/shadow- are configured — `L1`, scored

**Requires.** The backup is 0000/0600.
**Status.** `not applicable` — absent.
**Evidence (verified).** No `/etc/shadow-`.
**Cost.** none.

#### 6.1.8 Ensure permissions on /etc/group- are configured — `L1`, scored

**Requires.** The backup is 0644 or more restrictive.
**Status.** `not applicable` — absent.
**Evidence (verified).** No `/etc/group-`.
**Cost.** none.

#### 6.1.9 Ensure permissions on /etc/gshadow- are configured — `L1`, scored

**Requires.** The backup is 0000/0640.
**Status.** `not applicable` — absent.
**Evidence (verified).** No `/etc/gshadow-`.
**Cost.** none.

#### 6.1.10 Ensure no world writable files exist — `L1`, scored

**Requires.** No files are world-writable (`find / -xdev -type f -perm -0002`).
**Status.** `partial` — no world-writable *files*, but seven world-writable *directories*.
**Evidence (verified).** `cpio -itv` shows no file with the `o+w` bit (the applet symlinks are `lrwxrwxrwx`, which is normal and irrelevant). At runtime, u-root creates `/buildbin`, `/ubin`, `/env`, `/tcz`, `/lib`, `/usr/lib` and `/var/log` as 0777 (`u-root/pkg/libinit/root_linux.go:115-122`). `/tmp` and `/dev/shm` are 1777, which is expected.
**Cost.** trivial — chmod the seven directories (0755, or 1777 for the shared ones) in `uinit`. The world-writable library directories (`/lib`, `/usr/lib`) are the ones worth fixing regardless of the benchmark, since nothing should be able to drop a library there.

#### 6.1.11 Ensure no unowned files or directories exist — `L1`, scored

**Requires.** Every file has a valid owner.
**Status.** `comply`.
**Evidence (verified).** `cpio -itv` reports `root root` for every entry; u-root creates runtime directories as root.
**Cost.** none.

#### 6.1.12 Ensure no ungrouped files or directories exist — `L1`, scored

**Requires.** Every file has a valid group.
**Status.** `comply`.
**Evidence (verified).** As 6.1.11.
**Cost.** none.

#### 6.1.13 Audit SUID executables — `L1`, not scored

**Requires.** A review of all SUID executables, with none unexplained.
**Status.** `comply` — there are none.
**Evidence (verified).** `cpio -itv` shows no file with the setuid bit; `bb` and the four standalone binaries are mode 0775/0755. There is nothing to audit.
**Cost.** none. Worth re-checking if anything is ever added via `-files`.

#### 6.1.14 Audit SGID executables — `L1`, not scored

**Requires.** A review of all SGID executables.
**Status.** `comply` — there are none.
**Evidence (verified).** As 6.1.13; no setgid bit in the cpio.
**Cost.** none.

### 6.2 User and Group Settings

#### 6.2.1 Ensure password fields are not empty — `L1`, scored

**Requires.** No account has an empty password field.
**Status.** `comply`.
**Evidence (verified).** `configs/node/passwd:1-2` both have `x` in the password field.
**Cost.** none.

#### 6.2.2 Ensure no legacy "+" entries exist in /etc/passwd — `L1`, scored

**Requires.** No NIS-style `+` entries.
**Status.** `comply`.
**Evidence (verified).** `configs/node/passwd` has two ordinary entries and no `+`.
**Cost.** none.

#### 6.2.3 Ensure no legacy "+" entries exist in /etc/shadow — `L1`, scored

**Requires.** No `+` entries in the shadow file.
**Status.** `comply` — the file does not exist, so it has no entries.
**Evidence (verified).** No `/etc/shadow` in the image.
**Cost.** none.

#### 6.2.4 Ensure no legacy "+" entries exist in /etc/group — `L1`, scored

**Requires.** No `+` entries in the group file.
**Status.** `comply`.
**Evidence (verified).** `configs/node/group` has two ordinary entries and no `+`.
**Cost.** none.

#### 6.2.5 Ensure root is the only UID 0 account — `L1`, scored

**Requires.** Exactly one account has UID 0.
**Status.** `comply`.
**Evidence (verified).** `configs/node/passwd:1` is the only UID 0 entry; the other is 65534.
**Cost.** none.

#### 6.2.6 Ensure root PATH Integrity — `L1`, scored

**Requires.** Root's `PATH` contains no empty components, no `.`, and no directories writable by non-root.
**Status.** `non-compliant` — two world-writable directories are on root's `PATH`.
**Evidence (verified).** `u-root/pkg/libinit/root_linux.go:218` sets
`PATH=/go/bin/linux_amd64:/go/bin:/go/pkg/tool/linux_amd64:/ubin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/bin:/usr/local/sbin:/buildbin:/bbin`,
and `:115-116` creates `/buildbin` and `/ubin` mode **0777**. Any process can therefore drop an executable that root will run by name.
**Cost.** trivial — chmod those two to 0755 (they are populated by root at build time; nothing needs to write them at runtime), or drop them from `PATH`. This is one of the more consequential trivial fixes in the document, because uinit and the daemons run as root.

#### 6.2.7 Ensure all users' home directories exist — `L1`, scored

**Requires.** Every account's home directory exists.
**Status.** `non-compliant`.
**Evidence (verified).** root's home is `/root` (`configs/node/passwd:1`) and `nobody`'s is `/nonexistent` (`:2`); neither directory is in the image (cpio listing has no `/root` and no `/nonexistent`).
**Cost.** trivial — `mkdir /root 0700` in `uinit` (or in the cpio), and change `nobody`'s home to `/nonexistent` only in the sense that the benchmark expects it to exist; the conventional fix is to leave `nobody` alone and document it.

#### 6.2.8 Ensure users' home directories permissions are 750 or more restrictive — `L1`, scored

**Requires.** Home directories are 0750 or more restrictive.
**Status.** `non-compliant` — there are no home directories to have permissions.
**Evidence (verified).** As 6.2.7.
**Cost.** trivial once 6.2.7 is fixed: `mkdir -m 0700 /root` satisfies both.

#### 6.2.9 Ensure users own their home directories — `L1`, scored

**Requires.** Each home directory is owned by its user.
**Status.** `non-compliant` — the directories do not exist.
**Evidence (verified).** As 6.2.7.
**Cost.** trivial, together with 6.2.7/6.2.8 (root:root owns `/root`).

#### 6.2.10 Ensure users' dot files are not group or world writable — `L1`, scored

**Requires.** No user dot file is group- or world-writable.
**Status.** `not applicable` — there are no home directories and therefore no dot files.
**Evidence (verified).** No `/root`, no `/home`; nothing to hold a dot file.
**Cost.** none. Would become live if 6.2.7 is fixed and anything writes to `/root`.

#### 6.2.11 Ensure no users have .forward files — `L1`, scored

**Requires.** No `.forward` files.
**Status.** `comply` — no home directories, no mail system, no `.forward`.
**Evidence (verified).** As 6.2.10.
**Cost.** none.

#### 6.2.12 Ensure no users have .netrc files — `L1`, scored

**Requires.** No `.netrc` files.
**Status.** `comply`.
**Evidence (verified).** No home directories in the image, so no `.netrc`.
**Cost.** none.

#### 6.2.13 Ensure users' .netrc Files are not group or world accessible — `L1`, scored

**Requires.** Any `.netrc` is 0600.
**Status.** `comply` — there are none.
**Evidence (verified).** As 6.2.12.
**Cost.** none.

#### 6.2.14 Ensure no users have .rhosts files — `L1`, scored

**Requires.** No `.rhosts` files.
**Status.** `comply`.
**Evidence (verified).** No home directories, no rhosts authentication (5.2.8).
**Cost.** none.

#### 6.2.15 Ensure all groups in /etc/passwd exist in /etc/group — `L1`, scored

**Requires.** Every GID referenced in `passwd` has an entry in `group`.
**Status.** `comply`.
**Evidence (verified).** GIDs 0 and 65534 in `configs/node/passwd` both exist in `configs/node/group`.
**Cost.** none.

#### 6.2.16 Ensure no duplicate UIDs exist — `L1`, scored

**Requires.** No two accounts share a UID.
**Status.** `comply`.
**Evidence (verified).** UIDs 0 and 65534, distinct.
**Cost.** none.

#### 6.2.17 Ensure no duplicate GIDs exist — `L1`, scored

**Requires.** No two groups share a GID.
**Status.** `comply`.
**Evidence (verified).** GIDs 0 and 65534, distinct.
**Cost.** none.

#### 6.2.18 Ensure no duplicate user names exist — `L1`, scored

**Requires.** User names are unique.
**Status.** `comply`.
**Evidence (verified).** `root`, `nobody`.
**Cost.** none.

#### 6.2.19 Ensure no duplicate group names exist — `L1`, scored

**Requires.** Group names are unique.
**Status.** `comply`.
**Evidence (verified).** `root`, `nobody`.
**Cost.** none.

#### 6.2.20 Ensure shadow group is empty — `L1`, scored

**Requires.** No user is in the `shadow` group.
**Status.** `comply` — there is no `shadow` group.
**Evidence (verified).** `configs/node/group` has only `root` and `nobody`; there is no `/etc/shadow` for a shadow group to protect.
**Cost.** none.

---

## 6. The cheapest high-value set

Five changes close roughly **25 controls** for well under a day's work, and every
one of them is a genuine improvement rather than a checkbox. They are listed in
order of value per line changed.

### 6.1 One sysctl loop in `uinit` — 6 controls, plus 1 with a kernel line

`cmd/uinit/main.go` already has `write(path, content)` (`:335`). A loop over the
following would close **3.1.2, 3.2.2, 3.2.3, 3.2.4, 3.2.7, 3.2.9**, and with
`CONFIG_SYN_COOKIES=y` in `configs/k4s-tiny.config`, **3.2.8**:

```
net.ipv4.conf.all.send_redirects=0          net.ipv4.conf.default.send_redirects=0
net.ipv4.conf.all.accept_redirects=0        net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.secure_redirects=0        net.ipv4.conf.default.secure_redirects=0
net.ipv4.conf.all.log_martians=1            net.ipv4.conf.default.log_martians=1
net.ipv4.conf.all.rp_filter=1               net.ipv4.conf.default.rp_filter=1
net.ipv6.conf.all.accept_ra=0               net.ipv6.conf.default.accept_ra=0
net.ipv4.tcp_syncookies=1
```

This is the single best return in the document. It needs no new dependency, no
new binary and no policy decision, except the `rp_filter` caveat in 3.2.7 and the
`ip_forward` exception in 3.1.1.

### 6.2 Mount options and directory modes — 7–10 controls

Remount `/tmp` and `/dev/shm` with `nodev,nosuid,noexec`, mount a tmpfs on
`/var/tmp` with the same options, and chmod the u-root runtime directories:

- **1.1.3, 1.1.4, 1.1.5** (`/tmp`), **1.1.15, 1.1.16, 1.1.17** (`/dev/shm`);
- **1.1.8, 1.1.9, 1.1.10** if `/var/tmp` is created as a tmpfs;
- **1.1.21** and part of **6.1.10** by chmod'ing `/ubin`, `/buildbin`, `/lib`,
  `/usr/lib`, `/var/log`, `/env`, `/tcz` from 0777.

The mount work is three `mount` calls in `node()` (two remounts and one new tmpfs). Note the one real trade-off:
`noexec` on `/tmp` changes what workloads may do; decide that deliberately.

### 6.3 File modes and umask — 4 controls

- `chmod 0644 configs/node/passwd` and `configs/node/group` (or set the modes in
  `DIT`) closes **6.1.2** and **6.1.4**, and stops the image's `/etc` modes from
  depending on the builder's umask.
- Creating the daemon logs with mode 0640 instead of `os.Create`'s 0666, and
  setting `syscall.Umask(0o027)` in `uinit`, closes **4.2.3** and **5.4.4**.

### 6.4 A home directory for root — 3 controls

`mkdir -m 0700 /root` (and, if desired, a decision about `nobody`'s
`/nonexistent`) closes **6.2.7, 6.2.8, 6.2.9**. Trivial, and it removes a class
of "missing home" surprises for anything that writes to `$HOME`.

### 6.5 Take the world-writable directories off root's `PATH` — 1 control

Chmod `/ubin` and `/buildbin` to 0755 (or drop them from the `PATH` u-root sets at
`u-root/pkg/libinit/root_linux.go:218`) closes **6.2.6**. This is the same chmod
as §6.2; it is called out separately because it is the one with a clear privilege
consequence: root resolves executables through writable directories.

### 6.6 The highest-value change that closes no control: take sshd off the production path

sshd is a test instrument (`scripts/test-cluster.sh:181-191` exists so the
harness can read files out of the guest; `docs/testing.md` says so). It is
started unconditionally by `uinit`, listens on `0.0.0.0:2022`, and grants root to
any key in `authorized_keys`. Starting it only when `/etc/ssh/authorized_keys`
exists — or replacing it with a one-shot command channel — would remove the
node's only network-facing authentication surface. That does not move a CIS
number the way §6.1 does, but it is worth more than most of the controls that do.

**This is decision D2.** sshd is recorded as a test instrument to be gated behind
a build flag or the spliced key material; D2 carries the projection of which
controls flip when the gate lands. No status above changes until it does.

---

## 7. Not worth doing

### 7.1 Infeasible by design (7 controls)

These conflict with a locked decision (strict RAM-only, no package manager) and
should be recorded as documented exceptions, not worked around:

| Controls | Why |
| --- | --- |
| 1.1.6, 1.1.7, 1.1.11, 1.1.12, 1.1.13 | "Separate partition" requires a disk. The RAM-native equivalents are size-capped tmpfs mounts and, for `/var/log`, shipping logs off-box. |
| 4.2.2.3 | "journald writes to persistent disk" requires a persistent disk and systemd. Remote shipping is the replacement. |
| 6.1.1 | "Verify system file permissions against the package database" requires a package database. The cpio hash is the stronger baseline; verifying it at boot is the real control (1.3.2), and it is cheap. |

### 7.2 Expensive but possible — and worth pricing honestly

| Family | Controls | Cost | Judgement |
| --- | --- | --- | --- |
| auditd | 4.1.1.1–4.1.7, 4.1.9–4.1.15, 4.1.19 (17 non-compliant) | **large**: `CONFIG_AUDIT`/`AUDITSYSCALL`, a C audit daemon not in the image, a rule set, and a log destination that is not a disk | The kernel option is cheap; the daemon and the destination are not. On a container host the rule sets in 4.1.11/4.1.12/4.1.15 are extremely noisy, and the logs die with the reboot unless shipped. Do 4.2.1.5 (remote shipping) first — it is the same problem with a better cost/benefit. |
| LSM | 1.6.1.1, 1.6.2.2, 1.6.2.3, 1.6.2.6, 1.6.3.2 (5) | **large**: `CONFIG_SECURITY`, one LSM, policy, loader, relabel step | The only expensive item that changes the security posture rather than the score. Seccomp + namespaces already confine containers; an LSM would confine the node's own root processes (`uinit`, `containerd`, `kubelet`, `runc`, `sshd`). Decide once, not per control. |
| Firewall | 3.5.1.1–3.5.1.4, 3.5.2.1–3.5.2.4, 3.5.3 (9) | **moderate**: ship an nftables/iptables-nft binary, write a policy, keep it out of the CNI's way | The CNI (Cilium especially) owns firewall state on this node. A second owner is a bug factory. If a host firewall is required, define the boundary first (see question 6). |
| Log shipping | 4.2.1.1, 4.2.1.2, 4.2.1.5 (3 non-compliant) | **moderate**: a Go shipper in `uinit` or a small DaemonSet | Already M2. Highest-value logging item, because it is the only way logs survive the reboot the design guarantees. |

### 7.3 Not worth doing at all

| Controls | Why not |
| --- | --- |
| 1.7.1.1, 1.7.1.2, 1.7.1.3 (banners) | The console is a root shell, not a login prompt; sshd has no banner option. A banner would be displayed to nobody, or would require patching a test-only daemon. |
| 5.1.1–5.1.8 (cron) | No scheduled work exists. Adding cron to an immutable node creates a persistence mechanism for nothing. |
| 3.3.x (TCP wrappers) | A libc-era mechanism with no inetd and no libwrap consumer; it cannot wrap a Go SSH server. |
| 1.3.1 (AIDE) | A file-integrity database on a machine where every file is re-created from the image at boot detects only runtime tampering, which shipping logs and a read-only root would cover better. 1.3.2 (verify the image) is the real control. |
| 1.1.14, 6.2.10–6.2.14 (home/dot files) | No home directories, no users, no mail. Creating `/root` (6.4 above) is enough. |
| 5.3.x, 5.4.1.x (PAM/password policy) | No PAM, no shadow, no password authentication. Compliance here would mean building an authentication system the node does not need. |
| 1.4.x (bootloader) | There is no bootloader. The iPXE trust model is the real analogue and lives in the roadmap's open risks. |

---

## 8. Adjacent benchmarks

Two other CIS benchmarks are adjacent to this system. One is now assessed; the
other is not.

**CIS Kubernetes Benchmark.** This was a follow-up in the first edition of this
document. It is now the second benchmark of record (D1) and is assessed in §11,
for the worker node only: 27 controls, their evidence, and a tally of their own.

**CIS Docker Benchmark / containerd.** The runtime is containerd, not Docker,
and the brief for this work refers to "CIS containerd/Docker benchmarks" as
existing. I did not verify an edition or control list for a CIS containerd
benchmark and did not assess either; recording that honestly is better than
naming a version I have not seen.

The **Linux host** benchmark assessed in §5 is the least specific of the three.
The two assessments do not cover for each other: a control that is void on the
host because there is no systemd (1.4.x, 5.1.x, 5.2.x) is not repaired by the
Kubernetes benchmark, which assumes the same systemd unit model — §11's 4.1.1 is
void for exactly the reason 1.4.1 is.

---

## 9. What I could not determine

These are gaps in *this assessment*, distinct from gaps in the node.

1. **Boot-time kernel defaults.** 1.5.2 (NX) and 1.5.3 (ASLR) are marked
   `comply` from the kernel source and resolved config, not from a running guest.
   A boot with `sysctl kernel.randomize_va_space` and `grep nx /proc/cpuinfo`
   would settle them. I did not boot (the task forbids it).
2. **The exact algorithm defaults of the pinned SSH library.** 5.2.13–5.2.15 are
   `partial` because no cipher/MAC/KEX list is configured. Whether the Go
   library's defaults meet the benchmark's list depends on the version resolved in
   `u-root/go.mod`; I verified the absence of configuration, not the full
   negotiated set.
3. **Whether any real workload execs from `/tmp`.** This decides whether 1.1.5's
   `noexec` is free or a breakage. Nothing in the image or `examples/` does; a GPU
   node's setup scripts might.
4. **Multi-node forwarding.** 3.1.1 is `comply` as built, but the test cluster is
   single-node. Whether flannel host-gw needs `ip_forward=1` here (it does for
   cross-node traffic) and whether anything sets it in a real deployment is not
   exercised by any test in this repository.
5. **The official PDF.** The copy used came from third-party mirrors and its hash
   does not match the hash NIST publishes for its own copy (see
   `cis/SOURCES.md`). The edition and control set are corroborated three ways,
   but I cannot call the copy CIS-attested.
6. **A CIS containerd benchmark edition.** Not established (see §8).
7. **How an auditor would score the 59 `not applicable` items.** If the scoring
   profile counts them as failures, the effective score is much worse than the
   tally suggests. That is a reporting decision, not a technical one — and it is
   now settled by D3, which reports the five statuses and no percentage.
8. **The CIS Kubernetes PDFs.** Neither obtained: CIS WorkBench is a sign-in gate
   and both file endpoints 404 (see `cis/SOURCES.md` §2.4). §11 therefore
   enumerates kube-bench's Apache-2.0 control set, which upstream states
   implements v2.0.1, not the CIS document itself — and it cannot be checked
   against v2.1.0 either, which is newer, whose PDF is equally unobtainable, and
   which kube-bench does not implement. Whether any of the three differ is not
   something I can determine from here.
9. **What a literal `kube-bench` run would report for the kubelet.** Several of
   the config-file audits (`audit_config`) read a JSON path that this node's
   `kubelet.yaml` does not set, and report a failure even where the kubelet's own
   default is the compliant value — 4.2.1 is the clearest case. I assessed the
   *property* from the kubelet source, not the audit's output; kube-bench was not
   installed and I did not boot a guest to run it.
10. **The kubelet's negotiated cipher list.** 4.2.12 is `partial` because no
    `tlsCipherSuites` is configured and kubelet then uses the Go runtime's
    defaults. What a client actually negotiates is a property of the Go toolchain
    and needs a handshake against a running kubelet, which I did not do.

---

## 10. Questions for the owner

Each question names the decision it blocks. These are the places where I had to
assume scope or could not determine the answer.

1. **Which benchmark and profile is the target of record?** *Answered by D1:*
   both — DIL v2.0.0 Level 2 - Server, and the CIS Kubernetes Benchmark v2.0.1
   for the node side. The residual question is the **edition**: DIL v2.0.0 is the
   latest I could establish (NIST NCP marks it archived), and the Kubernetes
   edition enumerated is the one kube-bench implements for kubelet 1.34–1.35. If
   CIS publishes a newer edition of either, this document is against the previous
   one. **Blocks:** nothing today; it decides when the assessment needs redoing.
2. **Is sshd production or test-only?** *Answered by D2:* test-only, to be
   gated. The residual question is **which gate** — a build flag, or the presence
   of the spliced `authorized_keys` — and whether the 5.2.x hardening is worth
   doing at all for a test instrument once the gate exists. **Blocks:** the D2
   projection becoming real, and whether 5.2.7–5.2.23 are ever fixed rather than
   voided.
3. **Which host-level settings get documented exceptions because Kubernetes
   needs them?** A worker that forwards pod traffic needs `ip_forward=1`
   (3.1.1), and a dual-stack or Cilium deployment wants IPv6 (3.7, 3.2.9). The
   benchmark's "host only" profile assumes a host, not a router. **Blocks:**
   3.1.1, 3.2.9, 3.7, and whether the IPv6 half of `configs/k4s-cni.config` stays.
4. **Is auditd in scope?** If yes, the prerequisite is `CONFIG_AUDIT` +
   `CONFIG_AUDITSYSCALL` plus a C userspace daemon plus a log destination. If no,
   17 non-compliant audit controls become documented exceptions. **Blocks:**
   4.1.1.1–4.1.7, 4.1.9–4.1.15, 4.1.19.
5. **Which MAC, if any?** SELinux, AppArmor, or "seccomp + namespaces is the
   confinement story, documented". **Blocks:** 1.6.1.1, 1.6.2.2, 1.6.2.3,
   1.6.2.6, 1.6.3.2, and the 4.1.8 rationale.
6. **Who owns firewall state on the node — the node or the CNI?** A node-level
   default-deny policy and Cilium's datapath both write netfilter/nftables state.
   **Blocks:** all nine 3.5.x controls and the "no iptables binary" decision in
   the roadmap.
7. **What is M2's log-shipping design?** Destination, protocol, buffering on a
   node with no disk, and whether the shipper is in `uinit` or a DaemonSet.
   **Blocks:** 4.2.1.1, 4.2.1.2, 4.2.1.3, 4.2.1.5, 4.2.3, 4.3.
8. **Should the console be an unauthenticated root shell?** u-root's init falls
   through to `/bin/sh` after `uinit` returns. Accepting that is a threat-model
   decision (physical/serial access is currently trusted, per the roadmap);
   removing it means changing init or replacing it. **Blocks:** 1.4.3, 5.4.5,
   5.5, and the "hardware is trusted while in service" assumption.
9. **Is the image hash the integrity statement, and where is it checked?** The
   cpio is a complete, reproducible description of the node, but nothing verifies
   it at boot. iPXE signing is the natural place and is an open risk. **Blocks:**
   1.2.2, 1.3.1, 1.3.2, 6.1.1.
10. **Is the throwaway control plane in scope?** I treated the apiserver/etcd VM
    in `scripts/test-cluster.sh` as a test fixture and assessed nothing about it
    (`--authorization-mode=AlwaysAllow` would fail any real benchmark). **Blocks:**
    nothing in this document, but it determines whether a second assessment is
    needed.
11. **How should `not applicable` be reported?** *Answered by D3:* all five
    statuses are reported, for each benchmark, and no percentage is computed.
    There is no headline number, and the two tallies are never added together.
12. **Is the CIS Kubernetes PDF required, or is kube-bench's control set
    enough?** The PDFs are behind the CIS WorkBench sign-in and the file
    endpoints return 404 (see `cis/SOURCES.md` §2.4); the enumeration is
    kube-bench's Apache-2.0 adaptation of v2.0.1. If an CIS-attested copy is
    required — and in particular if **v2.1.0** is the edition of record — it has
    to be obtained by hand, and a reader who needs v2.1.0 would need a
    kube-bench control set for it that does not exist yet. **Blocks:** whether
    §11 may be called an enumeration of the benchmark or only of an
    implementation of it, and which edition is the target.
13. **Is a TLS bootstrap / CSR approver in scope?** 4.2.3 (no client CA) and 4.2.9
    (a self-signed serving certificate) both close properly only with a cluster
    that issues and approves certificates for the node. The throwaway control
    plane has no approver. **Blocks:** 4.2.3, 4.2.9, and whether 4.2.10's client
    rotation is worth enabling rather than voiding.
14. **Where is the kubeconfig's mode fixed — harness or issuer?** 4.1.5 is a
    one-line `chmod` in `scripts/test-cluster.sh`, but the production answer is
    "the issuer writes it 0600" and there is no production issuer yet. The same
    question applies to 4.1.9's `kubelet.yaml`, which `DIT` installs at 0664.
    **Blocks:** 4.1.5 and 4.1.9.

---

## 11. CIS Kubernetes Benchmark: the node side

The DIL benchmark in §5 says nothing about kubelet flags, anonymous
authentication, the read-only port, certificate rotation, or the client CA the
kubelet serves with. This section is the second benchmark of record (D1) and
assesses the node's Kubernetes surface. It is a separate enumeration with a
separate tally; nothing here is added to §5's numbers.

### 11.1 The edition, and what it was enumerated from

**CIS Kubernetes Benchmark v2.0.1.** Established from three things, each of which
can be re-checked:

1. The node's kubelet is **v1.35.8** — `DIT:147-149` stamps
   `k8s.io/component-base/version.gitVersion=v1.35.8`, and the checkout is
   `kubernetes` at `1c2e10a4 "Release commit for Kubernetes v1.35.8"`.
2. kube-bench's `cfg/config.yaml` maps Kubernetes `1.34` and `1.35` to its
   `cis-2.0` control set (`references/kube-bench/cfg/config.yaml`,
   `version_mapping`).
3. The commit that added that control set says what it is: *"This version
   targets k8s v1.34-v1.35 uses v2.0 patch version (v2.0.1)"* —
   `aquasecurity/kube-bench` commit `9f133cb7`, "feat: add CIS-2.0 support". CIS's
   own benchmark page lists **CIS Kubernetes Benchmark v2.0.1** (published
   2026-04-29) and names the file `CIS_Kubernetes_Benchmark_V2.0.1_PDF.pdf`.

**A newer edition exists and was not enumerated.** CIS lists **v2.1.0**
(published 2026-09-30) above v2.0.1, and it is the newest edition of this
benchmark. Its PDF is behind the same gate and was not obtained, and no
kube-bench control set implements it — `cfg/cis-2.0` is the newest CIS set in the
pinned tree and in `main` at the fetch. So this section enumerates v2.0.1: the
newest edition whose control text is obtainable at all, and the one whose target
Kubernetes versions (1.34–1.35) include this node's kubelet. What v2.1.0 changes,
and which Kubernetes version it targets, is unknown here and is recorded as a gap
(§9 item 8) rather than guessed.

**What could not be obtained.** Both CIS PDFs. `workbench.cisecurity.org` is a
sign-in gate (302 to the Auth0 portal, then 429), and the file downloads
referenced from CIS's page — `…/file/7494/download` for v2.0.1 and
`…/file/7832/download` for v2.1.0 — each return 404 to an automated fetch; see
`cis/SOURCES.md` §2.4. The enumerating text is therefore kube-bench's
**Apache-2.0** control set,
not the CIS document: control identifiers, titles, audits, remediation and the
`scored` flag all come from
`references/kube-bench/cfg/cis-2.0/{node,policies}.yaml`, vendored with URL,
HTTP status, bytes and SHA-256. That is an independent implementation of the
edition — in the same sense that `dev-sec/cis-dil-benchmark` is for §5 — not a
transcription of the benchmark and not a reconstruction by me. Where kube-bench
and the CIS PDF differ, the PDF is not available here to say so.

**`scored`, not Level.** The Kubernetes benchmark has no L1/L2 split. kube-bench's
`scored:` flag records whether *kube-bench* counts the control towards its own
score; it is reported here as `scored` / `not scored` and is **not** a CIS level,
and it weights nothing (D3).

### 11.2 Scope: the worker node, and what a node cannot answer

Enumerated, complete for the node:

| Section | Controls | What it is |
| --- | --- | --- |
| 4.1 Worker Node Configuration Files | 10 (4.1.1–4.1.10) | modes and ownership of the kubelet's unit file, kubeconfig, CA file and config file |
| 4.2 Kubelet | 14 (4.2.1–4.2.14) | kubelet flags and `KubeletConfiguration` fields |
| 4.3 kube-proxy | 1 (4.3.1) | enumerated in order to record that there is no kube-proxy |
| 5.3.1 | 1 | the CNI in use supports NetworkPolicies — the node chooses its CNI |
| 5.6.2 | 1 | the seccomp profile applied to pods — kubelet applies one node-wide |

**Excluded: the control plane.** The `master`, `controlplane` and `etcd` control
sets are not assessed. The apiserver, etcd, controller-manager and scheduler this
node talks to run in the **throwaway VM** built by `scripts/test-cluster.sh` and
started by `cmd/uinit`'s `control-plane` role with
`--authorization-mode=AlwaysAllow` (`cmd/uinit/main.go:203`). That is a test
fixture, not a deployed component, and nothing in this document assesses it — the
same exclusion §4.8 makes. A real control plane would be a third assessment.

**Excluded: the cluster-level policy controls a node cannot satisfy alone.**
5.1 (RBAC and service accounts), 5.2 (Pod Security Standards — enforced by the
apiserver's admission plugin, not by the node), 5.3.2 (every namespace has
NetworkPolicies — a property of cluster objects), 5.4 (secrets management), 5.5
(admission webhooks), and 5.6.1, 5.6.3, 5.6.4 (namespace and workload
conventions). None can be satisfied *by a node on its own*. 5.3.1 and 5.6.2 are
the two that a node can satisfy itself, which is why they are enumerated. A
literal `kube-bench` run against this node would also run the excluded ones, score
them against a cluster it does not have, and run the control-plane sets against a
VM; its score is not this section's.

**The benchmark assumes systemd.** Several audits name `$kubeletsvc` and remediate
with `systemctl restart kubelet.service`, and several read a config file with
`cat`. There is no systemd and no unit file on this node, so where the audit's
subject is absent the entry says so and assesses the *property* — the same
distinction §3 draws and 1.1.1.1 makes explicit.

### 11.3 Summary table and tally

All 27 enumerated controls, in benchmark order. The detailed entry for each is in
§11.4. `scored` is kube-bench's own `scored:` flag, not a CIS level.

<!-- K8S-SUMMARY-TABLE-START -->
| ID | Control | Scored | Status |
| --- | --- | --- | --- |
| 4.1.1 | Ensure that the kubelet service file permissions are set to 600 or more restrictive | `scored` | `not applicable` |
| 4.1.2 | Ensure that the kubelet service file ownership is set to root:root | `scored` | `comply` |
| 4.1.3 | If proxy kubeconfig file exists ensure permissions are set to 600 or more restrictive | `not scored` | `not applicable` |
| 4.1.4 | If proxy kubeconfig file exists ensure ownership is set to root:root | `not scored` | `not applicable` |
| 4.1.5 | Ensure that the --kubeconfig kubelet.conf file permissions are set to 600 or more restrictive | `scored` | `non-compliant` |
| 4.1.6 | Ensure that the --kubeconfig kubelet.conf file ownership is set to root:root | `scored` | `comply` |
| 4.1.7 | Ensure that the certificate authorities file permissions are set to 644 or more restrictive | `not scored` | `not applicable` |
| 4.1.8 | Ensure that the client certificate authorities file ownership is set to root:root | `not scored` | `not applicable` |
| 4.1.9 | If the kubelet config.yaml configuration file is being used validate permissions set to 600 or more restrictive | `scored` | `non-compliant` |
| 4.1.10 | If the kubelet config.yaml configuration file is being used validate file ownership is set to root:root | `scored` | `comply` |
| 4.2.1 | Ensure that the --anonymous-auth argument is set to false | `scored` | `comply` |
| 4.2.2 | Ensure that the --authorization-mode argument is not set to AlwaysAllow | `scored` | `comply` |
| 4.2.3 | Ensure that the --client-ca-file argument is set as appropriate | `scored` | `non-compliant` |
| 4.2.4 | Verify that if defined, the --read-only-port argument is set to 0 | `not scored` | `comply` |
| 4.2.5 | Ensure that the --streaming-connection-idle-timeout argument is not set to 0 | `not scored` | `comply` |
| 4.2.6 | Ensure that the --make-iptables-util-chains argument is set to true | `scored` | `partial` |
| 4.2.7 | Ensure that the --hostname-override argument is not set | `not scored` | `non-compliant` |
| 4.2.8 | Ensure that the eventRecordQPS argument is set to a level which ensures appropriate event capture | `not scored` | `comply` |
| 4.2.9 | Ensure that the --tls-cert-file and --tls-private-key-file arguments are set as appropriate | `not scored` | `non-compliant` |
| 4.2.10 | Ensure that the --rotate-certificates argument is not set to false | `scored` | `partial` |
| 4.2.11 | Verify that the RotateKubeletServerCertificate argument is set to true | `not scored` | `comply` |
| 4.2.12 | Ensure that the Kubelet only makes use of Strong Cryptographic Ciphers | `not scored` | `partial` |
| 4.2.13 | Ensure that a limit is set on pod PIDs | `not scored` | `non-compliant` |
| 4.2.14 | Ensure that the --seccomp-default parameter is set to true | `not scored` | `comply` |
| 4.3.1 | Ensure that the kube-proxy metrics service is bound to localhost | `scored` | `not applicable` |
| 5.3.1 | Ensure that the CNI in use supports NetworkPolicies | `not scored` | `partial` |
| 5.6.2 | Ensure that the seccomp profile is set to docker/default in your Pod definitions | `not scored` | `comply` |

**27 controls, reported separately from the DIL tally above** (25 from the worker-node sections 4.x and 2 cluster-level policy controls a node can satisfy on its own: 5.3.1 and 5.6.2).

| Status | Count |
| --- | --- |
| `comply` | 11 |
| `partial` | 4 |
| `non-compliant` | 6 |
| `not applicable` | 6 |
| `infeasible by design` | 0 |
| **total** | **27** |
<!-- K8S-SUMMARY-TABLE-END -->

### 11.4 Requirement-by-requirement assessment

Order is the benchmark's own. Each entry gives what the control requires, the
status, the evidence, and what closing it would take — the same four lines as §5.
Where the evidence is a default read from the kubelet source rather than a value
observed on a running node, the entry says which.

#### 4.1.1 Ensure that the kubelet service file permissions are set to 600 or more restrictive — scored

**Requires.** `$kubeletsvc` — the kubelet's systemd unit, `/etc/systemd/system/kubelet.service` or a drop-in — is mode 600 or more restrictive.
**Status.** `not applicable` — there is no unit file, because there is no systemd.
**Evidence (verified).** The cpio contains no `/etc/systemd`; kubelet is exec'd directly by `uinit` (`cmd/uinit/main.go:139-142`). The artefact this control is really about — a file a non-root account could rewrite to change how kubelet starts — is `/bin/kubelet`, which the cpio records as `0775 root:root`: group-writable, because `-files` records the source file's mode (`DIT:194` installs `build/kubelet`, which is 0775 on the builder).
**Cost.** none for the control as written. The analogous hardening is one `chmod 0755` on `build/kubelet` in `DIT` so the binary is not group-writable; it closes no control, since there is no unit file to grade.

#### 4.1.2 Ensure that the kubelet service file ownership is set to root:root — scored

**Requires.** The same unit file is owned `root:root`.
**Status.** `comply` — by the control's own test, which accepts an absent file.
**Evidence (verified).** kube-bench's test for 4.1.2 is `bin_op: or` over `root:root` and the literal `File not found` (`references/kube-bench/cfg/cis-2.0/node.yaml`, 4.1.2), and there is no unit file. Every file in the image is `root:root` (`cpio -itv`), `/bin/kubelet` included, so the property holds even where the control's subject does not exist.
**Cost.** none. The asymmetry with 4.1.1 is the benchmark's, not this node's: one control has a `File not found` escape and the other does not.

#### 4.1.3 If proxy kubeconfig file exists ensure permissions are set to 600 or more restrictive — not scored

**Requires.** `$proxykubeconfig` — kube-proxy's kubeconfig — is 600 or more restrictive, if it exists.
**Status.** `not applicable` — there is no kube-proxy and so no proxy kubeconfig.
**Evidence (verified).** No `kube-proxy` binary in the image (`cpio -it`); `DIT` builds no such binary; there is no `/var/lib/kube-proxy` or `/etc/kubernetes/proxy.conf`. kube-bench's candidate paths (`references/kube-bench/cfg/config.yaml`, `proxykubeconfig`) do not exist.
**Cost.** none.

#### 4.1.4 If proxy kubeconfig file exists ensure ownership is set to root:root — not scored

**Requires.** The same file is owned `root:root`.
**Status.** `not applicable` — as 4.1.3.
**Evidence (verified).** No proxy kubeconfig exists.
**Cost.** none.

#### 4.1.5 Ensure that the --kubeconfig kubelet.conf file permissions are set to 600 or more restrictive — scored

**Requires.** The kubelet's kubeconfig — `/etc/kubernetes/kubeconfig` here, one of the paths kube-bench probes — is 600 or more restrictive.
**Status.** `non-compliant` — 0644 on the only path where the file exists.
**Evidence (verified from source; not from a built test image).** The base image does not carry it (`DIT:177-179`); `scripts/test-cluster.sh:249` writes it with a shell redirect, the script sets no `umask`, and the recorder takes the source file's mode from `os.Lstat` (`u-root/pkg/cpio/fs_unix.go:235-252`), so it lands as 0644. `kube-bench`'s candidate list includes `/etc/kubernetes/kubeconfig`, so a literal run would find and fail it. Production has no issuance path for the file at all.
**Cost.** trivial — `chmod 600` after the heredoc, or create the file 0600 before splicing. The production answer is that the issuer writes it 0600 (question 14).

#### 4.1.6 Ensure that the --kubeconfig kubelet.conf file ownership is set to root:root — scored

**Requires.** The same file is owned `root:root`.
**Status.** `comply`.
**Evidence (verified).** Every file in the built image is archived `root:root` (`cpio -itv`), and the spliced kubeconfig goes through the same `u-root -files` path as the files that listing covers (`scripts/test-cluster.sh:448-450`).
**Cost.** none.

#### 4.1.7 Ensure that the certificate authorities file permissions are set to 644 or more restrictive — not scored

**Requires.** The CA file the kubelet serves/verifies with is 644 or more restrictive.
**Status.** `not applicable` — there is no CA file on the node.
**Evidence (verified).** `etc/kubernetes` in the cpio contains `kubelet.yaml` only, with no `pki/`; the CA is inlined in the kubeconfig as `certificate-authority-data` (`scripts/test-cluster.sh:237`).
**Cost.** none as written. 4.2.3 is where the absent CA file actually bites.

#### 4.1.8 Ensure that the client certificate authorities file ownership is set to root:root — not scored

**Requires.** The same CA file is owned `root:root`.
**Status.** `not applicable` — as 4.1.7.
**Evidence (verified).** No CA file exists on the node.
**Cost.** none.

#### 4.1.9 If the kubelet config.yaml configuration file is being used validate permissions set to 600 or more restrictive — scored

**Requires.** The kubelet config file — `/etc/kubernetes/kubelet.yaml` here — is 600 or more restrictive.
**Status.** `non-compliant` — it is 0664 in the built image.
**Evidence (verified).** `cpio -itv` records `etc/kubernetes/kubelet.yaml` as `-rw-rw-r--` (0664) `root root`, which is the mode of `configs/node/kubelet.yaml` on the builder; `DIT:196` installs it with `-files`. The mode is therefore whatever the checkout's umask left, not a decision.
**Cost.** trivial — `chmod 0600 configs/node/kubelet.yaml` (or the mode in `DIT`). The same class as 6.1.2 and 6.1.4.

#### 4.1.10 If the kubelet config.yaml configuration file is being used validate file ownership is set to root:root — scored

**Requires.** The same file is owned `root:root`.
**Status.** `comply`.
**Evidence (verified).** `cpio -itv`: `etc/kubernetes/kubelet.yaml` is owned `root root`, as every file in the image is.
**Cost.** none.

#### 4.2.1 Ensure that the --anonymous-auth argument is set to false — scored

**Requires.** Unauthenticated requests to the kubelet's HTTPS endpoint are refused: `authentication.anonymous.enabled: false`.
**Status.** `comply` — the kubelet's config-file default is already `false` in this version.
**Evidence (verified).** `configs/node/kubelet.yaml` sets no `authentication` block. kubelet v1.35.8's v1beta1 defaulting sets `Authentication.Anonymous.Enabled = false` when it is nil (`kubernetes/pkg/kubelet/apis/config/v1beta1/defaults.go:92-93`), and the config file is decoded through that scheme (`kubernetes/pkg/kubelet/kubeletconfig/configfiles/configfiles.go:65-84`). The *flag* API's legacy default is still `true` (`kubernetes/cmd/kubelet/app/options/options.go:213-215`) — this node is safe **because** it starts kubelet with `--config` (`cmd/uinit/main.go:139-142`) and not with a flag set.
**Cost.** none. Note for anyone running kube-bench literally: its `audit_config` reads `{.authentication.anonymous.enabled}` from the file and reports a failure when the key is absent, even though the effective value is `false` — §9 item 9.

#### 4.2.2 Ensure that the --authorization-mode argument is not set to AlwaysAllow — scored

**Requires.** `authorization.mode` is `Webhook`, not `AlwaysAllow`.
**Status.** `comply` — the config-file default is `Webhook`.
**Evidence (verified).** No `authorization` block in `configs/node/kubelet.yaml`; `defaults.go:101-102` sets `KubeletAuthorizationModeWebhook` when it is empty. As with 4.2.1, the legacy flag default is the dangerous one — `applyLegacyDefaults` sets `AlwaysAllow` (`cmd/kubelet/app/options/options.go:218-219`) — and using `--config` is what avoids it.
**Cost.** none.

#### 4.2.3 Ensure that the --client-ca-file argument is set as appropriate — scored

**Requires.** `authentication.x509.clientCAFile` names a CA the kubelet authenticates clients with.
**Status.** `non-compliant`.
**Evidence (verified).** No `authentication` block in `configs/node/kubelet.yaml`; `kubernetes/cmd/kubelet/app/server.go:1170-1173` loads a client CA only when the field is non-empty, and there is no fallback to the kubeconfig's CA. There is no CA file on the node to point at (4.1.7).
**Cost.** cheap — ship the CA (the kubeconfig already carries it base64 at `scripts/test-cluster.sh:237`) as `/etc/kubernetes/pki/ca.crt` and set `authentication.x509.clientCAFile`. Without it, x509 client authentication at the kubelet is simply unavailable; 4.2.1 and 4.2.2 mean that fails closed rather than open.

#### 4.2.4 Verify that if defined, the --read-only-port argument is set to 0 — not scored

**Requires.** The unauthenticated read-only port is disabled (`readOnlyPort: 0`), or the field is absent.
**Status.** `comply` — absent from the file, and the effective value is 0.
**Evidence (verified).** `configs/node/kubelet.yaml` sets no `readOnlyPort`; `SetDefaults_KubeletConfiguration` sets no `ReadOnlyPort` (`defaults.go:60-250`), and `defaults_test.go:152` shows the defaulted config with `ReadOnlyPort: 0`. kubelet only starts the listener when the value is positive (`kubernetes/cmd/kubelet/app/server.go:1270-1271`). The flag default of 10255 (`cmd/kubelet/app/options/options.go:220-221`, `kubernetes/pkg/cluster/ports/ports.go:37`) is not applied, because `kubeletConfigFlagPrecedence` re-parses only the flags actually given on the command line (`cmd/kubelet/app/server.go:408-431`).
**Cost.** none.

#### 4.2.5 Ensure that the --streaming-connection-idle-timeout argument is not set to 0 — not scored

**Requires.** Streaming connections (exec, attach, port-forward) are not allowed to live forever.
**Status.** `comply` — the default is 4 hours.
**Evidence (verified).** No `streamingConnectionIdleTimeout` in `configs/node/kubelet.yaml`; `defaults.go:134-135` sets `4 * time.Hour`.
**Cost.** none.

#### 4.2.6 Ensure that the --make-iptables-util-chains argument is set to true — scored

**Requires.** kubelet maintains its iptables utility chains.
**Status.** `partial` — the setting is the compliant default, but the mechanism it drives cannot run.
**Evidence (verified).** `defaults.go:245-246` sets `MakeIPTablesUtilChains = true`. But the image contains no `iptables`, `ip6tables` or `nft` binary (`cpio -it`), so the chains it would create cannot be created; the kernel would allow it (`build/kernel/.config`: `CONFIG_IP_NF_IPTABLES=y`, `CONFIG_IP_NF_FILTER=y`, `CONFIG_IP_NF_NAT=y`, `CONFIG_NF_TABLES=y`). The node has no kube-proxy either (4.3.1), so nothing on it consumes those chains.
**Cost.** cheap either way: ship an `iptables-nft` binary, or set `makeIPTablesUtilChains: false` and record why — the CNI owns netfilter state here (§7.2, firewall).

#### 4.2.7 Ensure that the --hostname-override argument is not set — not scored

**Requires.** The kubelet derives its node name from the machine, not from a flag.
**Status.** `non-compliant` — the flag is set.
**Evidence (verified).** `cmd/uinit/main.go:139-142` passes `--hostname-override=k4s-node-1`.
**Cost.** cheap but not free: nothing sets the guest's hostname (`grep -n sethostname cmd/uinit u-root/pkg/libinit` is empty), and both `scripts/test-cluster.sh:73` and the `nodeName: k4s-node-1` pinned in every `examples/*.yaml` depend on the name. Removing the flag needs a `sethostname` in `uinit` first, so that the machine carries the name rather than the kubelet flag asserting it.

#### 4.2.8 Ensure that the eventRecordQPS argument is set to a level which ensures appropriate event capture — not scored

**Requires.** `eventRecordQPS` is set, and not to 0 (unlimited) or a rate that drops events.
**Status.** `comply` — the default is 50 per second.
**Evidence (verified).** No `eventRecordQPS` in `configs/node/kubelet.yaml`; `defaults.go:116-117` sets `50`.
**Cost.** none. The control is a judgement call about a rate; the default is the benchmark's own "appropriate level", and nothing here tunes it.

#### 4.2.9 Ensure that the --tls-cert-file and --tls-private-key-file arguments are set as appropriate — not scored

**Requires.** The kubelet serves with an explicit certificate and key.
**Status.** `non-compliant` — neither is configured; kubelet generates a self-signed pair.
**Evidence (verified).** No `tlsCertFile`/`tlsPrivateKeyFile` in `configs/node/kubelet.yaml`. `kubernetes/cmd/kubelet/app/server.go:1102-1120` (`InitializeTLS`) then writes a self-signed certificate and key into `--cert-dir`, which defaults to `/var/lib/kubelet/pki` (`cmd/kubelet/app/options/options.go:138`), i.e. onto the tmpfs that `uinit` mounts for kubelet (`cmd/uinit/main.go:126-128`). A new pair is generated whenever the files cannot be read — which, on a RAM-only node, is every boot.
**Cost.** moderate — a per-boot cert is inherent to a diskless node; the compliant shape is `serverTLSBootstrap: true` plus a CSR approver in the cluster, which the throwaway control plane does not run (question 13).

#### 4.2.10 Ensure that the --rotate-certificates argument is not set to false — scored

**Requires.** Client certificate rotation is not disabled.
**Status.** `partial` — nothing sets it to `false`, so the control's letter holds; the effective value is `false`, so rotation does not happen.
**Evidence (verified).** No `rotateCertificates` in `configs/node/kubelet.yaml`. With a config file the value is the zero value and nothing in the defaulting path sets it: `defaults_test.go:157` records `RotateCertificates: false` in the defaulted configuration. Rotation is moot on this node — the harness writes a fresh kubeconfig with a fresh client certificate every boot (`scripts/test-cluster.sh:241-249`) — which is why this is `partial` rather than a finding.
**Cost.** none for the control; `rotateCertificates: true` needs a CSR approver, same as 4.2.9.

#### 4.2.11 Verify that the RotateKubeletServerCertificate argument is set to true — not scored

**Requires.** The `RotateKubeletServerCertificate` feature gate is not `false`.
**Status.** `comply` — the gate's default is `true`.
**Evidence (verified).** `configs/node/kubelet.yaml` sets no `featureGates`, and kube-bench's own test accepts an unset gate. The gate is beta-default-on since 1.12 (`kubernetes/pkg/features/kube_features.go:1724-1727`: `Default: true, PreRelease: featuregate.Beta`). Note the gate is **inert** here: with `serverTLSBootstrap` unset, the kubelet never asks the API for a serving certificate, so the self-signed pair of 4.2.9 is what it serves.
**Cost.** none.

#### 4.2.12 Ensure that the Kubelet only makes use of Strong Cryptographic Ciphers — not scored

**Requires.** `tlsCipherSuites` is restricted to the benchmark's ECDHE/AEAD list.
**Status.** `partial` — no list is configured; the Go runtime's defaults apply instead.
**Evidence (verified).** No `tlsCipherSuites` in `configs/node/kubelet.yaml`; `kubernetes/cmd/kubelet/app/server.go:1134-1164` sets `tlsConfig.CipherSuites` only when the configured list is non-empty. What is then served is the Go toolchain's default list — the ECDHE/AEAD suites the control names, with TLS 1.3 suites always on and not configurable — the direction the control wants, but owned by the toolchain rather than by this repository. Not verified against a handshake (§9 item 10).
**Cost.** cheap — one list in `kubelet.yaml` — and it pins a property that otherwise moves with the Go version, the same shape as DIL 5.2.13–5.2.15.

#### 4.2.13 Ensure that a limit is set on pod PIDs — not scored

**Requires.** `podPidsLimit` bounds the number of processes a pod can create.
**Status.** `non-compliant` — the field is absent and defaults to unlimited.
**Evidence (verified).** No `podPidsLimit` in `configs/node/kubelet.yaml`; `defaults.go:198-199` defaults it to `-1`, documented there as "node allocatable pid limit". The pids controller is enabled, so a limit would take effect (`cmd/uinit/main.go:110` writes `+pids` to `cgroup.subtree_control`).
**Cost.** trivial — `podPidsLimit: 4096` (or any chosen number) in `configs/node/kubelet.yaml`; the only real work is choosing it.

#### 4.2.14 Ensure that the --seccomp-default parameter is set to true — not scored

**Requires.** Pods without an explicit seccomp profile get `RuntimeDefault`.
**Status.** `comply`.
**Evidence (verified).** `configs/node/kubelet.yaml:15` sets `seccompDefault: true` (the `KubeletConfiguration` bool; the CLI flag is a string, as the comment there notes). The M1 test asserts the effect end to end: `scripts/test-cluster.sh:1060` prints `seccomp: ok (container runs under a filter)` and the smoke pod reports `Seccomp: 2`.
**Cost.** none. Of the controls here it is the one the node holds by a deliberate line of configuration rather than by inheriting a kubelet default, and it is why the DIL document's "no MAC" finding is not the whole confinement story (§4.4).

#### 4.3.1 Ensure that the kube-proxy metrics service is bound to localhost — scored

**Requires.** kube-proxy's metrics endpoint binds `127.0.0.1`, or the flag is absent.
**Status.** `not applicable` — there is no kube-proxy.
**Evidence (verified).** No `kube-proxy` binary in the image (`cpio -it`) and none built (`DIT` builds `kubelet` only). There is also no service routing to proxy: reaching a ClusterIP needs kube-proxy or a CNI that replaces it, and this node has neither, which is why flanneld is given `KUBERNETES_SERVICE_HOST`/`PORT` explicitly (`docs/roadmap.md:172`). flannel and Cilium program the node's routes themselves.
**Cost.** none. If kube-proxy were ever added, its metrics binding is one flag; until then this control has no subject.

#### 5.3.1 Ensure that the CNI in use supports NetworkPolicies — not scored

**Requires.** The cluster's CNI enforces NetworkPolicy objects.
**Status.** `partial` — the default CNI cannot; the optional one can.
**Evidence (verified).** The baked-in default is flannel (`DIT:201-206` installs the plugins and `configs/node/10-flannel.conflist`), which implements no NetworkPolicy. The same harness runs Cilium under `K4S_CNI=cilium` (`Makefile:121-122`), which does, and `docs/cilium.md` prices that choice. Which one is delivered decides this control.
**Cost.** the Cilium decision itself — kernel fragment, memory (`K4S_NODE_MEM=6144`) and an agent on every node. Not a hardening change a node can make on its own, which is why it is the only 5.3 control enumerated.

#### 5.6.2 Ensure that the seccomp profile is set to docker/default in your Pod definitions — not scored

**Requires.** Pods run with a default seccomp profile (`docker/default`, which in current Kubernetes is spelled `RuntimeDefault`).
**Status.** `comply` — by the node-wide mechanism rather than per-pod.
**Evidence (verified).** `configs/node/kubelet.yaml:15` (`seccompDefault: true`) makes kubelet apply `RuntimeDefault` to every pod that does not name a profile, so the workload-side setting the control asks for is unnecessary here. `scripts/test-cluster.sh:1060` asserts the container really runs under a filter.
**Cost.** none. A pod that explicitly asks for `Unconfined` can still opt out, which is a Pod Security admission question (§11.2, 5.2.x), not a node one.

