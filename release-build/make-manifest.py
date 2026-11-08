#!/usr/bin/env python3
"""make-manifest.py TREE - write the manifest of a release package.

The manifest records, per board, the write map derived from the package data:
the partition table of the device tree inside images/resource.img, the
partition table of the board's parameter structure, and the address of every
file the restore writes.  guard-release.py recomputes it and compares.
"""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DERIVE = os.path.join(HERE, "derive-layout.py")


def main():
    if len(sys.argv) != 2:
        print("usage: make-manifest.py TREE", file=sys.stderr)
        return 64
    tree = os.path.abspath(sys.argv[1])
    devices = os.path.join(tree, "devices")
    if not os.path.isdir(devices):
        print("STOP: %s has no devices/ directory" % tree, file=sys.stderr)
        return 3
    out = {"schema": 1, "boards": {}}
    for board in sorted(os.listdir(devices)):
        if not os.path.isfile(os.path.join(devices, board, "device.json")):
            continue
        res = subprocess.run([sys.executable, DERIVE, "--package", tree,
                              "--board", board, "--format", "json"],
                             capture_output=True, text=True)
        if res.returncode != 0:
            sys.stderr.write(res.stderr)
            print("STOP: cannot derive the layout of %s" % board, file=sys.stderr)
            return 3
        out["boards"][board] = json.loads(res.stdout)
    if not out["boards"]:
        print("STOP: %s has no board with a device.json" % tree, file=sys.stderr)
        return 3
    with open(os.path.join(tree, "manifest.json"), "w") as f:
        json.dump(out, f, indent=2, sort_keys=True)
        f.write("\n")
    print("manifest.json: %d board(s): %s"
          % (len(out["boards"]), ", ".join(out["boards"])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
