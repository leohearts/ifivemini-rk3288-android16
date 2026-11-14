#!/usr/bin/env python3
# final-report.py <run5-dir> [<census-dir>] - assemble the jank decision
# summary from files already on disk. Read-only, single pass, no waiting.
import re, sys, os, glob, statistics as st

def med_j(d, pat):
    v=[]
    for f in glob.glob(os.path.join(d, pat)):
        for L in open(f, errors="replace"):
            m=re.match(r"J=([\d.]+)", L.strip())
            if m: v.append(float(m.group(1)))
    return st.median(v) if v else None

def miss(d, pat):
    v=[]
    for f in glob.glob(os.path.join(d, pat)):
        for L in open(f, errors="replace"):
            m=re.match(r"MISSED_DIFF=(\d+)", L.strip())
            if m: v.append(int(m.group(1)))
    return st.median(v) if v else None

d=sys.argv[1]
dirs=[d]+[a for a in sys.argv[2:]]
print(f"== arms  (Jmedian% / missed-median; dirs: {', '.join(dirs)})")
for lab in ["A3-base-noBoost","A1-strip-boost","A2-strip-noBoost","B2-gate100",
            "A1b-recon-boost","A1d-recon2-boost","A1e-sync","A1e-nonblock",
            "A3c-base-swipe","A1c-strip-swipe","A5-alwaysOn"]:
    js=[med_j(x,lab+"*.txt") for x in dirs]; ms=[miss(x,lab+"*.txt") for x in dirs]
    j=next((q for q in js if q is not None), None); m=next((q for q in ms if q is not None), None)
    if j is not None:
        print(f"  {lab:20s} J={j:5.1f}%  missed={m if m is not None else '-':>6}")
print("== reset-source counts (gpureset files: lines = job-hang / resetting / failed-reset)")
for f in sorted(glob.glob(os.path.join(d,"*.gpureset.txt"))):
    print(f"  {os.path.basename(f):26s} {open(f).read().split()}")
for dd in dirs:
    c=os.path.join(dd,"mali_pm_census.txt")
    if os.path.exists(c):
        L=[x.strip() for x in open(c) if re.match(r"^\s*\d+",x)]
        print(f"== census ({os.path.basename(dd)}): line1=reset-waits line2=vblank-waits -> {L}")
    g=os.path.join(dd,"census.gfx.txt")
    if os.path.exists(g): print("   census gfx:", " | ".join(x.strip() for x in open(g)))
p=os.path.join(d,"A5.policy.txt")
if os.path.exists(p): print("== T7 policy census:", open(p).read().split())
