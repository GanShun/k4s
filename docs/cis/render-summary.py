#!/usr/bin/env python3
"""Regenerate both summary tables and both tallies in ../cis-level2-hardening.md.

The document is the source of truth: each control subsection carries a line
`**Status.** `<value>``, and this script reads those lines, cross-checks them
against the derived inventory (dil-2.0.0-controls.tsv for the Distribution
Independent Linux benchmark, the vendored kube-bench YAML for the Kubernetes
one) and rewrites the two tables between their marker pairs. The two benchmarks
are rendered separately and are never combined: that is decision D3 in the
document. Run from anywhere:

    python3 docs/cis/render-summary.py
"""

import os
import re
import sys
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
DOC = os.path.join(HERE, "..", "cis-level2-hardening.md")
TSV = os.path.join(HERE, "dil-2.0.0-controls.tsv")
KUBE = os.path.join(HERE, "references", "kube-bench", "cfg", "cis-2.0")

DIL_START = "<!-- SUMMARY-TABLE-START -->"
DIL_END = "<!-- SUMMARY-TABLE-END -->"
K8S_START = "<!-- K8S-SUMMARY-TABLE-START -->"
K8S_END = "<!-- K8S-SUMMARY-TABLE-END -->"

STATUSES = ["comply", "partial", "non-compliant", "not applicable", "infeasible by design"]

# A DIL heading looks like:  #### 1.1.1 Ensure ... — `L1`, scored
DIL_HEADING = re.compile(r"^#### (\d+(?:\.\d+)+) (.*?) — `L([12])`, (scored|not scored)\n(.*?)(?=^#### |^### |\Z)", re.M | re.S)
# A Kubernetes heading looks like:  #### 4.1.1 Ensure ... — scored
K8S_HEADING = re.compile(r"^#### (\d+(?:\.\d+)+) (.*?) — (scored|not scored)$", re.M)


def status_of(body: str) -> str:
    m = re.search(r"\*\*Status\.\*\* `([^`]+)`", body)
    if not m:
        return None
    if m.group(1) not in STATUSES:
        return f"UNKNOWN:{m.group(1)}"
    return m.group(1)


def render(inventory, status, mid_label, extra=None):
    """Build one table plus its tally block from an ordered inventory."""
    rows = [f"| ID | Control | {mid_label} | Status |", "| --- | --- | --- | --- |"]
    for cid, title, mid, level in inventory:
        safe = title.replace("|", "\\|")
        midcell = level if mid_label == "Level" else f"`{level}`"
        rows.append(f"| {cid} | {safe} | {midcell} | `{status[cid]}` |")

    tally = Counter(status.values())
    out = rows + [""]
    if extra:
        out += [extra, ""]
    out += ["| Status | Count |", "| --- | --- |"]
    for name in STATUSES:
        out.append(f"| `{name}` | {tally[name]} |")
    out.append(f"| **total** | **{len(inventory)}** |")
    return "\n".join(out), tally


def parse_kube_yaml():
    """(id -> (title, scored)) from the vendored kube-bench control sets."""
    controls = {}
    for name in ("node.yaml", "policies.yaml"):
        path = os.path.join(KUBE, name)
        text = open(path, encoding="utf-8").read()
        for block in re.split(r"\n      - id: ", text)[1:]:
            cid = block.split("\n", 1)[0].strip()
            title = re.search(r'\n        text: "(.*)"\n', block)
            scored = re.search(r"\n        scored: (true|false)", block)
            if not title or not scored:
                print(f"error: cannot parse {name} control {cid}", file=sys.stderr)
                return None
            # The YAML records the automation marker in the title; the document
            # titles stop at the em dash.
            clean = re.sub(r" \((Automated|Manual)\)$", "", title.group(1))
            controls[cid] = (clean, "scored" if scored.group(1) == "true" else "not scored")
    return controls


def main() -> int:
    doc = open(DOC, encoding="utf-8").read()

    # ---- Distribution Independent Linux -------------------------------------
    inventory = []
    for line in open(TSV, encoding="utf-8"):
        if line.startswith("#"):
            continue
        cid, level, scored, title = line.rstrip("\n").split("\t")
        inventory.append((cid, title, "Level", f"L{level}"))

    dil_status = {}
    for m in DIL_HEADING.finditer(doc):
        st = status_of(m.group(5))
        if not st:
            print(f"error: {m.group(1)} has no status line", file=sys.stderr)
            return 1
        if st.startswith("UNKNOWN"):
            print(f"error: {m.group(1)} has unknown status {st[8:]}", file=sys.stderr)
            return 1
        dil_status[m.group(1)] = st

    ids = {c[0] for c in inventory}
    missing = [c[0] for c in inventory if c[0] not in dil_status]
    extra = [c for c in dil_status if c not in ids]
    if missing or extra:
        print(f"error: DIL missing={missing} extra={extra}", file=sys.stderr)
        return 1

    l1 = sum(1 for c in inventory if c[3] == "L1")
    l2 = sum(1 for c in inventory if c[3] == "L2")
    dil_extra = (
        f"**{len(inventory)} controls, all in the Level 2 - Server profile** "
        f"({l1} Level 1 items and {l2} Level 2 items)."
    )
    dil_table, dil_tally = render(inventory, dil_status, "Level", dil_extra)

    # ---- CIS Kubernetes -----------------------------------------------------
    # Scope the Kubernetes headings to §11 so nothing earlier can be picked up.
    k8s_at = doc.find("\n## 11. CIS Kubernetes Benchmark")
    if k8s_at < 0:
        print("error: cannot find the Kubernetes section (## 11.)", file=sys.stderr)
        return 1
    k8s_text = doc[k8s_at:]

    kube = parse_kube_yaml()
    if kube is None:
        return 1

    k8s_inventory = []
    k8s_status = {}
    heads = list(K8S_HEADING.finditer(k8s_text))
    for i, m in enumerate(heads):
        cid, title, scored = m.group(1), m.group(2), m.group(3)
        body_end = heads[i + 1].start() if i + 1 < len(heads) else len(k8s_text)
        body = k8s_text[m.end():body_end]
        if cid not in kube:
            print(f"error: {cid} is not in the vendored kube-bench control set", file=sys.stderr)
            return 1
        if (title, scored) != kube[cid]:
            print(
                f"error: {cid} differs from kube-bench: doc={(title, scored)!r} "
                f"yaml={kube[cid]!r}",
                file=sys.stderr,
            )
            return 1
        st = status_of(body)
        if not st:
            print(f"error: {cid} has no status line", file=sys.stderr)
            return 1
        if st.startswith("UNKNOWN"):
            print(f"error: {cid} has unknown status {st[8:]}", file=sys.stderr)
            return 1
        k8s_inventory.append((cid, title, "Scored", scored))
        k8s_status[cid] = st

    if not k8s_inventory:
        print("error: no Kubernetes controls found in §11", file=sys.stderr)
        return 1

    node_ids = {c for c, (_, _) in kube.items() if c.startswith("4.")}
    missing = sorted(node_ids - set(k8s_status))
    if missing:
        print(f"error: worker-node controls not enumerated: {missing}", file=sys.stderr)
        return 1

    sections = Counter(c.split(".")[0] for c in k8s_status)
    k8s_extra = (
        f"**{len(k8s_inventory)} controls, reported separately from the DIL tally "
        f"above** ({sections['4']} from the worker-node sections 4.x and "
        f"{sections['5']} cluster-level policy controls a node can satisfy on its "
        f"own: 5.3.1 and 5.6.2)."
    )
    k8s_table, k8s_tally = render(k8s_inventory, k8s_status, "Scored", k8s_extra)

    # ---- rewrite both blocks ------------------------------------------------
    for start, end, table, name in (
        (DIL_START, DIL_END, dil_table, "DIL"),
        (K8S_START, K8S_END, k8s_table, "Kubernetes"),
    ):
        if start not in doc or end not in doc:
            print(f"error: {name} markers not found", file=sys.stderr)
            return 1
        doc = re.sub(
            re.escape(start) + r".*?" + re.escape(end),
            start + "\n" + table + "\n" + end,
            doc,
            count=1,
            flags=re.S,
        )
    open(DOC, "w", encoding="utf-8").write(doc)

    print(f"DIL: {len(inventory)} rows; tally: { {s: dil_tally[s] for s in STATUSES} }")
    print(f"Kubernetes: {len(k8s_inventory)} rows; tally: { {s: k8s_tally[s] for s in STATUSES} }")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
