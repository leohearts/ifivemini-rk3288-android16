#!/usr/bin/env python3
"""Parse a kpanic RKLOGDP1 dump (the 4 MiB kpanic partition, or a file with the same bytes).

Layout (matches drivers/soc/rockchip/rk_logdump.c, version 2):
  0x000 "RKLOGDP1", 0x008 u32 version, 0x00c u32 reason_off (512),
  0x010 u32 reason_len, 0x014 u32 log_buf_len, 0x018 u32 payload_len,
  0x01c u32 payload_off (1024), 0x020 u64 local_clock ns, 0x028 u32 sect_off,
  0x02c u32 sect_len, 0x030 u32 seq (0 = one-shot), 0x038 u64 boottime ns,
  0x200 reason (NUL terminated), 0x400 raw printk ring (payload_len bytes).
  Sections at sect_off: 512-byte sub-header ("RKRAMOP1" / "RKPREVC1",
  u32 version=1 at 0x08, u64 phys at 0x10, u32 data_len at 0x18, u32 total_len
  at 0x1c) followed by data rounded up to 512 bytes.

The printk ring holds struct printk_log records (16-byte header: u64 ts_nsec,
u16 len, u16 text_len, u16 dict_len, u8 facility, u8 flags:5/level:3; then text,
then dict; len is 4-byte aligned, len == 0 is padding). CONFIG_PRINTK_PROCESS is
off in both kernel configs, so no process fields are present.

Ring recovery is best effort. The chain from offset 0 gives the newest records
(up to the write position). The older part after the wrap is found by scanning
forward for a run of at least 3 consistent records. Records that were overwritten
only in part can still show up as stale entries, so they are sorted by timestamp
and reported with the source chain they came from.

Usage: parse-logdump.py <kpanic.bin> [-o OUTDIR]
"""
import argparse
import os
import struct
import sys

MAGIC = b"RKLOGDP1"
HDR = 0x200
REASON_AREA = 512
PAYLOAD_OFF = 0x400
SECT_HDR = 512
SECT_MAGICS = (b"RKRAMOP1", b"RKPREVC1")
PART_BYTES = 4 * 1024 * 1024
REC_HDR = 16
ALIGN = 4


def roundup(v, a):
    return (v + a - 1) // a * a


def decode_record(buf, off, n):
    """Return (ts, text_bytes) for a valid record at off, or None."""
    if off + REC_HDR > n:
        return None
    ts, ln, tl, dl, _fac, _lv = struct.unpack_from("<QHHHBB", buf, off)
    if ln < REC_HDR or ln % ALIGN or off + ln > n or REC_HDR + tl + dl > ln:
        return None
    if ts == 0:
        return None
    return ts, bytes(buf[off + REC_HDR: off + REC_HDR + tl])


def walk_chain(buf, n, start, out, tag):
    """Follow records from start; append to out. Return (end_offset, count)."""
    off = start
    count = 0
    while True:
        rec = decode_record(buf, off, n)
        if rec is None:
            return off, count
        out.append((rec[0], off, tag, rec[1]))
        count += 1
        off += struct.unpack_from("<H", buf, off + 8)[0]
        if off >= n:
            return off, count


def chain_ok(buf, n, start, need=3):
    """True if at least `need` consecutive valid records start at `start`."""
    off = start
    for _ in range(need):
        rec = decode_record(buf, off, n)
        if rec is None:
            return False
        off += struct.unpack_from("<H", buf, off + 8)[0]
    return True


def decode_ring(buf):
    """Return a list of (ts, offset, source, text) sorted by timestamp."""
    n = len(buf)
    recs = []
    end, newest = walk_chain(buf, n, 0, recs, "newest")
    old = 0
    p = roundup(end, ALIGN)
    while p + REC_HDR <= n:
        if chain_ok(buf, n, p):
            _, old = walk_chain(buf, n, p, recs, "old")
            break
        p += ALIGN
    recs.sort(key=lambda r: r[0])
    return recs, newest, old


def parse(data):
    if len(data) < HDR or data[:8] != MAGIC:
        raise ValueError("not an RKLOGDP1 image (bad magic)")
    (version, reason_off, reason_len, log_buf_len, payload_len, payload_off) = struct.unpack_from(
        "<6I", data, 8)
    (sect_off, sect_len, seq) = struct.unpack_from("<III", data, 0x28)
    (clock_ns,) = struct.unpack_from("<Q", data, 0x20)
    (uptime_ns,) = struct.unpack_from("<Q", data, 0x38)
    warnings = []
    if version != 2:
        warnings.append("version %d (expected 2)" % version)
    if reason_off != 512 or payload_off != PAYLOAD_OFF:
        warnings.append("unexpected reason_off/payload_off %d/%d" % (reason_off, payload_off))
    if payload_len > log_buf_len:
        warnings.append("payload_len %d exceeds log_buf_len %d" % (payload_len, log_buf_len))
    if PAYLOAD_OFF + payload_len > len(data):
        warnings.append("payload runs past the image; truncated")
        payload_len = len(data) - PAYLOAD_OFF
    reason_len = min(reason_len, REASON_AREA - 1)
    reason = data[HDR: HDR + reason_len].decode("utf-8", "replace")
    payload = data[PAYLOAD_OFF: PAYLOAD_OFF + payload_len]
    if sect_off != roundup(PAYLOAD_OFF + payload_len, SECT_HDR):
        warnings.append("sect_off %d not after payload" % sect_off)
    sections = []
    pos = sect_off
    end = min(sect_off + sect_len, len(data))
    while pos + SECT_HDR <= end:
        magic = data[pos: pos + 8]
        if magic not in SECT_MAGICS:
            break
        (sver, _rsv) = struct.unpack_from("<II", data, pos + 8)
        (phys, dlen, tlen) = struct.unpack_from("<QII", data, pos + 0x10)
        body_start = pos + SECT_HDR
        body = data[body_start: body_start + dlen]
        sections.append({
            "magic": magic.decode(),
            "version": sver,
            "phys": phys,
            "data_len": dlen,
            "total_len": tlen,
            "truncated": dlen < tlen,
            "body": body,
        })
        pos = body_start + roundup(dlen, SECT_HDR)
    return {
        "version": version,
        "reason": reason,
        "log_buf_len": log_buf_len,
        "payload_len": payload_len,
        "clock_ns": clock_ns,
        "uptime_ns": uptime_ns,
        "seq": seq,
        "payload": payload,
        "sections": sections,
        "warnings": warnings,
    }


def fmt_ts(ts):
    sec, rem = divmod(ts, 1_000_000_000)
    return "[%5d.%06d]" % (sec, rem // 1000)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("image")
    ap.add_argument("-o", "--outdir", help="write log.txt, reason.txt and section bodies here")
    args = ap.parse_args()
    with open(args.image, "rb") as f:
        data = f.read()
    d = parse(data)
    recs, newest, old = decode_ring(d["payload"])
    lines = ["%s %s" % (fmt_ts(ts), text.decode("utf-8", "replace").rstrip("\n"))
             for ts, _off, _src, text in recs]
    print("seq=%d version=%d log_buf_len=%d payload_len=%d" %
          (d["seq"], d["version"], d["log_buf_len"], d["payload_len"]))
    print("uptime_ns=%d clock_ns=%d" % (d["uptime_ns"], d["clock_ns"]))
    print("reason: %s" % (d["reason"] or "(none)"))
    print("ring records: %d (newest chain %d, older chain %d)" % (len(recs), newest, old))
    for s in d["sections"]:
        print("section %s phys=0x%x data=%d total=%d%s" % (
            s["magic"], s["phys"], s["data_len"], s["total_len"],
            " TRUNCATED" if s["truncated"] else ""))
    for w in d["warnings"]:
        print("warning: %s" % w, file=sys.stderr)
    if args.outdir:
        os.makedirs(args.outdir, exist_ok=True)
        with open(os.path.join(args.outdir, "log.txt"), "w") as f:
            f.write("\n".join(lines) + "\n")
        with open(os.path.join(args.outdir, "reason.txt"), "w") as f:
            f.write(d["reason"] + "\n")
        for s in d["sections"]:
            name = {"RKRAMOP1": "ramoops.bin", "RKPREVC1": "prev_console.bin"}[s["magic"]]
            with open(os.path.join(args.outdir, name), "wb") as f:
                f.write(s["body"])
    else:
        print("\n".join(lines))


if __name__ == "__main__":
    main()
