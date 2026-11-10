#!/usr/bin/env python3
"""shade-frame-audit.py - decide from an atrace what the pull-down costs.

Usage:
    shade-frame-audit.py trace.txt                 # single capture report
    shade-frame-audit.py --compare a.txt b.txt     # before/after verdict

Pitfalls this tool exists to avoid (all learned from mis-reads of these
traces, see reports/ShadeJankTrace1110.md):
  - Pair B/E slices PER THREAD (the ftrace line's comm-tid), not per pid:
    a process has a main thread and a RenderThread both tracing, and
    cross-thread pairing fabricates 12 ms "median" durations for slices
    that are actually 0.3 ms.
  - A `Drawing x y w h` slice belongs to the process that drew that
    window on its RenderThread. SurfaceFlinger's composition pass emits
    no `Drawing` slice - never attribute a Drawing to SF by its size.
  - The decisive cadence number is the app-side buffer RELEASE rate
    (releaseBufferCallback intervals per surface): that is how fast SF
    consumes frames, and it is where the old HWC's GLES pass showed up
    (median release gap 26-32 ms for VRI[NotificationShade] instead of
    16.6).

Decision table after the HWC/split-shade changes:
  release med ~16.6 + slow% low        -> fixed, done.
  release med >24 still                -> SF side still slow: check the
                                          hwc validate logs (downgrades?).
  release ok but shade Drawing slow    -> app-side raster: GPU clock or
                                          damage size, not SF.
Exit: 0 = release cadence healthy, 2 = old signature still present.
"""
import re
import sys
import statistics
from collections import defaultdict

# tid, timestamp, type, pid-marker, body
PAT = re.compile(
    r'\S+-(\d+)\s+\(\s*\d+\)\s+\[\s*\d+\]\s+\S+\s+(\d+\.\d+):\s'
    r'tracing_mark_write:\s([BEX])\|(\d+)\|?(.*)')


def scan(path):
    trav = []                      # SystemUI main-thread traversal windows
    draws = defaultdict(list)      # pid -> [(start, dur_ms, shape)]
    rels = defaultdict(list)       # surface name -> release ts
    stacks = defaultdict(list)     # tid -> [(body, ts)]
    sysui = None
    with open(path, errors='replace') as f:
        for line in f:
            m = PAT.search(line)
            if not m:
                continue
            tid, ts, typ, pid, body = (m.group(1), float(m.group(2)),
                                       m.group(3), m.group(4), m.group(5))
            if typ == 'B':
                stacks[tid].append((body, ts))
                if sysui is None and 'VRI[NotificationShade]' in body:
                    sysui = pid
            elif typ == 'E':
                s = stacks[tid]
                if not s:
                    continue
                b0, t0 = s.pop()
                d = (ts - t0) * 1000
                if b0 == 'traversal' and pid == sysui:
                    trav.append((t0, ts, tid))
                elif b0.startswith('Drawing') and d > 3:
                    mm = re.match(r'Drawing\s+([0-9.]+)\s+([0-9.]+)\s+'
                                  r'([0-9.]+)\s+([0-9.]+)', b0)
                    shape = 'FULL'
                    if mm:
                        x0, y0, x1, y1 = map(float, mm.groups())
                        w, h = x1 - x0, y1 - y0
                        if w > 1000 and h < 300:
                            shape = 'STRIP'
                        elif h > 1000 and w < 1000:
                            shape = 'BAND'
                    draws[pid].append((t0, d, shape))
                elif b0.startswith('releaseBufferCallback'):
                    mv = re.search(r'(VRI\[[^\]]+\])', b0)
                    if mv:
                        rels[mv.group(1)].append(ts)
    release_gaps = {}
    for name, v in rels.items():
        v.sort()
        g = [(b - a) * 1000 for a, b in zip(v, v[1:])
             if 0.5 < (b - a) * 1000 < 100]
        if len(g) >= 10:
            release_gaps[name] = g
    return trav, draws, sysui, release_gaps


def report(path):
    trav, draws, sysui, rels = scan(path)
    if sysui is None:
        print(f'  {path}: no VRI[NotificationShade] - wrong capture?')
        return None
    print(f'  file={path} SystemUI pid={sysui}')
    ok = True
    shade = rels.get('VRI[NotificationShade]')
    if shade:
        med = statistics.median(shade)
        slow = sum(1 for g in shade if g > 24) * 100 // len(shade)
        print(f'  shade release cadence: n={len(shade)} med={med:.1f}ms '
              f'slow(>24ms)={slow}%')
        ok = med <= 20
    for name, g in sorted(rels.items(), key=lambda kv: -len(kv[1]))[:3]:
        if name == 'VRI[NotificationShade]':
            continue
        print(f'  {name}: n={len(g)} med={statistics.median(g):.1f}ms')
    contention = 0
    for pid, ds in sorted(draws.items(), key=lambda kv: -len(kv[1])):
        if pid == sysui:
            continue
        occ = [x for x in ds if x[2] in ('STRIP', 'BAND')]
        if occ:
            med = statistics.median([d for _, d, _ in occ])
            print(f'  contention pid={pid}: STRIP/BAND={len(occ)} '
                  f'med={med:.1f}ms')
            contention += len(occ)
    own = draws.get(sysui, [])
    if own:
        print(f'  SystemUI big draws: n={len(own)} '
              f'med={statistics.median([d for _, d, _ in own]):.1f}ms')
    print(f'  CONTENTION_TOTAL={contention} CADENCE_OK={ok}')
    return contention, ok


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
        ca, oa = a
        cb, ob = b
        if ob and oa:
            print('VERDICT: both captures cadence-healthy')
            return 0
        if ob and not oa:
            print('VERDICT: PASS - SF consumption cadence restored')
            return 0
        if not ob and not oa:
            print('VERDICT: FAIL - release cadence still >20 ms median '
                  'after the changes (check hwc downgrade counters)')
            return 2
        print('VERDICT: REGRESSION - cadence was healthy before, not after')
        return 2
    r = report(args[0])
    if r is None:
        return 1
    return 0 if r[1] else 2


if __name__ == '__main__':
    sys.exit(main())
