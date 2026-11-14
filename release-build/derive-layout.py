#!/usr/bin/env python3
"""derive-layout.py - derive the rescue write map from the data inside the package.

Nothing here is hardcoded to one tablet: the write addresses come from two
sources that travel inside the release package.

  images/resource.img               Rockchip RSCE container.  Its device tree
                                    (extracted with tools/resource_tool and
                                    decompiled with tools/dtc) carries the GSI
                                    partition table in the kernel command line
                                    (blkdevparts=mmcblk0:...).

  devices/<board>/parameter-p1.img  the board's own Rockchip parameter
                                    structure ("PARM").  Its CMDLINE carries
                                    the mtdparts table the bootloader uses.

  devices/<board>/device.json       board metadata: where the parameter
                                    structures live and a note about the
                                    loader area below tool LBA 0.

The image -> partition roles are fixed by the GSI image set:

  images/resource.img           -> resource
  images/kernel.img             -> kernel
  images/ramdisk.img            -> boot
  images/super.img              -> system
  images/metadata.img           -> metadata
  images/userdata-head-zero.img -> userdata (head only)

The two tables must agree.  The stock parameter and the GSI device tree differ
in one place only: the GSI gives "system" more room, so every partition behind
"system" moves by exactly that difference.  The script checks that rule and
fails loudly when the tables disagree in any other way.

Usage:
  derive-layout.py --package DIR --board ID [--format text|env|json]
  derive-layout.py --package DIR --detect-dump FILE

Exit codes: 0 ok, 3 layout error, 64 usage error.
"""
import argparse
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile

PARM_MAGIC = b"PARM"
SECTOR = 512
MIB = 1024 * 1024
# tool LBA 0 is eMMC sector 0x2000: the loader area below it is unreachable
# with any rkdeveloptool LBA command.
TOOL_LBA_BASE = 0x2000
# The partition the two tables are anchored on.
#
# The GSI device tree gives "system" twice the room the stock parameter gives
# it: 3072 MiB in the DTB against 1536 MiB in the stock parameter.  The extra
# 1536 MiB (0x300000 sectors) is what makes the GSI super image of
# 2037186560 B (1943 MiB) fit - it does not fit the stock 1536 MiB system
# partition.  Every partition behind "system" therefore starts 0x300000
# sectors further out than the stock parameter says.  The distance is computed
# from the two tables at run time, never written down as a constant.
TAIL_ANCHOR = "system"

# image file -> partition name (the roles of the GSI image set), in write order
IMAGE_ROLES = (
    ("images/resource.img", "resource"),
    ("images/kernel.img", "kernel"),
    ("images/ramdisk.img", "boot"),
    ("images/super.img", "system"),
    ("images/metadata.img", "metadata"),
    ("images/userdata-head-zero.img", "userdata"),
)


class LayoutError(Exception):
    """A fatal inconsistency in the package data."""


# ---------------------------------------------------------------- tools ----

def find_tool(package, script_dir, name):
    """Locate a bundled helper binary (dtc, resource_tool)."""
    candidates = [
        os.path.join(package, "tools", name),
        os.path.join(script_dir, "tools", name),
        os.path.join(script_dir, name),
    ]
    for c in candidates:
        if os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    raise LayoutError("missing helper tool %s (looked in %s)"
                      % (name, ", ".join(candidates)))


def extract_dtb(package, script_dir, resource_img):
    """Unpack the device tree out of the RSCE container and decompile it."""
    resource_tool = find_tool(package, script_dir, "resource_tool")
    dtc = find_tool(package, script_dir, "dtc")
    work = tempfile.mkdtemp(prefix="derive-layout.")
    try:
        subprocess.run([resource_tool, "--unpack", "--image=%s" % resource_img, work],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        dtb = os.path.join(work, "rk-kernel.dtb")
        if not os.path.isfile(dtb):
            raise LayoutError("%s: no rk-kernel.dtb inside the resource image" % resource_img)
        dts = os.path.join(work, "rk.dts")
        subprocess.run([dtc, "-I", "dtb", "-O", "dts", "-o", dts, dtb],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        with open(dts, "r", errors="replace") as f:
            return f.read()
    except subprocess.CalledProcessError as e:
        raise LayoutError("cannot extract the device tree from %s (%s)" % (resource_img, e))
    finally:
        shutil.rmtree(work, ignore_errors=True)


# ------------------------------------------------------------- parsing ----

def _size_bytes(value, unit):
    """A partition size from a table entry; None means 'the rest of the disk'."""
    if value == "-":
        return None
    if unit == "M":
        return int(value) * MIB
    return int(value, 16) * SECTOR


def parse_blkdevparts(dts):
    """The GSI partition table from the device tree command line.

    Entries look like "16M@16M(resource)".  The offset is a raw eMMC offset
    in MiB (or in sectors when written in hex), the size is in MiB.
    """
    m = re.search(r'blkdevparts=mmcblk0:([^"\s]+)', dts)
    if not m:
        raise LayoutError("the device tree has no blkdevparts=mmcblk0: table")
    parts = {}
    order = []
    for entry in m.group(1).split(","):
        mm = re.fullmatch(r'(-|\d+)M?@([0-9A-Fa-fx]+)M?\((\w+)\)', entry)
        if not mm:
            raise LayoutError("cannot parse partition entry %r" % entry)
        size, offset, name = mm.group(1), mm.group(2), mm.group(3)
        if offset.lower().startswith("0x"):
            lba = int(offset, 16) - TOOL_LBA_BASE
        else:
            lba = int(offset) * (MIB // SECTOR) - TOOL_LBA_BASE
        parts[name] = {"lba": lba, "size": _size_bytes(size, "M")}
        order.append(name)
    return parts, order


def parse_parameter(path):
    """Parse a Rockchip parameter structure ("PARM").

    Layout: magic "PARM" at offset 0, the text area length as a little endian
    uint32 at offset 4, the text area at offset 8, CRLF terminated.
    """
    try:
        with open(path, "rb") as f:
            data = f.read(1 << 20)
    except OSError as e:
        raise LayoutError("cannot read %s: %s" % (path, e))
    if data[:4] != PARM_MAGIC:
        raise LayoutError("%s: no PARM structure (magic %r)" % (path, data[:4]))
    size = struct.unpack_from("<I", data, 4)[0]
    text = data[8:8 + size]
    if len(text) != size or b"\r\n" not in text:
        # tolerate the alternative header shape (length at offset 8, text at 0x10)
        alt_size = struct.unpack_from("<I", data, 8)[0]
        alt_text = data[0x10:0x10 + alt_size]
        if b"\r\n" in alt_text:
            size, text = alt_size, alt_text
        else:
            raise LayoutError("%s: the PARM text area is malformed" % path)
    return text.decode("ascii", errors="replace").replace("\r\n", "\n")


def parse_mtdparts(text):
    """The partition table the bootloader uses, from the parameter CMDLINE.

    Entries look like "0x00008000@0x00006000(resource)": the size and the
    offset are in sectors, and the offset is already the tool LBA.
    """
    m = re.search(r'mtdparts=[^:\s]+:([^\s"]+)', text)
    if not m:
        raise LayoutError("the parameter structure has no mtdparts= table")
    parts = {}
    order = []
    for entry in m.group(1).split(","):
        mm = re.fullmatch(r'(-|0x[0-9A-Fa-f]+)@(0x[0-9A-Fa-f]+)\((\w+)\)', entry)
        if not mm:
            raise LayoutError("cannot parse mtdparts entry %r" % entry)
        size, offset, name = mm.group(1), mm.group(2), mm.group(3)
        parts[name] = {"lba": int(offset, 16), "size": _size_bytes(size, "S")}
        order.append(name)
    return parts, order


# ------------------------------------------------------------ comparison --

def check_tables(dtb_parts, dtb_order, param_parts):
    """The device tree table and the parameter table must describe one disk.

    The two tables use different units, both are converted to sectors here:
    the device tree lists blkdevparts=... in MiB, the parameter structure
    lists mtdparts=... in sectors.

    "system" is the anchor.  The GSI gives "system" twice the room the stock
    parameter gives it (3072 MiB in the device tree against 1536 MiB in the
    stock parameter, so the GSI super image of 2037186560 B fits), and every
    partition behind "system" therefore moves by exactly that difference:

      system and everything before it: the two tables must agree exactly
      everything behind system:        dtb_lba == param_lba + delta

    delta is computed from the two tables, never written down as a constant.
    """
    if TAIL_ANCHOR not in dtb_parts or TAIL_ANCHOR not in param_parts:
        raise LayoutError(
            "neither the device tree nor the parameter structure defines the %r "
            "partition, the two tables cannot be compared" % TAIL_ANCHOR)
    d_size = dtb_parts[TAIL_ANCHOR]["size"]
    p_size = param_parts[TAIL_ANCHOR]["size"]
    if d_size is None or p_size is None:
        raise LayoutError("the %r partition has no fixed size in one of the tables"
                          % TAIL_ANCHOR)
    if (d_size - p_size) % SECTOR:
        raise LayoutError("the %r size difference is not a multiple of %d B"
                          % (TAIL_ANCHOR, SECTOR))
    delta = (d_size - p_size) // SECTOR
    if delta <= 0:
        raise LayoutError(
            "the device tree gives %r %d B (%d MiB), the parameter gives %d B "
            "(%d MiB): the device tree must give it more room, not less"
            % (TAIL_ANCHOR, d_size, d_size // MIB, p_size, p_size // MIB))

    anchor_index = dtb_order.index(TAIL_ANCHOR) if TAIL_ANCHOR in dtb_order else len(dtb_order)
    differences = {}
    for index, name in enumerate(dtb_order):
        if name not in param_parts:
            continue
        d, p = dtb_parts[name], param_parts[name]
        behind = index > anchor_index
        want_lba = d["lba"] - (delta if behind else 0)
        if p["lba"] != want_lba:
            differences.setdefault(name, {})["lba"] = {
                "dtb": d["lba"], "parameter": p["lba"], "expected": want_lba}
        if name != TAIL_ANCHOR and d["size"] != p["size"]:
            differences.setdefault(name, {})["size"] = {
                "dtb": d["size"], "parameter": p["size"]}
    if differences:
        names = ", ".join(sorted(differences))
        raise LayoutError(
            "the device tree and the parameter structure disagree about %s "
            "(the device tree gives %r %d B, the parameter %d B, so every "
            "partition behind it must move by %d sectors)"
            % (names, TAIL_ANCHOR,
               dtb_parts[TAIL_ANCHOR]["size"], param_parts[TAIL_ANCHOR]["size"], delta))
    return delta


# ----------------------------------------------------------------- plan ----

def build_plan(package, board, board_json):
    """Compute the whole write map for one board."""
    resource_img = os.path.join(package, "images", "resource.img")
    if not os.path.isfile(resource_img):
        raise LayoutError("missing %s" % resource_img)
    param_img = os.path.join(package, "devices", board, "parameter-p1.img")
    if not os.path.isfile(param_img):
        raise LayoutError("missing %s" % param_img)

    script_dir = os.path.dirname(os.path.abspath(__file__))
    dts = extract_dtb(package, script_dir, resource_img)
    dtb_parts, dtb_order = parse_blkdevparts(dts)

    text = parse_parameter(param_img)
    param_parts, param_order = parse_mtdparts(text)
    delta = check_tables(dtb_parts, dtb_order, param_parts)

    loader_lba = int(board_json.get("parameter_region_lba", 0))
    p1_lba = int(board_json.get("p1_lba", 0))
    if p1_lba <= loader_lba:
        raise LayoutError("devices/%s: the p1 LBA 0x%x must be above the loader area LBA 0x%x"
                          % (board, p1_lba, loader_lba))
    # the parameter structure describes the p1 partition as "uboot"
    if "uboot" in param_parts and param_parts["uboot"]["lba"] != p1_lba:
        raise LayoutError(
            "devices/%s: device.json says the p1 parameter lives at tool LBA 0x%x "
            "but the parameter structure puts %r at 0x%x"
            % (board, p1_lba, "uboot", param_parts["uboot"]["lba"]))

    writes = []
    for image, partition in IMAGE_ROLES:
        path = os.path.join(package, image)
        if not os.path.isfile(path):
            raise LayoutError("missing %s" % image)
        size = os.path.getsize(path)
        if partition not in dtb_parts:
            raise LayoutError("%s: the device tree has no partition %r" % (image, partition))
        psize = dtb_parts[partition]["size"]
        if psize is not None and size > psize:
            raise LayoutError("%s: %d B does not fit the %s partition (%d B)"
                              % (image, size, partition, psize))
        writes.append({
            "key": partition,
            "file": image,
            "partition": partition,
            "lba": dtb_parts[partition]["lba"],
            "bytes": size,
        })

    parameter_writes = []
    for key, name, lba in (("parameter_loader", "parameter-loader.img", loader_lba),
                           ("parameter_p1", "parameter-p1.img", p1_lba)):
        path = os.path.join(package, "devices", board, name)
        if not os.path.isfile(path):
            if key == "parameter_p1":
                raise LayoutError("missing devices/%s/%s" % (board, name))
            # the loader-area copy is optional: a board whose stock backup has
            # no bootloader dump cannot provide it
            continue
        parameter_writes.append({
            "key": key,
            "file": "devices/%s/%s" % (board, name),
            "partition": None,
            "lba": lba,
            "bytes": os.path.getsize(path),
        })

    return {
        "plan_schema": 1,
        "board": board,
        "display_name": board_json.get("display_name", board),
        "source": {
            "resource": "images/resource.img",
            "parameter": "devices/%s/parameter-p1.img" % board,
        },
        "dtb_partitions": dtb_parts,
        "dtb_order": dtb_order,
        "parameter_partitions": param_parts,
        "parameter_order": param_order,
        "tail_delta_sectors": delta,
        "parameter_writes": parameter_writes,
        "writes": writes,
    }


def build_dtb_layout(package):
    """The partition table of the device tree alone, without any board.

    flash.sh only needs the image partitions, and those come from the device
    tree, which every board of a package shares.  This is the fallback for a
    package that has no devices/ tree yet.
    """
    resource_img = os.path.join(package, "images", "resource.img")
    if not os.path.isfile(resource_img):
        raise LayoutError("missing %s" % resource_img)
    script_dir = os.path.dirname(os.path.abspath(__file__))
    dts = extract_dtb(package, script_dir, resource_img)
    dtb_parts, dtb_order = parse_blkdevparts(dts)
    return {
        "plan_schema": 1,
        "dtb_partitions": dtb_parts,
        "dtb_order": dtb_order,
    }


def load_board(package, board):
    path = os.path.join(package, "devices", board, "device.json")
    if not os.path.isfile(path):
        raise LayoutError("no device.json for board %r" % board)
    try:
        with open(path, "r") as f:
            return json.load(f)
    except ValueError as e:
        raise LayoutError("%s: invalid JSON (%s)" % (path, e))


def list_boards(package):
    d = os.path.join(package, "devices")
    if not os.path.isdir(d):
        return []
    return sorted(n for n in os.listdir(d)
                  if os.path.isfile(os.path.join(d, n, "device.json")))


def detect_board(package, dump):
    """Match a parameter structure read from the device against the boards.

    The device parameter text must match one board's parameter structure.
    """
    device_text = parse_parameter(dump)
    known = list_boards(package)
    if not known:
        raise LayoutError("this package has no devices/ directory")
    matches = []
    for board in known:
        path = os.path.join(package, "devices", board, "parameter-p1.img")
        if not os.path.isfile(path):
            continue
        if parse_parameter(path) == device_text:
            matches.append(board)
    if len(matches) == 1:
        return matches[0]
    if not matches:
        raise LayoutError("the device parameter structure matches no known board (%s)"
                          % ", ".join(known))
    raise LayoutError("the device parameter structure matches several boards (%s)"
                      % ", ".join(matches))


# ---------------------------------------------------------------- output --

def format_dtb_text(layout):
    out = ["== device tree partition table"]
    for name in layout["dtb_order"]:
        p = layout["dtb_partitions"][name]
        size = "rest of disk" if p["size"] is None else "%d B" % p["size"]
        out.append("   %-16s tool LBA 0x%05x   size %s" % (name, p["lba"], size))
    return "\n".join(out)


def format_text(plan):
    out = []
    out.append("== board %s (%s)" % (plan["board"], plan["display_name"]))
    out.append("== device tree partition table (%s)" % plan["source"]["resource"])
    for name in plan["dtb_order"]:
        p = plan["dtb_partitions"][name]
        size = "rest of disk" if p["size"] is None else "%d B" % p["size"]
        out.append("   %-16s tool LBA 0x%05x   size %s" % (name, p["lba"], size))
    out.append("== parameter partition table (%s)" % plan["source"]["parameter"])
    for name in plan["parameter_order"]:
        p = plan["parameter_partitions"][name]
        size = "rest of disk" if p["size"] is None else "%d B" % p["size"]
        out.append("   %-16s tool LBA 0x%05x   size %s" % (name, p["lba"], size))
    out.append("== the tables agree; the partitions behind %r move by %d sectors"
               % (TAIL_ANCHOR, plan["tail_delta_sectors"]))
    out.append("== write map")
    for w in plan["parameter_writes"] + plan["writes"]:
        out.append("   %-42s tool LBA 0x%05x   %d B%s"
                   % (w["file"], w["lba"], w["bytes"],
                      "   (%s)" % w["partition"] if w["partition"] else ""))
    return "\n".join(out)


def format_env(plan):
    out = ["PLAN_BOARD=%s" % plan["board"]]
    items = plan["parameter_writes"] + plan["writes"]
    out.append("PLAN_ITEM_ORDER=%s" % " ".join(w["key"] for w in items))
    for w in items:
        out.append("PLAN_%s_FILE=%s" % (w["key"].upper(), w["file"]))
        out.append("PLAN_%s_LBA=0x%05x" % (w["key"].upper(), w["lba"]))
        out.append("PLAN_%s_BYTES=%d" % (w["key"].upper(), w["bytes"]))
        out.append("PLAN_%s_PARTITION=%s" % (w["key"].upper(), w["partition"] or "-"))
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--package", required=True, help="the release package directory")
    ap.add_argument("--board", help="board id to compute the layout for")
    ap.add_argument("--detect-dump", help="a parameter structure read from the device")
    ap.add_argument("--dtb-only", action="store_true",
                    help="only the device tree partition table, no board needed")
    ap.add_argument("--format", choices=("text", "env", "json"), default="text")
    ap.add_argument("--output", help="write the result to this file")
    args = ap.parse_args()

    package = os.path.abspath(args.package)
    try:
        if args.detect_dump:
            board = detect_board(package, args.detect_dump)
            sys.stdout.write("detected board %s\n" % board)
            return 0
        if args.dtb_only:
            layout = build_dtb_layout(package)
            out = json.dumps(layout, indent=2, sort_keys=True) \
                if args.format == "json" else format_dtb_text(layout)
            if args.output:
                with open(args.output, "w") as f:
                    f.write(out + "\n")
            else:
                sys.stdout.write(out + "\n")
            return 0
        if not args.board:
            ap.error("--board is required (or --detect-dump)")
        board_json = load_board(package, args.board)
        plan = build_plan(package, args.board, board_json)
    except LayoutError as e:
        sys.stderr.write("STOP: %s\n" % e)
        return 3

    if args.format == "text":
        out = format_text(plan)
    elif args.format == "env":
        out = format_env(plan)
    else:
        out = json.dumps(plan, indent=2, sort_keys=True)
    if args.output:
        with open(args.output, "w") as f:
            f.write(out + "\n")
    else:
        sys.stdout.write(out + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
