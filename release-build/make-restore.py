#!/usr/bin/env python3
"""make-restore.py OUT_DIR - build the per-board rescue data of a release package.

Every board gets its own directory under OUT_DIR/devices/<board>/:

  device.json          board id, display name, the LBAs where the parameter
                       structures live, and a note about the loader area
  parameter-p1.img     the board's p1 parameter partition image (4 MiB, the
                       parameter structure 4x, 1 MiB apart)
  parameter-loader.img the loader-area parameter region (4 MiB, the parameter
                       structure 8x, 512 KiB apart)
  head-4M.bin          optional: the board's first 4 MiB of eMMC (idblock +
                       u-boot.itb), for the case where the loader area was
                       erased and rkdeveloptool cannot write it

The board definitions live in release-build/boards/<board>.json; each one
points at the stock backup of that board and gives the LBAs of the two
parameter regions.  The stock backup is read-only and never modified.

The source directory can be overridden per board with the STOCK_BACKUP_DIR
environment variable (it then applies to every board).

Every output is checked: the parameter images must be exactly 4 MiB and hold
the expected number of "PARM" structures at the expected offsets, and the
loader head must carry the Rockchip "RK32" tag.  A failing check is fatal.
A missing source file is not fatal: the affected outputs are skipped with a
warning.
"""
import argparse
import gzip
import hashlib
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_STOCK_BACKUP_DIR = "/home/leohearts/rk3288-ifive-mini4s/stock-backup"
BOARDS_DIR = os.path.join(HERE, "boards")

IMG_SIZE = 4 * 1024 * 1024
PARM_MAGIC = b"PARM"

# p1 partition image: 4 copies of the parameter structure, 1 MiB apart
P1_PARM_OFFSETS = (0x000000, 0x100000, 0x200000, 0x300000)
# loader-area parameter region: 8 copies, 512 KiB apart
LOADER_PARM_OFFSETS = tuple(i * 0x80000 for i in range(8))

# bootloader-8M.bin is a dump of raw sectors 0..0x3FFF; the loader-area
# parameter region is the second 4 MiB of it
LOADER_SLICE_START = 0x400000
LOADER_SLICE_LEN = 0x400000

HEAD4_SIZE = 4 * 1024 * 1024
# the u-boot.itb starts at eMMC sector 0x44 and carries the Rockchip tag "RK32"
RK32_OFFSET = 0x44 * 512
RK32_TAG = b"RK32"


def die(msg):
    print("STOP: %s" % msg, file=sys.stderr)
    sys.exit(3)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def gunzip(path):
    try:
        with gzip.open(path, "rb") as f:
            return f.read()
    except OSError as e:
        die("cannot read %s: %s" % (path, e))


def parm_offsets(data):
    """Offsets of every PARM structure in a buffer."""
    out = []
    start = 0
    while True:
        i = data.find(PARM_MAGIC, start)
        if i < 0:
            return out
        out.append(i)
        start = i + 1


def check_parm(name, data, expected):
    found = parm_offsets(data)
    print("   %s: %d PARM structure(s) at %s"
          % (name, len(found), ", ".join("0x%x" % o for o in found)))
    if tuple(found) != tuple(expected):
        die("%s holds PARM structures at %s, expected %s"
            % (name, ", ".join("0x%x" % o for o in found),
               ", ".join("0x%x" % o for o in expected)))
    print("   %s: PARM layout OK" % name)


def load_board(path):
    try:
        with open(path, "r") as f:
            board = json.load(f)
    except ValueError as e:
        die("%s: invalid JSON (%s)" % (path, e))
    except OSError as e:
        die("cannot read %s: %s" % (path, e))
    for key in ("board", "display_name", "stock_backup_dir",
                "p1_parameter_gz", "bootloader_8m_gz",
                "parameter_region_lba", "p1_lba",
                "loader_area_raw_start", "loader_area_lba_raw",
                "loader_area_lba_tool"):
        if key not in board:
            die("%s: missing %r" % (path, key))
    return board


def build_board(out_dir, board):
    """Build devices/<board>/ for one board definition."""
    board_id = board["board"]
    dev_dir = os.path.join(out_dir, "devices", board_id)
    os.makedirs(dev_dir, exist_ok=True)

    # STOCK_BACKUP_DIR overrides the board's directory. If unset, check the repo's
    # own stock-backup/ folder before falling back to the board's stock_backup_dir.
    repo_stock = os.path.join(HERE, "..", "stock-backup")
    default_src = repo_stock if os.path.isdir(repo_stock) else board["stock_backup_dir"]
    src_dir = os.environ.get("STOCK_BACKUP_DIR") or default_src
    p1_gz = os.path.join(src_dir, board["p1_parameter_gz"])
    bl_gz = os.path.join(src_dir, board["bootloader_8m_gz"])
    have_p1 = os.path.isfile(p1_gz)
    have_bl = os.path.isfile(bl_gz)

    print("== board %s (%s)" % (board_id, board["display_name"]))
    print("   stock backup: %s" % src_dir)

    device = {
        "board": board_id,
        "display_name": board["display_name"],
        "parameter_region_lba": int(board["parameter_region_lba"]),
        "p1_lba": int(board["p1_lba"]),
        # the loader area (the first 4 MiB of the eMMC) and the two ways its
        # address can be counted; write-loader-head.sh reads them from here
        "loader_area_raw_start": int(board["loader_area_raw_start"]),
        "loader_area_lba_raw": int(board["loader_area_lba_raw"]),
        "loader_area_lba_tool": int(board["loader_area_lba_tool"]),
        "loader_area_note": board.get("loader_area_note", ""),
        "files": {
            "parameter_loader": "devices/%s/parameter-loader.img" % board_id,
            "parameter_p1": "devices/%s/parameter-p1.img" % board_id,
        },
    }

    # ---- loader head (the part below tool LBA 0) ----
    if have_bl:
        bl = gunzip(bl_gz)
        print("   %s decompressed: %d bytes  sha256 %s"
              % (board["bootloader_8m_gz"], len(bl), sha256(bl)))
        if len(bl) != 8 * 1024 * 1024:
            die("%s decompresses to %d bytes, expected %d"
                % (board["bootloader_8m_gz"], len(bl), 8 * 1024 * 1024))
        digest = sha256(bl)
        if "head8_sha256" in board and digest != board["head8_sha256"]:
            die("%s decompresses to sha256 %s, expected %s"
                % (board["bootloader_8m_gz"], digest, board["head8_sha256"]))
        head4 = bl[:HEAD4_SIZE]
        head4_digest = sha256(head4)
        if "head4_sha256" in board and head4_digest != board["head4_sha256"]:
            die("the loader head has sha256 %s, expected %s"
                % (head4_digest, board["head4_sha256"]))
        tag = head4[RK32_OFFSET:RK32_OFFSET + len(RK32_TAG)]
        if tag != RK32_TAG:
            die("the loader head has no %s tag at byte offset 0x%x"
                % (RK32_TAG.decode(), RK32_OFFSET))
        with open(os.path.join(dev_dir, "head-8M.bin"), "wb") as f:
            f.write(bl)
        with open(os.path.join(dev_dir, "head-4M.bin"), "wb") as f:
            f.write(head4)
        device["files"]["head_8m"] = "devices/%s/head-8M.bin" % board_id
        device["files"]["head_4m"] = "devices/%s/head-4M.bin" % board_id
        device["head8_sha256"] = digest
        device["head4_sha256"] = head4_digest
        print("   head-8M.bin: %d bytes  sha256 %s"
              % (len(bl), digest))
        print("   head-4M.bin: %d bytes  sha256 %s  (RK32 tag at 0x%x)"
              % (len(head4), head4_digest, RK32_OFFSET))
    else:
        print("WARNING: %s not found - skipping head-4M.bin" % bl_gz)
        print("WARNING: a tablet with an erased loader area cannot be restored "
              "from this package")

    # ---- the p1 parameter image ----
    # It comes from the p1 parameter partition of the stock backup and has
    # nothing to do with the bootloader dump, so it is built whenever the p1
    # parameter file is there.
    if not have_p1:
        print("WARNING: %s not found - skipping parameter-p1.img" % p1_gz)
        print("WARNING: a wiped tablet cannot be restored from this package")
        return None

    p1 = gunzip(p1_gz)
    print("   %s decompressed: %d bytes  sha256 %s"
          % (board["p1_parameter_gz"], len(p1), sha256(p1)))
    if len(p1) != IMG_SIZE:
        die("%s decompresses to %d bytes, expected %d"
            % (board["p1_parameter_gz"], len(p1), IMG_SIZE))
    if "p1_sha256" in board and sha256(p1) != board["p1_sha256"]:
        die("%s decompresses to sha256 %s, expected %s"
            % (board["p1_parameter_gz"], sha256(p1), board["p1_sha256"]))
    check_parm("parameter-p1.img", p1, P1_PARM_OFFSETS)
    with open(os.path.join(dev_dir, "parameter-p1.img"), "wb") as f:
        f.write(p1)

    # ---- the loader-area parameter image ----
    # The loader area holds a second copy of the parameter structure: it lives
    # in the bootloader dump at byte offset 0x2000..0x3FFF (eMMC sectors
    # 0x2000..0x3FFF, the tool LBA 0 region), 8 copies 512 KiB apart.
    if not have_bl:
        print("WARNING: %s not found - skipping parameter-loader.img" % bl_gz)
        print("WARNING: the loader-area parameter copy cannot be restored from "
              "this package")
        del device["files"]["parameter_loader"]
    else:
        loader = bl[LOADER_SLICE_START:LOADER_SLICE_START + LOADER_SLICE_LEN]
        if len(loader) != IMG_SIZE:
            die("the loader parameter region is %d bytes, expected %d"
                % (len(loader), IMG_SIZE))
        if "parameter_loader_sha256" in board and sha256(loader) != board["parameter_loader_sha256"]:
            die("the loader parameter region has sha256 %s, expected %s"
                % (sha256(loader), board["parameter_loader_sha256"]))
        check_parm("parameter-loader.img", loader, LOADER_PARM_OFFSETS)
        with open(os.path.join(dev_dir, "parameter-loader.img"), "wb") as f:
            f.write(loader)

    device["parameter_region_lba"] = int(board["parameter_region_lba"])
    device["p1_lba"] = int(board["p1_lba"])
    with open(os.path.join(dev_dir, "device.json"), "w") as f:
        json.dump(device, f, indent=2, sort_keys=True)
        f.write("\n")

    print("== %s written to %s" % (board_id, dev_dir))
    for name in ("parameter-loader.img", "parameter-p1.img", "head-4M.bin"):
        path = os.path.join(dev_dir, name)
        if not os.path.isfile(path):
            continue
        with open(path, "rb") as f:
            digest = sha256(f.read())
        print("   %-24s %d bytes  sha256 %s"
              % (name, os.path.getsize(path), digest))
    print("   parameter structures -> tool LBA 0x%05x (loader area), 0x%05x (p1)"
          % (int(board["parameter_region_lba"]), int(board["p1_lba"])))
    return device


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("out_dir", help="the release package directory")
    ap.add_argument("--boards-dir", default=BOARDS_DIR, help="where the board definitions live")
    ap.add_argument("--board", action="append", help="build only this board (repeatable)")
    args = ap.parse_args()

    out_dir = os.path.abspath(args.out_dir)
    os.makedirs(os.path.join(out_dir, "devices"), exist_ok=True)

    if not os.path.isdir(args.boards_dir):
        die("no board definitions in %s" % args.boards_dir)
    names = sorted(n for n in os.listdir(args.boards_dir) if n.endswith(".json"))
    if args.board:
        names = [n for n in names if n[:-5] in args.board]
        if not names:
            die("no board definition for %s" % ", ".join(args.board))
    if not names:
        die("no board definitions in %s" % args.boards_dir)

    built = []
    for name in names:
        board = load_board(os.path.join(args.boards_dir, name))
        if build_board(out_dir, board) is not None:
            built.append(board["board"])
    if not built:
        print("WARNING: no board got a complete parameter set - the package "
              "cannot restore a wiped tablet")
        return 0
    print("== boards with rescue data: %s" % ", ".join(built))
    return 0


if __name__ == "__main__":
    sys.exit(main())
