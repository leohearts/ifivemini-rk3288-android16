#!/usr/bin/env python3
# slice-table.py <atrace.txt> [tid-filter] - strict same-thread B/E LIFO
# slice durations for an atrace text dump. One command, read-only.
import re, sys, collections

if len(sys.argv) < 2:
    print("usage: slice-table.py <atrace.txt> [tid-filter]"); sys.exit(0)

ln = re.compile(r'^\s*([\w:.<>-]+)-(\d+)\s+\(\s*(-?\d+)\)\s+\[\w+\]\s+\S+\s+([\d.]+):\s+tracing_mark_write:\s+([BEC])\|(\d+)\|?(.*)$')
stack = collections.defaultdict(list)
durs = collections.Counter(); cnt = collections.Counter(); top = collections.Counter()
tf = sys.argv[2] if len(sys.argv) > 2 else None
n = 0
for line in open(sys.argv[1], errors="replace"):
    m = ln.match(line)
    if not m: continue
    n += 1
    tid, ts, kind, rest = m.group(2), float(m.group(4)), m.group(5), m.group(7).strip()
    if tf and tid != tf: continue
    if kind == "B": stack[tid].append((rest, ts))
    elif kind == "E" and stack[tid]:
        name, ts0 = stack[tid].pop(); d = ts - ts0
        k = name.split('/')[0][:40]
        durs[k] += d; cnt[k] += 1
        if d > top[k]: top[k] = d
print(f"  mark-write lines parsed: {n}")
print(f"  {'slice':40s} {'n':>5s} {'avg(ms)':>8s} {'max(ms)':>8s}")
for k, s in durs.most_common(16):
    print(f"  {k:40s} {cnt[k]:5d} {1000*s/cnt[k]:8.2f} {1000*top[k]:8.1f}")
