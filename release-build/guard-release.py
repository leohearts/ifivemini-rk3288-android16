#!/usr/bin/env python3
# guard-release.py RESOURCE.img SUPER.img FLASH.sh
# Fails (exit 3) unless:
#  - super.img fits the system partition named in the resource bootargs blkdevparts;
#  - flash.sh SUPER_LBA/META_LBA/UD_LBA equal the resource's system/metadata/userdata offsets,
#    where LBA = MiB*2048 - 0x2000 (partition start MiB, minus the 0x2000-sector offset used by flash.sh).
import os, re, subprocess, sys, tempfile

RT = "/run/media/leohearts/Data/rk3288-a11/release/build/tools/resource_tool"
DTC = "/run/media/leohearts/Data/rk3288-a11/release/build/tools/dtc"


def fail(msg):
    print("GUARD FAIL:", msg)
    sys.exit(3)


def blkdevparts(res, tmp):
    subprocess.run([RT, "--unpack", f"--image={res}", tmp], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    dts = os.path.join(tmp, "rk-kernel.dts")
    subprocess.run([DTC, "-I", "dtb", "-O", "dts", "-o", dts, os.path.join(tmp, "rk-kernel.dtb")],
                   check=True, stderr=subprocess.DEVNULL)
    m = re.findall(r'blkdevparts=mmcblk0:([^"\s]+)', open(dts).read())
    if len(m) != 1:
        fail(f"{res}: expected one blkdevparts in bootargs, got {len(m)}")
    parts = {}
    for ent in m[0].split(","):
        mm = re.fullmatch(r'(\d+|-)M?@(\d+)M\(([^)]+)\)', ent)
        if not mm:
            # sizes like 4M@8M(uboot) — regex above covers them; anything else is a parse error
            fail(f"{res}: cannot parse blkdevparts entry {ent!r}")
        size, off, name = mm.group(1), int(mm.group(2)), mm.group(3)
        parts[name] = (None if size == "-" else int(size), off)
    return parts


def lba(mib):
    return mib * 2048 - 0x2000


def main():
    res, sup, flash = sys.argv[1], sys.argv[2], sys.argv[3]
    with tempfile.TemporaryDirectory() as tmp:
        parts = blkdevparts(res, tmp)
    for need in ("system", "metadata", "userdata"):
        if need not in parts:
            fail(f"{res}: no {need} partition in blkdevparts")
    sys_mib, sys_off = parts["system"]
    if sys_mib is None:
        fail("system partition has no fixed size")
    sys_bytes = sys_mib * 1024 * 1024
    sup_bytes = os.path.getsize(sup)
    if sup_bytes > sys_bytes:
        fail(f"super.img {sup_bytes} B > system {sys_bytes} B ({sys_mib}M)")

    txt = open(flash).read()

    def flash_lba(name):
        m = re.findall(rf'\b{name}=(0x[0-9A-Fa-f]+)', txt)
        if len(m) != 1:
            fail(f"{flash}: expected one {name}, got {len(m)}")
        return int(m[0], 16)

    want = {
        "SUPER_LBA": lba(sys_off),
        "META_LBA": lba(parts["metadata"][1]),
        "UD_LBA": lba(parts["userdata"][1]),
    }
    for k, v in want.items():
        got = flash_lba(k)
        if got != v:
            fail(f"{flash}: {k}=0x{got:x} but resource layout needs 0x{v:x}")
        print(f"ok {k}=0x{got:x}")
    print(f"ok super {sup_bytes} B <= system {sys_mib}M ({sys_bytes} B)")
    print("GUARD OK", res, sup, flash)


if __name__ == "__main__":
    main()
