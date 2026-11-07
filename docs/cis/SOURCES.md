# Provenance of the CIS reference material

Everything under `docs/cis/` that came from outside this repository is recorded
here: source URL, HTTP status, byte count, SHA-256, fetch date and licence. Files
fetched but **not** vendored are listed separately, with the reason.

Fetch date for every row: **2026-10-19** (UTC), except where a row says otherwise
(the kube-bench `cfg/config.yaml` and the Kubernetes edition evidence in §2.4.1
were fetched **2026-10-20**).

## 1. The benchmark this assessment enumerates

**CIS Distribution Independent Linux Benchmark, version 2.0.0, 2019-07-16.**

| Property | Value |
| --- | --- |
| Document self-identifies as | `CIS Distribution Independent Linux Benchmark v2.0.0 - 07-16-2019` |
| Pages | 572 |
| Controls | 237 (all in the Level 1/2 - Server profiles; 45 are Level 2 additions) |
| Obtained from | two independent public mirrors (below), byte-identical |
| Byte count | 3,227,396 |
| SHA-256 | `6deafd75b8270141e1368312ff081d4d9792d0f835bbc9e631c919b5c88b359a` |
| Licence | © Center for Internet Security. Distributed free of charge for non-commercial use; **not** redistributable here. |
| Vendored in this repository | **No** — deliberately. See §4. |

Both mirrors returned the same file:

| URL | HTTP | Bytes | SHA-256 |
| --- | --- | --- | --- |
| `https://paper.bobylive.com/Security/CIS/CIS_Distribution_Independent_Linux_Benchmark_v2_0_0.pdf` | 200 | 3,227,396 | `6deafd75…b359a` |
| `https://raw.githubusercontent.com/skylens/CIS/master/CIS_Distribution_Independent_Linux_Benchmark_v2.0.0.pdf` | 200 | 3,227,396 | `6deafd75…b359a` |

These are **third-party mirrors, not CIS**. They are cited so the enumeration can
be re-derived; they are not authoritative distribution channels and may vanish.

### What could not be obtained, and how that was handled

| Source | Result | Consequence |
| --- | --- | --- |
| `https://www.cisecurity.org/benchmark/distribution_independent_linux` | **404** | The old landing page is gone. |
| `https://www.cisecurity.org/cis-benchmarks` | **403** to an automated fetch | CIS's own copy could not be checked. |
| `https://workbench.cisecurity.org/` (CIS WorkBench, where the PDFs now live) | **302 redirect loop** (>50 redirects), i.e. an interactive sign-in/consent gate | Not obtainable programmatically. |
| `https://downloads.cisecurity.org/` | 200, but a JavaScript app behind a consent gate | No PDF obtainable. |
| NIST NCP checklist 1129 "download" endpoint | 200, 1,713 bytes of HTML (an error/interstitial page, not a PDF) | Not used as a copy. |

**Hash-level caveat.** NIST's National Checklist Program entry for this benchmark
(checklist 1129) publishes a SHA-256 of **its own** artifact:
`74569FEEE61F0299B09D420A44463AD6166C5497339C36EF16A9F693E1321C39`
(`https://ncp.nist.gov/checklist/1129`). That is *not* the hash of the PDF I
obtained, so I cannot claim the mirror copies are bit-identical to whatever NCP
holds. What I can say is narrower and factual: the two independent mirrors agree
byte-for-byte, the document's own title page says v2.0.0 / 2019-07-16, it is 572
pages, and its content and control set match the InSpec profile that targets the
same edition (see §2). This is an **unverified copy of the right edition**, not a
CIS-attested one.

**Edition is the latest known.** CIS's January 2026 benchmark-update post lists
no Distribution Independent Linux release, and NCP marks v2.0.0 as *archived*. I
found no evidence of a v2.1 or v3.0 DIL benchmark. If one exists, this assessment
is against the wrong edition — see "questions for the owner" in
`../cis-level2-hardening.md`.

**The second benchmark of record** is the CIS Kubernetes Benchmark, worker-node
sections only. Its edition (v2.0.1), its fetched provenance and the PDF that could
not be obtained are §2.4 and §2.4.1 below.

## 2. Vendored reference material

Each directory carries its upstream `LICENSE` and a `MANIFEST.sha256` of every
file in it, so the vendored tree can be verified without re-downloading a
tarball.

### 2.1 dev-sec/cis-dil-benchmark — the independent cross-check

| Property | Value |
| --- | --- |
| URL | `https://codeload.github.com/dev-sec/cis-dil-benchmark/tar.gz/c73917fb02e7b452e1f080bf970e09338cb2f9eb` |
| HTTP | 200 |
| Bytes | 54,272 |
| SHA-256 | `973273fd244cad03b6d781044f900f5130f3bc693bd2c6149bd4d3242c98f7e8` |
| Commit | `c73917fb02e7b452e1f080bf970e09338cb2f9eb` |
| Licence | **Apache-2.0** (`LICENSE` in the tree) |
| Vendored at | `references/dev-sec-cis-dil-benchmark/` |
| Profile version | `inspec.yml` says `0.4.13`, default `cis_level: 2` |

**What it is, precisely:** an InSpec profile *implementing* CIS DIL 2.0.0. It is
not the benchmark, but each control carries the benchmark's ID
(`tag cis: 'distribution-independent-linux:<id>'`), title, level (`tag level:`)
and an audit implemented in Ruby. It is the source used to cross-check that the
PDF enumeration is complete and to corroborate level assignments.

Cross-check result:

- InSpec profile: **237 controls**. PDF enumeration: **237 controls**. Same ID set.
- Level split: InSpec `{level 1: 192, level 2: 45}`; PDF `{L1-Server: 192,
  L2-Server: 45}`. Same.
- Two level disagreements: **5.2.6** (InSpec level 1; PDF says Level 1 -
  Workstation / Level 2 - Server) and **5.2.22** (InSpec level 2; PDF says Level 1
  - Server / Level 1 - Workstation). The **PDF is treated as authoritative**; the
  disagreements are recorded rather than silently resolved.
- **A parser caveat worth recording, because it nearly produced a wrong
  inventory.** The first automated extraction from the PDF found only 224
  controls: 13 headings (e.g. 4.1.7, 4.1.8, 4.1.11, 4.1.12, 4.1.16, 5.3.2,
  6.2.8, 1.1.18–1.1.20) wrap across lines in a way that a naive heading regex
  misses. The InSpec profile's 237 and the PDF's own summary table caught the
  discrepancy; the body headings were then re-parsed with the wrapping handled,
  and all 237 have full body text. No control's assessment rests on the summary
  table alone.

### 2.2 dev-sec/linux-baseline

| Property | Value |
| --- | --- |
| URL | `https://codeload.github.com/dev-sec/linux-baseline/tar.gz/a9e6ad61d819c248bc2400d7750b3e2632dd0db2` |
| HTTP | 200 |
| Bytes | 18,716 |
| SHA-256 | `e66344334f5863ea7d30cc9815c50ec63b9ac734413eb31a32d986b068a0385f` |
| Commit | `a9e6ad61d819c248bc2400d7750b3e2632dd0db2` |
| Licence | **Apache-2.0** |
| Vendored at | `references/dev-sec-linux-baseline/` |
| Profile version | `2.11.0` |

Used as a second opinion on kernel-sysctl and mount-option remediation wording
(`controls/sysctl_spec.rb`, `controls/os_spec.rb`). It is **not** a CIS mapping;
it carries no CIS control IDs.

### 2.3 dev-sec/ssh-baseline

| Property | Value |
| --- | --- |
| URL | `https://codeload.github.com/dev-sec/ssh-baseline/tar.gz/975dff3caa1e6d912ae52be1f82318c9e42bedfa` |
| HTTP | 200 |
| Bytes | 17,334 |
| SHA-256 | `44b5429f20540fa2a0de50d91b8090045aef4d25ddd3f3e885872a5aed40ff93` |
| Commit | `975dff3caa1e6d912ae52be1f82318c9e42bedfa` |
| Licence | **Apache-2.0** |
| Vendored at | `references/dev-sec-ssh-baseline/` |
| Profile version | `2.8.1` |

Used for what an `sshd_config`-based audit actually looks for, to make the
"there is no `sshd_config` here" finding concrete rather than rhetorical.

### 2.4 aquasecurity/kube-bench — the Kubernetes benchmark of record

| Property | Value |
| --- | --- |
| URL base | `https://raw.githubusercontent.com/aquasecurity/kube-bench/e278a5915a982f2756026de6e2f9ca77077ef9f9/` |
| Commit | `e278a5915a982f2756026de6e2f9ca77077ef9f9` (2026-10-05) |
| Licence | **Apache-2.0** (`LICENSE` in the tree) |
| Vendored at | `references/kube-bench/` |

Only the CIS Kubernetes control set was vendored, not the whole repository
(~10 MB). It is the enumerating text for §11 of the assessment: control
identifiers, titles, audits, remediation and the `scored` flag. Per-file
provenance:

| File | HTTP | Bytes | SHA-256 |
| --- | --- | --- | --- |
| `cfg/config.yaml` | 200 | 16,428 | `f274224ff57a5aa945fffa673224ac1830f0b10ed1c015fa04810c1f85e15374` |
| `cfg/cis-2.0/config.yaml` | 200 | 77 | `f8beefa9c5392e5c25d03e802294ad1852ac094d3bf3053903dad718f599e3b7` |
| `cfg/cis-2.0/controlplane.yaml` | 200 | 2,810 | `c675e598ab6414b2e2e1b4e8dc9d947dd2d3fd3138ad1107b07c83cfb4c96897` |
| `cfg/cis-2.0/etcd.yaml` | 200 | 4,919 | `6febdc4959f769153ffe3b605a8b4db794b29ed605e11cbe651575d0f7d768a5` |
| `cfg/cis-2.0/master.yaml` | 200 | 40,262 | `0b1b74801b86638646a9bfb83c1f1f861c96f0f9009a96f4dc966889cad48b8d` |
| `cfg/cis-2.0/node.yaml` | 200 | 20,993 | `6e1ed27051bffcebbaeba5e6895c81704efd785e9daf8bb896febe8f135862a7` |
| `cfg/cis-2.0/policies.yaml` | 200 | 24,707 | `716ac411115288c01553491b6fe96d85366c3d012af8bdc2abda9ae7d10884f9` |
| `LICENSE` | 200 | 11,358 | `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30` |

`cfg/config.yaml` was fetched on **2026-10-20** (UTC); the other rows on
2026-10-19. It is vendored because it is the file that carries the edition
mapping (below); without it the `cis-2.0` control set names only
`version: "cis-2.0"` and no CIS edition.

#### 2.4.1 Which CIS Kubernetes edition: v2.0.1

Three independent facts, each re-checkable:

1. kube-bench's `cfg/config.yaml` `version_mapping` sends Kubernetes `1.34` and
   `1.35` to the `cis-2.0` control set. The node's kubelet is **v1.35.8**
   (`DIT:147-149` stamps `gitVersion=v1.35.8`; the checkout is at
   `1c2e10a4 "Release commit for Kubernetes v1.35.8"`).
2. The commit that added `cfg/cis-2.0` — `9f133cb7`, "feat: add CIS-2.0 support
   (#2124) (#2126)" — says what it implements: *"This version targets k8s
   v1.34-v1.35 uses v2.0 patch version
   ([v2.0.1](https://workbench.cisecurity.org/benchmarks/26831))"*.
3. `https://www.cisecurity.org/benchmark/kubernetes` (HTTP 200, 315,892 bytes,
   SHA-256 `7bdba239354b41f1f5e61bc407437439a8aca1ec3db4651516c64310d310fc2e`,
   fetched 2026-10-20) lists the editions with their publication dates:
   **v2.1.0** (2026-09-30, file id 7832), **v2.0.1** (2026-04-29, file id 7494)
   and **v2.0.0** (2026-04-29, file id 7350).

The directory is named `cis-2.0`, not `cis-2.0.1`. The patch version comes from
(2) and (3) and is recorded as theirs — it is **not** inferred from the directory
name.

**v2.1.0 is newer and was not enumerated.** It is the newest edition CIS lists.
Its PDF endpoint returns 404 to an automated fetch exactly as v2.0.1's does, and
no kube-bench control set implements it: `cfg/cis-2.0` is the newest CIS set in
the pinned tree and in `main` at the time of the fetch (the `cfg/` listing on
`main` ends at `cis-2.0`, and the newest release, v0.16.0, predates v2.1.0's
publication). §11 therefore enumerates **v2.0.1**, because it is the newest
edition whose control text is obtainable at all, and because it is the edition
that maps to this node's Kubernetes version — its target is 1.34–1.35 and the
kubelet is v1.35.8. What v2.1.0 changes, and which Kubernetes version it
targets, is **not known here**: the document is not obtainable, and this record
does not guess.

**What could not be obtained: the CIS Kubernetes PDF itself.**

| Attempt | Result |
| --- | --- |
| `https://workbench.cisecurity.org/benchmarks/26831` | 302 to the CIS Auth0 sign-in portal; following redirects ends at `auth.portal.cisecurity.org/u/login` after 48 hops, final response **429** |
| `https://workbench.cisecurity.org/cis/api/v1/file/7494/download` (the file CIS's page references for v2.0.1) | **404**, 1,659 bytes of HTML |
| `https://workbench.cisecurity.org/cis/api/v1/file/7832/download` (the same for v2.1.0) | **404**, 1,659 bytes of HTML |
| `https://www.cisecurity.org/benchmark/kubernetes` | 200, but it is the catalogue page — HTML metadata and WorkBench links, no control text |

So §11 of the assessment enumerates **kube-bench's Apache-2.0 control set**, an
independent implementation of the edition in the same sense that
`dev-sec/cis-dil-benchmark` is for DIL — not a transcription of the CIS document,
and not a reconstruction by the assessment's author. Where kube-bench and the CIS
PDF differ, the PDF is not available here to say so, and
`../cis-level2-hardening.md` §9 item 8 records that as a gap.

### 2.5 ComplianceAsCode/content — distro benchmark cross-reference

| Property | Value |
| --- | --- |
| Commit | `36fb9257b83a67460c1d37ccfc5b9bf3561427b1` |
| Licence | **BSD-3-Clause** (`LICENSE` in the tree; the repository's `NOASSERTION` GitHub label is just missing SPDX detection) |
| Vendored at | `references/complianceascode/` |

| File | URL | HTTP | Bytes | SHA-256 |
| --- | --- | --- | --- | --- |
| `cis_ubuntu2204.yml` | `https://raw.githubusercontent.com/ComplianceAsCode/content/36fb9257b83a67460c1d37ccfc5b9bf3561427b1/controls/cis_ubuntu2204.yml` | 200 | 82,228 | `3726240945cb1e1c5e578175299f25492f08105e8925f951f02476bbcb135659` |
| `LICENSE` | `…/36fb9257…/LICENSE` | 200 | 1,553 | `ade633d5db670a58ff5f735c3602caafc72657a516416969fff79ff8a0c10298` |

Used only to show what a *distro-specific* CIS benchmark looks like where the
DIL benchmark has no equivalent (package-manager and PAM controls), and to
support the "adjacent benchmarks" section. It is **not** the basis of any status.

## 3. Consulted, not vendored

| Source | Why not vendored |
| --- | --- |
| `https://ncp.nist.gov/checklist/1129` (NIST NCP entry, CIS DIL v2.0.0, "Archived") | Metadata only; used to confirm the edition exists and to note the hash mismatch above. |
| `https://www.tenable.com/audits/CIS_Distribution_Independent_Linux_Server_L1_v2.0.0` and `…_L2_v2.0.0` | Proprietary audit files; cited only as evidence that L1/L2 variants of this edition are in circulation. Tenable's "estimated item count" (281 for L1) counts audit items, not benchmark controls, and is not reconciled with the 237 here. |
| `https://raw.githubusercontent.com/wazuh/wazuh/04b678cb/ruleset/sca/generic/sca_distro_independent_linux.yml` | GPL-2.0; a secondary restatement of many checks. Consulted for wording, not copied. |
| `https://github.com/dev-sec/cis-dil-benchmark/issues/67` | Used only to confirm the 2019-07-16 / 572-page release metadata. |
| `https://ubuntu.com/security/cis` (HTTP 200, 133,988 bytes, SHA-256 `cb7b191a141811e23f42faeaa2a570ecebb4437f58cd93a5e92c5957b818fc90`, fetched 2026-10-19) | Canonical's marketing page for Ubuntu Security Guide (USG); it carries no control list and no audit text, so it was not used as a source of any status. Recorded because it was a candidate in the brief. |
| `https://www.cisecurity.org/benchmark/kubernetes` (HTTP 200, 315,892 bytes, SHA-256 `7bdba239354b41f1f5e61bc407437439a8aca1ec3db4651516c64310d310fc2e`, fetched 2026-10-20) | CIS's catalogue page for the Kubernetes benchmark. It establishes the edition (v2.0.1) but carries no control text; cited in §2.4.1, not vendored. |
| `https://workbench.cisecurity.org/…` (sign-in gate, 302 then 429; file endpoint 404) | The CIS WorkBench copy of the Kubernetes PDF could not be obtained. See §2.4.1. |
| `https://paper.bobylive.com/...pdf` and `https://github.com/skylens/CIS/...pdf` | The benchmark itself: fetched to extract facts, **not** vendored (see §4). |

## 4. Why the benchmark PDFs are not in this repository

The CIS Benchmarks are free to download for non-commercial use but are not open
licence. Redistributing the PDF in a source repository is not a use the CIS
terms clearly grant, and a Git history is effectively permanent. The assessment
therefore records **control identifiers, titles, levels and audit/remediation
facts** — which is what an assessment needs — and cites the edition and hash
above instead of shipping the document.

If the project decides it needs the PDF archived (for reproducibility of this
assessment, say), that is a decision for the owner; it was not taken here. The
same applies to the CIS Kubernetes Benchmark PDF, which could not be obtained at
all (§2.4.1), so nothing about it was ever a candidate for vendoring.

## 5. Verification commands

```
# the two mirrors agree (rerun on a machine with network access)
curl -sSL -o /tmp/dil.pdf https://paper.bobylive.com/Security/CIS/CIS_Distribution_Independent_Linux_Benchmark_v2_0_0.pdf
sha256sum /tmp/dil.pdf      # expect 6deafd75b8270141e1368312ff081d4d9792d0f835bbc9e631c919b5c88b359a

# vendored trees
for d in docs/cis/references/*/; do (cd "$d" && sha256sum -c MANIFEST.sha256); done
```
