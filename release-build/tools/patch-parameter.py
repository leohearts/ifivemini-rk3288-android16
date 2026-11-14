#!/usr/bin/env python3
"""patch-parameter.py - remap partitions inside a Rockchip parameter image.

Why: the eMMC of ML5RRJ6M5C developed dead blocks over the physical range
that holds kernel 0xE000..0x16000 (upper 4 MiB..13 MiB) and boot
0x16000..0x18000 (all of it). Writes there report "100%" but read back
0xcc. The recovery area (0x26000, 32 MiB) and the space behind it are
healthy: the GSI boots kernel from 0x26000 (16 MiB) and the boot ramdisk
from 0x2E000 (8 MiB); recovery moves to 0x36000 and backup to
0x3E000@0x12000, cache onward unchanged. The stock firmware's copies in
the backup partition are not needed - the host keeps the full stock backup.

The tool rewrites every PARM structure in the image (parameter-p1.img
holds four copies) with fixed-width replacements inside the mtdparts=
table, so the header size field and the text length never change. It
refuses to run if any replacement would change a length, or if a
partition's new range collides with a neighbour.

usage: patch-parameter.py IN.img OUT.img from=to[,from=to...]
  names refer to the mtdparts entry names; each mapping rewrites the
  entry as <size>@<new_lba>, sizes unchanged except via size=NAME:0x...
"""
import re
import struct
import sys

SECTOR = 512

def parse(text):
    m = re.search(r'mtdparts=[^:\s]+:([^\s"]+)', text)
    if not m:
        raise SystemExit("no mtdparts= table")
    entries = []
    for e in m.group(1).split(","):
        mm = re.fullmatch(r'(0x[0-9a-fA-F]+|-)@(0x[0-9a-fA-F]+)\((\w+)\)', e)
        if not mm:
            raise SystemExit(f"unparsed entry {e!r}")
        esize = None if mm.group(1) == "-" else int(mm.group(1), 16)
        entries.append((esize, int(mm.group(2), 16), mm.group(3), e))
    return m, entries

def patch_image(inp, outp, remap, resize):
    data = bytearray(open(inp, "rb").read())
    n = 0
    pos = 0
    while True:
        pos = data.find(b"PARM", pos)
        if pos < 0:
            break
        size = struct.unpack_from("<I", data, pos + 4)[0]
        text = data[pos + 8: pos + 8 + size]
        try:
            ts = text.decode("ascii")
        except UnicodeDecodeError:
            pos += 4
            continue
        m = re.search(r'mtdparts=[^:\s]+:([^\s"]+)', ts)
        if not m:
            pos += 4
            continue
        new_parts = []
        for esize, eoff, name, orig in parse(ts)[1]:
            if name in resize and esize is not None:
                esize = resize[name]
            eoff2 = remap.get(name, eoff)
            szs = "-" if esize is None else f"0x{esize:08x}"
            new_parts.append(f"{szs}@0x{eoff2:08x}({name})")
        new_table = ",".join(new_parts)
        head = ts[:m.start(1)]
        tail = ts[m.end(1):]
        new_text = (head + new_table + tail).encode("ascii")
        if len(new_text) != size:
            raise SystemExit(f"structure at {hex(pos)}: text length changed {size} -> {len(new_text)}; keep hex fields fixed width")
        # collision check
        spans = []
        for esize, eoff, name, orig in parse(ts)[1]:
            if name in resize and esize is not None:
                esize = resize[name]
            eoff2 = remap.get(name, eoff)
            if esize is None:
                continue  # open-ended tail partition, cannot collide left
            spans.append((eoff2, eoff2 + esize, name))
        spans.sort()
        for (a0, a1, an), (b0, b1, bn) in zip(spans, spans[1:]):
            if a1 > b0:
                raise SystemExit(f"collision: {an} ends {hex(a1)} > {bn} starts {hex(b0)}")
        data[pos + 8: pos + 8 + size] = new_text
        n += 1
        pos += 8 + size
    if n == 0:
        raise SystemExit("no PARM structure with mtdparts found")
    open(outp, "wb").write(bytes(data))
    print(f"patched {n} PARM structure(s): {inp} -> {outp}")

def main():
    a = sys.argv[1:]
    if len(a) < 3:
        raise SystemExit(__doc__)
    inp, outp, spec = a[0], a[1], a[2]
    remap, resize = {}, {}
    for item in spec.split(","):
        if "=" in item and "(" not in item and ":" not in item:
            # kernel=0x26000 style remap
            name, dst = item.split("=", 1)
            remap[name] = int(dst, 0)
        elif item.startswith("size="):
            name, sz = item[5:].split(":", 1)
            resize[name] = int(sz, 0)
        else:
            raise SystemExit(f"bad mapping {item!r}; use name=0xLBA or size=NAME:0xSECTORS")
    patch_image(inp, outp, remap, resize)

main()
