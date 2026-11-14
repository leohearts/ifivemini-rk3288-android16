#!/usr/bin/env python3
"""analyze-run.py - summarize one jank test-run directory into a decision table.

Usage: analyze-run.py <dir>   (dir = out/tmp/jankwork/<...> or the results dir
printed by ab-test.sh / pipeline-measure.sh / resume-jank-test.sh)

For each arm file "LABEL.txt": median J%, N stability, the freq histogram
("-- freq samples" section), trans_stat "Total" line after the burst.
For diag files "LABEL.logcat.txt": the HAL decision counts.
Then applies the pre-registered rules (docs/jank-test-plan.md) and prints
the recommended next step. Read-only; prints; exit 0 always.
"""
import sys, os, re, glob, statistics

def parse_arm(path):
    txt = open(path, errors="ignore").read()
    js = [float(x) for x in re.findall(r"^J=([\d.]+)$", txt, re.M)]
    ns = [int(x) for x in re.findall(r"^N=(\d+)", txt, re.M)]
    freq = {}
    m = re.search(r"-- freq samples \(10Hz\):(.*)", txt, re.S)
    if m:
        for cnt, hz in re.findall(r"^\s*(\d+)\s+(\d{9})$", m.group(1), re.M):
            freq[hz] = freq.get(hz, 0) + int(cnt)
    miss = re.findall(r"MISSED_DIFF=(\d+)", txt)
    ts = re.findall(r"Transitions (Total )?(\d+)", txt)
    return js, ns, freq, miss, bool(ts)

def main(d):
    arms = sorted(glob.glob(os.path.join(d, "*.txt")))
    arms = [a for a in arms if not a.endswith((".logcat.txt", ".framestats.txt",
             ".freq.txt", ".transstat.txt", ".ctx.txt", ".burst.txt"))]
    print(f"{'arm':34s} {'nJ':>3s} {'Jmed%':>7s} {'Jrange':>14s} {'Nset':>8s} top-freq(MHz)xcount  missed")
    j_by_prefix = {}
    for a in arms:
        js, ns, freq, miss, _ = parse_arm(a)
        if not js:
            continue
        name = os.path.basename(a)[:-4]
        top = sorted(freq.items(), key=lambda kv: -kv[1])[:2]
        tops = " ".join(f"{int(f)//1000000}MHzx{c}" for f, c in top) or "-"
        print(f"{name:34s} {len(js):3d} {statistics.median(js):7.1f} "
              f"{min(js):5.1f}-{max(js):5.1f} {str(sorted(set(ns))):>8s} {tops:22s} {','.join(miss) or '-'}")
        j_by_prefix.setdefault(name.split("-r")[0], []).extend(js)
    # diag counts
    for a in sorted(glob.glob(os.path.join(d, "*.logcat.txt"))):
        txt = open(a, errors="ignore").read()
        counts = re.findall(r"^\s{2}(\d{1,2}\s?\w.*)", txt, re.M)
        head = [l for l in txt.splitlines() if "=" in l and not l.startswith(" ")]
        print(f"\n{os.path.basename(a)}:")
        for l in txt.splitlines():
            if re.match(r"\s+\d", l) and any(k in l for k in ("GLES", "fail match", "so big", "skip-all", "is_afbc", "global alpha")):
                print("  " + l.strip())
    # pre-registered rules
    print("\n== rule check ==")
    def med(p): 
        v = [x for k, vv in j_by_prefix.items() if k.startswith(p) for x in vv]
        return statistics.median(v) if v else None
    a3, a1 = med("A3-base"), med("A1-strip")
    if a3 and a1:
        print(f"  fix effect (same protocol): BASE {a3:.1f}% -> STRIP {a1:.1f}% ({a3-a1:+.1f} pts)")
        print("  RULE 'A1 <= A3-30':", "PASS" if a1 <= a3-30 else "FAIL")
    a1c, a3c = med("A1c-strip-swipe"), med("A3c-base-swipe")
    if a1c and a3c:
        print(f"  swipe protocol: BASE {a3c:.1f}% -> STRIP {a1c:.1f}%; AOSP-era reference 6.9-7.2%")
    # rules pre-registered 2026-11-13 for the new levers:
    for lbl, base, note in (("A1b",           "A1-strip",    "rebuild equivalence: |diff|<=3 pts"),
                            ("A1d",           "A1-strip",    "plane-merge port: expect <=, never >3 worse"),
                            ("A1e-nonblock", "A1e-sync",    "NONBLOCK gain: this delta = vblank-wait share"),
                            ("A5-alwaysOn",  "A1-strip",    "power-cycle cost: this delta = per-frame PM share")):
        m1, m0 = med(lbl), med(base)
        if m1 and m0:
            print(f"  {lbl} vs {base}: {m0:.1f}% -> {m1:.1f}% ({m0-m1:+.1f} pts)  [{note}]")
    # mali PM census (from pipeline dir; absent here if dirs differ):
    cen = os.path.join(d, "mali_pm_census.txt")
    if os.path.exists(cen):
        lines = [L.strip() for L in open(cen, errors="replace") if L.strip()]
        print(f"  census: {lines}  (burst ~5.5s -> transitions/s = count/5.5)")
    # diag pair-merge functional evidence: echo the count blocks from diags
    import re as _re
    for f in sorted(glob.glob(os.path.join(d, "*.logcat.txt"))):
        txt = open(f, errors="replace").read()
        m = _re.search(r"== HAL decision counts.*", txt, _re.S)
        if m and "A1d" in os.path.basename(f) or m and "A1e" in os.path.basename(f):
            head = [L for L in m.group(0).splitlines() if ("pair" in L or "size distribution" in L or _re.search(r"^\s+\d", L))][:12]
            print(f"  -- diag {os.path.basename(f)} --")
            for L in head: print("    " + L.rstrip()[:78])
    # freq verdict
    for a in arms:
        js, ns, freq, miss, _ = parse_arm(a)
        if freq and "A1" in os.path.basename(a):
            hi = sum(c for f, c in freq.items() if int(f) >= 500000000)
            lo = sum(c for f, c in freq.items() if int(f) < 300000000)
            if hi == 0:
                print(f"  {os.path.basename(a)}: GPU NEVER above 300MHz while busy -> kbase/clock path is the target")
            elif lo == 0 and hi > 0:
                print(f"  {os.path.basename(a)}: GPU held high; jank persists -> composition/content, not clock")
    print(f"\nraw files: {d}")

if __name__ == "__main__":
    if len(sys.argv) == 2 and os.path.isdir(sys.argv[1]):
        main(sys.argv[1])
    else:
        print(__doc__)
