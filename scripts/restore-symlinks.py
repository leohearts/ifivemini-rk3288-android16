#!/usr/bin/env python3
"""Restore damaged symbolic links if unzipped without symlink support."""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))

restored = 0
for dirpath, dirnames, filenames in os.walk(ROOT):
    if "/.git" in dirpath:
        continue
    for f in filenames:
        p = os.path.join(dirpath, f)
        if not os.path.islink(p) and os.path.getsize(p) < 120:
            try:
                with open(p, "rb") as fp:
                    content = fp.read()
                if (content.startswith(b"../") or content.startswith(b"/") or b".dts" in content or b"test-batch" in content) and b"\n" not in content:
                    target = content.decode("utf-8").strip()
                    os.remove(p)
                    os.symlink(target, p)
                    restored += 1
            except Exception:
                pass

if restored > 0:
    print(f"Restored {restored} symbolic links broken during zip extraction.")
