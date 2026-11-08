#!/usr/bin/env python3
"""make-flash.py TREE - render flash.sh from flash.sh.src and manifest.json.

The write addresses of flash.sh come from manifest.json, which make-manifest.py
derived from the partition table of the device tree inside images/resource.img.
The same manifest drives restore.sh, so both scripts of a package write every
image to the same place.

The addresses of the image partitions come from the device tree, which every
board of a package shares; the check below makes sure the boards of a package
do not disagree about them.

Usage:
  make-flash.py TREE [--template flash.sh.src] [--output flash.sh]

Exit codes: 0 ok, 3 inconsistent package, 64 usage error.
"""
import importlib.util
import json
import os
import re
import sys

sys.dont_write_bytecode = True   # do not litter the source tree with __pycache__

HERE = os.path.dirname(os.path.abspath(__file__))


def _load_derive_layout():
    """The layout derivation shared with the package (derive-layout.py)."""
    path = os.path.join(HERE, "derive-layout.py")
    spec = importlib.util.spec_from_file_location("derive_layout", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


derive_layout = _load_derive_layout()

# the flash.sh variable that holds the address of each partition
LBAS = {
    "RES_LBA": "resource",
    "KRN_LBA": "kernel",
    "RD_LBA": "boot",
    "SUPER_LBA": "system",
    "META_LBA": "metadata",
    "UD_LBA": "userdata",
}
# the flash.sh variable that holds the size limit of each image
MAXES = {
    "RES_MAX": "resource",
    "KRN_MAX": "kernel",
    "RD_MAX": "boot",
    "META_MAX": "metadata",
    "UD_MAX": "userdata",
}
SECTOR = 512


def die(msg):
    print("STOP: %s" % msg, file=sys.stderr)
    sys.exit(3)


def partition_addresses(plan):
    """The address of every image partition of a plan."""
    out = {}
    for w in plan["writes"]:
        if w["partition"]:
            out[w["partition"]] = w["lba"]
    return out


def partition_sizes(plan):
    """The size of every image partition of a plan, in bytes."""
    out = {}
    for w in plan["writes"]:
        if w["partition"]:
            out[w["partition"]] = plan["dtb_partitions"][w["partition"]]["size"]
    return out


def main():
    argv = sys.argv[1:]
    if not argv:
        print("usage: make-flash.py TREE [--template FILE] [--output FILE]",
              file=sys.stderr)
        return 64
    tree = os.path.abspath(argv[0])
    template = os.path.join(tree, "flash.sh.src")
    output = os.path.join(tree, "flash.sh")
    layout = "gsi"
    rest = argv[1:]
    while rest:
        if rest[0] == "--template" and len(rest) > 1:
            template = rest[1]
            rest = rest[2:]
        elif rest[0] == "--output" and len(rest) > 1:
            output = rest[1]
            rest = rest[2:]
        elif rest[0] == "--layout" and len(rest) > 1:
            layout = rest[1]
            rest = rest[2:]
        else:
            print("usage: make-flash.py TREE [--template FILE] [--output FILE] "
                  "[--layout NAME]", file=sys.stderr)
            return 64

    manifest_path = os.path.join(tree, "manifest.json")
    if not os.path.isfile(template):
        die("%s is missing" % template)

    boards = {}
    image_sizes = {}
    if os.path.isfile(manifest_path):
        try:
            with open(manifest_path) as f:
                manifest = json.load(f)
        except ValueError as e:
            die("%s: invalid JSON (%s)" % (manifest_path, e))
        boards = manifest.get("boards") or {}
        if not boards:
            die("%s has no board" % manifest_path)
    else:
        # no board in this package: the device tree still names the image
        # partitions, and that is all flash.sh needs
        print("NOTE: %s is missing, the addresses come from the device tree alone"
              % manifest_path)

    # every board of a package shares one device tree, so they must agree
    # about the address of every image partition
    reference = None
    ref_board = None
    for board in sorted(boards):
        plan = boards[board]
        addrs = partition_addresses(plan)
        sizes = partition_sizes(plan)
        missing = [p for p in LBAS.values() if p not in addrs]
        if missing:
            die("board %s: no address for the %s partition"
                % (board, ", ".join(missing)))
        if reference is None:
            reference = (addrs, sizes)
            ref_board = board
        elif addrs != reference[0]:
            die("the boards of this package disagree about the partition "
                "addresses (%s against %s)" % (board, ref_board))
        for w in plan["writes"]:
            if w["partition"]:
                image_sizes[w["partition"]] = w["bytes"]

    if reference is None:
        layout = derive_layout.build_dtb_layout(tree)
        addrs = {name: p["lba"] for name, p in layout["dtb_partitions"].items()}
        sizes = {name: p["size"] for name, p in layout["dtb_partitions"].items()}
        for part, size in (
                ("resource", "images/resource.img"),
                ("kernel", "images/kernel.img"),
                ("boot", "images/ramdisk.img"),
                ("system", "images/super.img"),
                ("metadata", "images/metadata.img"),
                ("userdata", "images/userdata-head-zero.img")):
            path = os.path.join(tree, size)
            if os.path.isfile(path):
                image_sizes[part] = os.path.getsize(path)
    else:
        addrs, sizes = reference

    values = {}
    for var, part in LBAS.items():
        if part not in addrs:
            die("the device tree has no %s partition" % part)
        values[var] = "0x%05x" % addrs[part]
    for var, part in MAXES.items():
        size = sizes[part]
        if size is None:
            # the partition takes the rest of the disk: the image is a head
            # of it, so the image size is the limit
            size = image_sizes.get(part)
        if size is None:
            die("no size for the %s partition" % part)
        values[var] = str(size)

    system_size = sizes["system"]
    if system_size is None:
        die("the system partition has no fixed size")
    values["SYSTEM_SECTORS"] = "0x%x" % (system_size // SECTOR)
    values["LAYOUT"] = layout

    with open(template) as f:
        text = f.read()
    for name, value in values.items():
        text = text.replace("@%s@" % name, value)
    left = re.findall(r"@[A-Z_]+@", text)
    if left:
        die("%s has placeholders this script does not fill: %s"
            % (template, ", ".join(sorted(set(left)))))

    with open(output, "w") as f:
        f.write(text)
    os.chmod(output, 0o755)
    print("flash.sh: %d board(s), %s"
          % (len(boards), ", ".join(
              "%s=0x%05x" % (var, addrs[part]) for var, part in sorted(LBAS.items()))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
