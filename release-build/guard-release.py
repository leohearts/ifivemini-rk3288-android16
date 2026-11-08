#!/usr/bin/env python3
# guard-release.py RESOURCE.img SUPER.img FLASH.sh
# Fails (exit 3) unless:
#  - super.img fits the system partition named in the resource bootargs blkdevparts;
#  - flash.sh SUPER_LBA/META_LBA/UD_LBA equal the resource's system/metadata/userdata offsets,
#    where LBA = MiB*2048 - 0x2000 (partition start MiB, minus the 0x2000-sector offset used by flash.sh);
#  - the devices/ tree exists and every board has device.json and parameter-p1.img;
#  - every board's parameter-p1.img is 4 MiB and holds exactly 4 PARM structures,
#    and its parameter-loader.img is 4 MiB and holds exactly 8;
#  - every board's head-4M.bin carries the "RK32" tag at byte offset 0x8800
#    (eMMC sector 0x44) and matches the digest recorded in its device.json;
#  - the write map derived from the device tree and the parameter structure
#    agrees with the addresses recorded in the package manifest (manifest.json);
#  - the derived addresses agree with the LBAs flash.sh uses;
#  - write-loader-head.sh is in the package, is executable, reads the board
#    addresses from devices/<board>/device.json and hardcodes no board LBA;
#  - SHA256SUMS lists every images/*.img, loader/*.bin and devices/* file,
#    every devices/<board>/head-4M.bin and write-loader-head.sh.
import hashlib
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True   # do not litter the source tree with __pycache__

HERE = os.path.dirname(os.path.abspath(__file__))
RT = os.path.join(HERE, "tools", "resource_tool")
DTC = os.path.join(HERE, "tools", "dtc")

PARAM_SIZE = 4194304
PARAM_MAGIC = b"PARM"
P1_PARM_OFFSETS = (0x000000, 0x100000, 0x200000, 0x300000)
LOADER_PARM_OFFSETS = tuple(i * 0x80000 for i in range(8))

HEAD4_SIZE = 4194304
HEAD8_SIZE = 8388608
# the u-boot.itb starts at eMMC sector 0x44 and carries the Rockchip tag "RK32"
# (byte offset 0x44 * 512 = 0x8800; byte offset 0x44 itself is part of the idblock
# hash area and is zero)
IDBLOCK_TAG_OFFSET = 0x8800
IDBLOCK_TAG = b"RK32"

MANIFEST_NAME = "manifest.json"


def _load_derive_layout():
    """The layout derivation shared with the package (derive-layout.py)."""
    path = os.path.join(HERE, "derive-layout.py")
    spec = importlib.util.spec_from_file_location("derive_layout", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


derive_layout = _load_derive_layout()


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


def parm_offsets(path):
    """Offsets of every PARM structure in a file."""
    with open(path, "rb") as f:
        data = f.read()
    out = []
    start = 0
    while True:
        i = data.find(PARAM_MAGIC, start)
        if i < 0:
            return out
        out.append(i)
        start = i + 1


def check_param_image(path, expected):
    """A parameter image must be 4 MiB and hold exactly the expected PARM structures."""
    size = os.path.getsize(path)
    if size != PARAM_SIZE:
        fail(f"{path}: {size} B, expected {PARAM_SIZE} B")
    found = parm_offsets(path)
    if tuple(found) != tuple(expected):
        fail(f"{path}: PARM structures at {[hex(o) for o in found]}, "
             f"expected {[hex(o) for o in expected]}")
    print(f"ok {os.path.basename(path)}: {size} B, {len(found)} PARM structures "
          f"at {[hex(o) for o in found]}")


def script_lba(path, name):
    """The value of NAME=0x... in a shell script."""
    txt = open(path).read()
    m = re.findall(rf'\b{name}=(0x[0-9A-Fa-f]+)', txt)
    if len(m) != 1:
        fail(f"{path}: expected one {name}, got {len(m)}")
    return int(m[0], 16)


def list_boards(tree):
    """The boards of a release tree."""
    d = os.path.join(tree, "devices")
    if not os.path.isdir(d):
        return []
    return sorted(n for n in os.listdir(d)
                  if os.path.isdir(os.path.join(d, n)))


def check_devices_tree(tree):
    """The devices/ tree and the files every board needs."""
    boards = list_boards(tree)
    if not boards:
        fail(f"{tree}: no devices/ tree with boards")
    print(f"ok {tree}/devices: {len(boards)} board(s): {', '.join(boards)}")
    for board in boards:
        bdir = os.path.join(tree, "devices", board)
        for name in ("device.json", "parameter-p1.img"):
            path = os.path.join(bdir, name)
            if not os.path.isfile(path):
                fail(f"{bdir}: missing {name}")
        try:
            with open(os.path.join(bdir, "device.json")) as f:
                device = json.load(f)
        except ValueError as e:
            fail(f"{bdir}/device.json: invalid JSON ({e})")
        for key in ("board", "display_name", "parameter_region_lba", "p1_lba"):
            if key not in device:
                fail(f"{bdir}/device.json: missing {key!r}")
        if device["board"] != board:
            fail(f"{bdir}/device.json: board id {device['board']!r} does not match "
                 f"the directory name")
        print(f"ok devices/{board}: device.json (p1 LBA 0x{device['p1_lba']:x}, "
              f"parameter region LBA 0x{device['parameter_region_lba']:x})")

        check_param_image(os.path.join(bdir, "parameter-p1.img"), P1_PARM_OFFSETS)
        loader = os.path.join(bdir, "parameter-loader.img")
        if os.path.isfile(loader):
            check_param_image(loader, LOADER_PARM_OFFSETS)

        head8 = os.path.join(bdir, "head-8M.bin")
        head4 = os.path.join(bdir, "head-4M.bin")
        if os.path.isfile(head8) != os.path.isfile(head4):
            missing = "head-8M.bin" if os.path.isfile(head4) else "head-4M.bin"
            fail(f"{bdir}: the loader head is incomplete, missing {missing}")
        if os.path.isfile(head4):
            size = os.path.getsize(head4)
            if size != HEAD4_SIZE:
                fail(f"{head4}: {size} B, expected {HEAD4_SIZE} B")
            with open(head4, "rb") as f:
                data = f.read()
            digest = hashlib.sha256(data).hexdigest()
            want = device.get("head4_sha256")
            if want and digest != want:
                fail(f"{head4}: sha256 {digest}, expected {want}")
            tag = data[IDBLOCK_TAG_OFFSET:IDBLOCK_TAG_OFFSET + len(IDBLOCK_TAG)]
            if tag != IDBLOCK_TAG:
                fail(f"{head4}: no {IDBLOCK_TAG.decode()} tag at byte offset "
                     f"0x{IDBLOCK_TAG_OFFSET:x} (eMMC sector 0x44), got {tag!r}")
            print(f"ok devices/{board}/head-4M.bin: {size} B, sha256 {digest}, "
                  f"{IDBLOCK_TAG.decode()} tag at byte offset 0x{IDBLOCK_TAG_OFFSET:x}")

            size8 = os.path.getsize(head8)
            if size8 != HEAD8_SIZE:
                fail(f"{head8}: {size8} B, expected {HEAD8_SIZE} B")
            with open(head8, "rb") as f:
                data8 = f.read()
            digest8 = hashlib.sha256(data8).hexdigest()
            want8 = device.get("head8_sha256")
            if want8 and digest8 != want8:
                fail(f"{head8}: sha256 {digest8}, expected {want8}")
            if data8[:HEAD4_SIZE] != data:
                fail(f"{head4}: not identical to the first {HEAD4_SIZE} bytes of "
                     f"{os.path.basename(head8)}")
            print(f"ok devices/{board}/head-8M.bin: {size8} B, sha256 {digest8}, "
                  f"identical to the first {HEAD4_SIZE} bytes")
    return boards


def check_loader_head_script(tree, boards):
    """write-loader-head.sh must be there, executable, board independent."""
    path = os.path.join(tree, "write-loader-head.sh")
    if not os.path.isfile(path):
        fail(f"{tree}: write-loader-head.sh is missing")
    if not os.access(path, os.X_OK):
        fail(f"{path}: is not executable")
    txt = open(path).read()
    if "device.json" not in txt:
        fail(f"{path}: does not read devices/<board>/device.json")
    # No address of a board may be written down in the script: it has to come
    # from the board description, so one script serves every board.
    for board in boards:
        with open(os.path.join(tree, "devices", board, "device.json")) as f:
            device = json.load(f)
        for key in ("loader_area_raw_start", "loader_area_lba_raw",
                    "loader_area_lba_tool"):
            if key not in device:
                fail(f"devices/{board}/device.json: missing {key!r}")
        for key in ("p1_lba", "parameter_region_lba",
                    "loader_area_lba_raw", "loader_area_lba_tool"):
            value = int(device[key])
            if value == 0:
                continue
            for literal in (str(value), "0x%x" % value):
                if re.search(r"(?<![0-9A-Za-z_])" + re.escape(literal) +
                             r"(?![0-9A-Za-z_])", txt):
                    fail(f"{path}: hardcodes the {key} of {board} ({literal}); "
                         f"it must read devices/<board>/device.json")
    print(f"ok {path}: executable, reads device.json, no hardcoded board LBA")


def check_manifest(tree, boards, flash):
    """The derived write map must agree with the recorded manifest."""
    manifest_path = os.path.join(tree, MANIFEST_NAME)
    if not os.path.isfile(manifest_path):
        fail(f"{manifest_path} is missing")
    try:
        with open(manifest_path) as f:
            manifest = json.load(f)
    except ValueError as e:
        fail(f"{manifest_path}: invalid JSON ({e})")
    if "boards" not in manifest:
        fail(f"{manifest_path}: no boards")

    for board in boards:
        if board not in manifest["boards"]:
            fail(f"{manifest_path}: no entry for board {board}")
        recorded = manifest["boards"][board]
        try:
            derived = derive_layout.build_plan(
                tree, board,
                derive_layout.load_board(tree, board))
        except derive_layout.LayoutError as e:
            fail(f"cannot derive the layout of {board}: {e}")

        want = {(w["key"], w["file"]): w for w in recorded["writes"]}
        got = {(w["key"], w["file"]): w for w in derived["writes"]}
        if set(want) != set(got):
            fail(f"{manifest_path}: board {board} lists {sorted(want)}, "
                 f"the package derives {sorted(got)}")
        for key in want:
            if want[key]["lba"] != got[key]["lba"]:
                fail(f"{manifest_path}: board {board} {key} is at LBA "
                     f"0x{want[key]['lba']:x}, the package derives 0x{got[key]['lba']:x}")
            if want[key]["bytes"] != got[key]["bytes"]:
                fail(f"{manifest_path}: board {board} {key} is {want[key]['bytes']} B, "
                     f"the package derives {got[key]['bytes']} B")
        print(f"ok manifest board {board}: {len(want)} write(s) agree with the "
              f"device tree and the parameter structure")

        # the derived addresses must agree with the LBAs flash.sh uses
        flash_txt = open(flash).read()
        names = {"RES_LBA": "resource", "KRN_LBA": "kernel", "RD_LBA": "boot",
                 "SUPER_LBA": "system", "META_LBA": "metadata", "UD_LBA": "userdata"}
        for var, part in names.items():
            derived_lba = None
            for w in derived["writes"]:
                if w["partition"] == part:
                    derived_lba = w["lba"]
            if derived_lba is None:
                fail(f"board {board}: no derived address for the {part} partition")
            m = re.findall(rf'\b{var}=(0x[0-9A-Fa-f]+)', flash_txt)
            if len(m) != 1:
                fail(f"{flash}: expected one {var}, got {len(m)}")
            if int(m[0], 16) != derived_lba:
                fail(f"{flash}: {var}=0x{int(m[0], 16):x} but the package derives "
                     f"0x{derived_lba:x} for the {part} partition")
            print(f"ok {var}=0x{derived_lba:x} agrees with the derived layout")

        # the size limits flash.sh uses must be the derived partition sizes
        maxes = {"RES_MAX": "resource", "KRN_MAX": "kernel", "RD_MAX": "boot",
                 "META_MAX": "metadata", "UD_MAX": "userdata"}
        for var, part in maxes.items():
            derived_size = derived["dtb_partitions"][part]["size"]
            if derived_size is None:
                # the partition takes the rest of the disk: the limit is the
                # size of the image that goes into it
                derived_size = None
                for w in derived["writes"]:
                    if w["partition"] == part:
                        derived_size = w["bytes"]
            m = re.findall(rf'\b{var}=([0-9]+)', flash_txt)
            if len(m) != 1:
                fail(f"{flash}: expected one {var}, got {len(m)}")
            if int(m[0]) != derived_size:
                fail(f"{flash}: {var}={m[0]} but the package derives {derived_size} "
                     f"for the {part} partition")
            print(f"ok {var}={derived_size} agrees with the derived layout")

        # the system partition size flash.sh checks super.img against
        sys_size = derived["dtb_partitions"]["system"]["size"]
        m = re.findall(r'\bSYSTEM_SECTORS=(0x[0-9A-Fa-f]+)', flash_txt)
        if len(m) != 1:
            fail(f"{flash}: expected one SYSTEM_SECTORS, got {len(m)}")
        if int(m[0], 16) * 512 != sys_size:
            fail(f"{flash}: SYSTEM_SECTORS={m[0]} means {int(m[0], 16) * 512} B "
                 f"but the package derives {sys_size} B for the system partition")
        print(f"ok SYSTEM_SECTORS={m[0]} agrees with the derived layout")


def check_sha256sums(tree):
    """SHA256SUMS must list every images/*.img, loader/*.bin and devices/ file.

    flash.sh and restore.sh both run "sha256sum -c SHA256SUMS", so a file that is
    shipped but not listed would be written unchecked (or make the check fail).
    """
    sums = os.path.join(tree, "SHA256SUMS")
    if not os.path.isfile(sums):
        print("ok no SHA256SUMS in this tree")
        return
    listed = set()
    for line in open(sums):
        parts = line.split(None, 1)
        if len(parts) == 2:
            listed.add(parts[1].strip().lstrip("*"))
    for sub in ("images", "loader"):
        d = os.path.join(tree, sub)
        if not os.path.isdir(d):
            continue
        for name in sorted(os.listdir(d)):
            if not (sub == "images" and name.endswith(".img")) and \
               not (sub == "loader" and name.endswith(".bin")):
                continue
            rel = f"{sub}/{name}"
            if rel not in listed:
                fail(f"{sums}: {rel} is not listed in SHA256SUMS")
            print(f"ok SHA256SUMS covers {rel}")
    devices = os.path.join(tree, "devices")
    if os.path.isdir(devices):
        for board in sorted(os.listdir(devices)):
            bdir = os.path.join(devices, board)
            if not os.path.isdir(bdir):
                continue
            for name in sorted(os.listdir(bdir)):
                rel = f"devices/{board}/{name}"
                if rel not in listed:
                    fail(f"{sums}: {rel} is not listed in SHA256SUMS")
                print(f"ok SHA256SUMS covers {rel}")
            # the loader head is what write-loader-head.sh writes: it must be
            # covered by the checksum file as well
            head = f"devices/{board}/head-4M.bin"
            if os.path.isfile(os.path.join(tree, head)) and head not in listed:
                fail(f"{sums}: {head} is not listed in SHA256SUMS")
            print(f"ok SHA256SUMS covers {head}")
    script = "write-loader-head.sh"
    if os.path.isfile(os.path.join(tree, script)):
        if script not in listed:
            fail(f"{sums}: {script} is not listed in SHA256SUMS")
        print(f"ok SHA256SUMS covers {script}")


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
    # the other three image partitions, from the same independent path
    for var, part in (("RES_LBA", "resource"), ("KRN_LBA", "kernel"),
                      ("RD_LBA", "boot")):
        if part not in parts:
            fail(f"{res}: no {part} partition in blkdevparts")
        want[var] = lba(parts[part][1])
    for k, v in want.items():
        got = flash_lba(k)
        if got != v:
            fail(f"{flash}: {k}=0x{got:x} but resource layout needs 0x{v:x}")
        print(f"ok {k}=0x{got:x}")
    print(f"ok super {sup_bytes} B <= system {sys_mib}M ({sys_bytes} B)")

    tree = os.path.dirname(os.path.abspath(flash))
    boards = check_devices_tree(tree)
    check_loader_head_script(tree, boards)
    check_manifest(tree, boards, flash)
    check_sha256sums(tree)
    print("GUARD OK", res, sup, flash)


if __name__ == "__main__":
    main()
