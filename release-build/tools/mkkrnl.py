#!/usr/bin/env python3
"""Rockchip KRNL/PARM container: pack, unpack, verify.

Layout: magic[4] ('KRNL' or 'PARM') | payload_len u32 LE | payload | crc u32 LE
CRC: rkflashtool rkcrc, MSB-first CRC with poly 0x04C10DB7, init 0, no final xor.
"""
import argparse
import struct
import sys

MAGICS = (b"KRNL", b"PARM")
POLY = 0x04C10DB7


def _table():
    tab = []
    for i in range(256):
        c = i << 24
        for _ in range(8):
            c = (((c << 1) ^ POLY) if c & 0x80000000 else (c << 1)) & 0xFFFFFFFF
        tab.append(c)
    return tab


_TAB = _table()


def rkcrc(data: bytes) -> int:
    c = 0
    for b in data:
        c = ((c << 8) & 0xFFFFFFFF) ^ _TAB[((c >> 24) ^ b) & 0xFF]
    return c


def pack_bytes(payload: bytes, magic: bytes = b"KRNL") -> bytes:
    if magic not in MAGICS:
        raise ValueError(f"bad magic {magic!r}")
    return magic + struct.pack("<I", len(payload)) + payload + struct.pack("<I", rkcrc(payload))


def parse(blob: bytes):
    """Return (magic, payload). Raises ValueError on malformed/CRC mismatch."""
    if len(blob) < 12:
        raise ValueError("file too short")
    magic = blob[:4]
    if magic not in MAGICS:
        raise ValueError(f"bad magic {magic!r}")
    (n,) = struct.unpack("<I", blob[4:8])
    if len(blob) != 12 + n:
        raise ValueError(f"length mismatch: header says {n} payload, file has {len(blob) - 12}")
    payload = blob[8:8 + n]
    (crc,) = struct.unpack("<I", blob[8 + n:])
    got = rkcrc(payload)
    if crc != got:
        raise ValueError(f"crc mismatch: stored {crc:08x}, computed {got:08x}")
    return magic, payload


def cmd_pack(a):
    with open(a.input, "rb") as f:
        payload = f.read()
    with open(a.output, "wb") as f:
        f.write(pack_bytes(payload, a.magic.encode()))


def cmd_unpack(a):
    with open(a.input, "rb") as f:
        _, payload = parse(f.read())
    with open(a.output, "wb") as f:
        f.write(payload)


def cmd_verify(a):
    with open(a.input, "rb") as f:
        magic, payload = parse(f.read())
    print(f"{magic.decode()} payload {len(payload)} bytes crc ok")


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("pack")
    s.add_argument("input")
    s.add_argument("output")
    s.add_argument("--magic", default="KRNL", choices=["KRNL", "PARM"])
    s.set_defaults(fn=cmd_pack)
    s = sub.add_parser("unpack")
    s.add_argument("input")
    s.add_argument("output")
    s.set_defaults(fn=cmd_unpack)
    s = sub.add_parser("verify")
    s.add_argument("input")
    s.set_defaults(fn=cmd_verify)
    a = p.parse_args(argv)
    try:
        a.fn(a)
    except (OSError, ValueError) as e:
        print(f"mkkrnl: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
