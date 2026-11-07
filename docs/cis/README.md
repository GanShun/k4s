# CIS reference material for the k4s node assessment

This directory holds the **sources and derived inventory** behind
[`../cis-level2-hardening.md`](../cis-level2-hardening.md). The assessment itself
is the document one level up; this directory is its evidence.

## What is here

| Path | What it is |
| --- | --- |
| `SOURCES.md` | Provenance for everything below: source URL, HTTP status, byte count, SHA-256, fetch date, licence, and what could **not** be obtained. Read this first. |
| `dil-2.0.0-controls.tsv` | Derived inventory of the **237** control identifiers, titles, levels and scored flags from CIS Distribution Independent Linux Benchmark v2.0.0 (2019-07-16). Body text is deliberately not reproduced. |
| `render-summary.py` | Regenerates **both** summary tables and both tallies in the assessment, from the controls in the document and the two inventories. `python3 docs/cis/render-summary.py`. |
| `references/dev-sec-cis-dil-benchmark/` | Apache-2.0 InSpec profile implementing the same benchmark edition. The independent cross-check that the enumeration is complete (237/237) and the levels match (192 L1 / 45 L2). |
| `references/dev-sec-linux-baseline/` | Apache-2.0 InSpec baseline, consulted for sysctl and mount-option wording. Not a CIS mapping. |
| `references/dev-sec-ssh-baseline/` | Apache-2.0 InSpec SSH baseline, consulted to make the "no `sshd_config` here" finding concrete. |
| `references/kube-bench/` | Apache-2.0 CIS Kubernetes control set (`cfg/cis-2.0` plus the `cfg/config.yaml` edition mapping). **The enumerating text for the second benchmark**, assessed in §11 of the assessment — not transcribed or reconstructed. |
| `references/complianceascode/` | BSD-3-Clause CIS Ubuntu 22.04 control mapping, vendored only as an example of a distro-specific benchmark. Not the basis of any status. |

Every vendored tree has a `MANIFEST.sha256`; verify with
`(cd references/<tree> && sha256sum -c MANIFEST.sha256)`.

## Two benchmarks, two tallies

The assessment reports **CIS Distribution Independent Linux v2.0.0 Level 2 -
Server** (237 controls) and the **CIS Kubernetes Benchmark v2.0.1, worker-node
sections only** (27 controls) — decision D1 in the document. They are enumerated
and tallied separately and are never combined into one number (D3). The DIL
inventory is the TSV above; the Kubernetes inventory is the vendored kube-bench
YAML, which `render-summary.py` also cross-checks the document against, control by
control (identifier, title and `scored` flag).

## The benchmark copies are not in this repository

The CIS Distribution Independent Linux Benchmark is free to download but is not
open-licence, so the PDF is **not** committed. The assessment cites the edition,
page count (572), byte count and SHA-256 of the copy used, and says plainly that
it came from third-party mirrors rather than from CIS. See `SOURCES.md` §1 and §4
for why, for the one hash mismatch that could not be resolved, and for what was
tried (the official sites are behind a 403, a redirect loop and a JS consent
gate).

The **CIS Kubernetes Benchmark PDFs could not be obtained at all**, v2.0.1 and
the newer v2.1.0 alike: CIS WorkBench is a sign-in gate and both file endpoints
return 404 (`SOURCES.md` §2.4.1). Their control identifiers, titles and audits are
therefore taken from kube-bench's Apache-2.0 control set, which upstream states
implements v2.0.1 — recorded as such, not presented as the CIS document.

Control **identifiers, titles and levels** are recorded here because an
assessment needs to name what it assessed; the audit and remediation *facts* are
summarised in the assessment with citations, not reproduced verbatim.

## Editions

- **CIS Distribution Independent Linux Benchmark v2.0.0, 2019-07-16.** No newer
  edition was found (CIS's 2026 update posts do not list one; NIST NCP marks v2.0.0
  archived). If a newer edition exists, this material is against the wrong one.
- **CIS Kubernetes Benchmark v2.0.1**, which kube-bench implements for Kubernetes
  1.34–1.35 and the node's kubelet is 1.35.8. See `SOURCES.md` §2.4.1 for the
  three facts that establish it. **v2.1.0** (2026-09-30) is newer; its PDF is
  equally unobtainable and no kube-bench control set implements it, so it was not
  enumerated — that gap is recorded, not filled.

Questions about either edition are in the assessment's §10.
