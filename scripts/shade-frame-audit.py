#!/usr/bin/env python3
"""shade-frame-audit.py - decide from an atrace what the pull-down costs.

Usage:
    shade-frame-audit.py trace.txt                 # single capture report
    shade-frame-audit.py --compare a.txt b.txt     # before/after verdict

All measurements are per owning pid of each atrace slice, which is what the
earlier analysis got wrong: a `Drawing x y w h` slice belongs to the process
whose RenderThread drew that window, NOT to SurfaceFlinger (SF's composition
pass emits no `Drawing` slice). The process that traces `traversal` and
`VRI[NotificationShade]` is SystemUI; `Drawing` slices >3 ms from any OTHER
pid during pull-down are the GPU-queue contention this device suffers from
(split-shade drawer bands: the exposed strip of the app behind, and the
taskbar strip under the drawer).

Reports per capture:
  - SystemUI main-thread frame-gap distribution (traversal windows)
  - band Drawing counts by pid (non-SystemUI), with medians
  - gap overlap with SystemUI's own big Drawing (self-contention, expected)
Exit: 0 no band redraws, 3 few, 2 many (GLES/drawer signature present).
"""
import re
import sys
import statistics
from collections import defaultdict

PAT = re.compile(
    r'\(\s*\d+\)\s+\[\s*\d+\]\s+\S+\s+(\d+\.\d+):\s+tracing_mark_write:\s'
    r'([BEX])\|(\d+)\|?(.*)')


def scan(path):
    """Return (traversal_windows, drawings_by_pid, sysui_pid)."""
    trav = []
    draws = defaultdict(list)   # pid -> [(start, dur_ms, shape)]
    stacks = defaultdict(list)
    sysui = None
    with open(path, errors='replace') as f:
        for line in f:
            m = PAT.search(line)
            if not m:
                continue
            ts, typ, pid, body = (float(m.group(1)), m.group(2),
                                  m.group(3), m.group(4))
            if typ == 'B':
                stacks[pid].append((body, ts))
                if sysui is None and 'VRI[NotificationShade]' in body:
                    sysui = pid
            elif typ == 'E':
                s = stacks[pid]
                if not s:
                    continue
                b0, t0 = s.pop()
                d = (ts - t0) * 1000
                if b0 == 'traversal' and pid == sysui:
                    trav.append((t0, ts))
                elif b0.startswith('Drawing') and d > 3:
                    mm = re.match(r'Drawing\s+([0-9.]+)\s+([0-9.]+)\s+'
                                  r'([0-9.]+)\s+([0-9.]+)', b0)
                    shape = 'FULL'
                    if mm:
                        x0, y0, x1, y1 = map(float, mm.groups())
                        w, h = x1 - x0, y1 - y0
                        if w > 1000 and h < 300:
                            shape = 'STRIP'      # taskbar strip
                        elif h > 1000 and w < 1000:
                            shape = 'BAND'       # drawer-exposed band
                    draws[pid].append((t0, d, shape))
    return trav, draws, sysui


def report(path):
    trav, draws, sysui = scan(path)
    if sysui is None:
        print('  no VRI[NotificationShade] slice found - wrong capture?')
        return None
    if not trav:
        print('  no completed SystemUI traversal windows')
        return None
    gaps = []
    prev = None
    for t0, t1 in sorted(trav):
        if prev:
            g = (t0 - prev[1]) * 1000
            if 0.5 < g < 100:
                gaps.append(g)
        prev = (t0, t1)
    n = len(gaps)
    slow = sum(1 for g in gaps if g > 24)
    print(f'  file={path}')
    print(f'  SystemUI pid={sysui} frame-pairs={n} '
          f'gap med={statistics.median(gaps):.1f}ms '
          f'p90={sorted(gaps)[int(n*.9)]:.1f}ms '
          f'slow(>24ms)={slow} ({100*slow//max(n,1)}%)')
    band_total = 0
    for pid, ds in sorted(draws.items(), key=lambda kv: -len(kv[1])):
        if pid == sysui:
            continue
        occ = [x for x in ds if x[2] in ('STRIP', 'BAND')]
        med = statistics.median([d for _, d, _ in occ]) if occ else 0
        shapes = {s: sum(1 for x in ds if x[2] == s) for s in ('STRIP', 'BAND', 'FULL')}
        print(f'  contention pid={pid}: STRIP={shapes["STRIP"]} '
              f'BAND={shapes["BAND"]} FULL={shapes["FULL"]} '
              f'med(occ)={med:.1f}ms')
        band_total += len(occ)
    sd = draws.get(sysui, [])
    print(f'  SystemUI own big draws: n={len(sd)} '
          f'med={statistics.median([d for _, d, _ in sd]) if sd else 0:.1f}ms')
    print(f'  CONTENTION_TOTAL={band_total}')
    return band_total


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 1
    if args[0] == '--compare':
        a = report(args[1])
        b = report(args[2])
        if a is None or b is None:
            return 1
        if a == 0:
            print('VERDICT: cannot judge (before had no contention draws)')
            return 1
        frac = b / a
        verdict = ('PASS' if frac <= 0.2 else
                   'PARTIAL' if frac <= 0.6 else 'FAIL')
        print(f'VERDICT: {verdict} - contention draws {a} -> {b} '
              f'({100*frac:.0f}% remaining)')
        return 0 if verdict == 'PASS' else 2
    v = report(args[0])
    if v is None:
        return 1
    return 0 if v == 0 else (3 if v < 30 else 2)


if __name__ == '__main__':
    sys.exit(main())
