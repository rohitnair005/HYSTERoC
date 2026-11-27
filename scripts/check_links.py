#!/usr/bin/env python3
"""Check that relative links in README/docs markdown resolve (no network)."""
import os, re, sys
bad = []
for dirpath, _, files in os.walk("."):
    if ".git" in dirpath or "sim/run" in dirpath:
        continue
    for f in files:
        if not f.endswith(".md"):
            continue
        p = os.path.join(dirpath, f)
        for m in re.finditer(r'\]\(([^)]+)\)', open(p).read()):
            tgt = m.group(1).split("#")[0]
            if not tgt or tgt.startswith("http"):
                continue
            if not os.path.exists(os.path.join(os.path.dirname(p), tgt)):
                bad.append(f"{p}: {tgt}")
print("docs links OK" if not bad else "\n".join(bad))
sys.exit(1 if bad else 0)
