#!/usr/bin/env python3
# drmtrace-analyze.py - parse a 6s `atrace sched drm sync` capture taken
# during burst5 (pipeline.drmtrace.txt). Answers, in one shot:
#   1) commit rate + nonblock flag seen on drm_atomic_commit lines
#   2) per-commit -> next drm_vblank_event pairing = present->vsync wait ms
#   3) vblank period sanity (panel cadence)
# Usage: python3 drmtrace-analyze.py <trace.txt> [crtc-filter e.g. 31]
import re, sys, collections

path = sys.argv[1]
crtc_f = sys.argv[2] if len(sys.argv) > 2 else None

commit = re.compile(r'(\d+\.\d+):\s+drm_atomic_commit: .*?commit=\w+, nonblock=(\d)')
vblev  = re.compile(r'(\d+\.\d+):\s+drm_vblank_event: (.*)')
tcom, tvb = [], []
nonb = collections.Counter()
for line in open(path, errors='replace'):
    m = commit.search(line)
    if m:
        tcom.append(float(m.group(1))); nonb[m.group(2)] += 1; continue
    m = vblev.search(line)
    if m:
        if crtc_f and f"crtc={crtc_f}" not in m.group(2):
            # tolerate 'pipe'/'crtc' naming variants
            if crtc_f not in m.group(2):
                continue
        tvb.append(float(m.group(1)))

print(f"  commits={len(tcom)}  nonblock-flag {{0:syn,1:async}}={dict(nonb)}  vblank-events={len(tvb)}")
if len(tvb) > 3:
    per = sorted((b-a)*1000 for a, b in zip(tvb, tvb[1:]) if (b-a) < 0.1)
    if per:
        print(f"  vblank period ms: median {per[len(per)//2]:.2f}  p10 {per[len(per)//10]:.2f}  p90 {per[-len(per)//10]:.2f}")
if tcom and tvb:
    import bisect
    waits = []
    for t in tcom:
        i = bisect.bisect_right(tvb, t)
        if i < len(tvb):
            w = (tvb[i]-t)*1000
            if 0 <= w < 120: waits.append(w)
    if waits:
        waits.sort()
        n = len(waits)
        h = collections.Counter(min(int(w//5)*5, 45) for w in waits)
        print(f"  commit->next-vblank wait ms: n={n} median {waits[n//2]:.2f} p90 {waits[int(n*0.9)]:.2f} max {waits[-1]:.2f}")
        for b in sorted(h):
            print(f"    {b:2d}-{b+5:2d}ms {'#'*min(h[b],42)} {h[b]}")
    else:
        print("  no commit/vblank pairs in window")
