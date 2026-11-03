#!/usr/bin/env python3
"""Repack the bundled CPython install into android/app/src/main/jniLibs.

The upstream youtubedl-android artifact ships a full Termux-based CPython
distribution. Most of it is fine to redistribute (PSF-2.0, MIT, Apache-2.0,
X11, public domain), but three libraries are GPL-3.0 and are not needed by an
extractor:

    libreadline / libhistory   (GNU Readline, GPL-3.0)
    libgdbm / libgdbm_compat   (GNU dbm, GPL-3.0)

Dropping them - together with the two extension modules that link them - leaves
a payload with no copyleft code, at the cost of the interactive history editing
and the dbm.gnu backend, neither of which yt-dlp uses.

Usage:
    python tools/repack_engine.py --source path/to/extracted-aar --abi arm64-v8a
"""

from __future__ import annotations

import argparse
import os
import shutil
import sys
import zipfile

# GPL-3.0 files removed from the payload.
GPL_FILES = (
    "usr/lib/libreadline",
    "usr/lib/libhistory",
    "usr/lib/libgdbm",
    "usr/lib/python3.12/lib-dynload/readline.cpython",
    "usr/lib/python3.12/lib-dynload/_gdbm.cpython",
)

# Optional dead weight: test module, never imported by the extractor.
EXTRA_DROP = ("usr/lib/python3.12/lib-dynload/_ctypes_test.cpython",)


def is_dropped(name: str) -> bool:
    return any(name.startswith(prefix) for prefix in GPL_FILES + EXTRA_DROP)


def repack(source_zip: str, target_zip: str) -> tuple[int, int, int]:
    kept = dropped = 0
    dropped_bytes = 0
    removed = []
    with zipfile.ZipFile(source_zip) as src, zipfile.ZipFile(
        target_zip, "w", zipfile.ZIP_DEFLATED, compresslevel=9
    ) as dst:
        for info in src.infolist():
            if is_dropped(info.filename):
                dropped += 1
                dropped_bytes += info.file_size
                removed.append(info.filename)
                continue
            dst.writestr(info, src.read(info.filename))
            kept += 1
    for name in removed:
        print(f"  dropped {name}")
    return kept, dropped, dropped_bytes


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", required=True, help="directory holding the AAR's jni/ tree")
    ap.add_argument("--out", required=True, help="jniLibs directory of the app")
    ap.add_argument("--abi", nargs="+", default=["arm64-v8a", "armeabi-v7a", "x86_64"])
    args = ap.parse_args()

    for abi in args.abi:
        src = os.path.join(args.source, abi, "libpython.zip.so")
        if not os.path.exists(src):
            print(f"missing {src}", file=sys.stderr)
            return 1
        dst_dir = os.path.join(args.out, abi)
        os.makedirs(dst_dir, exist_ok=True)
        dst = os.path.join(dst_dir, "libpython.zip.so")
        before = os.path.getsize(src)
        print(f"{abi}: repacking {before / 1e6:.1f} MB")
        kept, dropped, dropped_bytes = repack(src, dst)
        after = os.path.getsize(dst)
        print(
            f"{abi}: kept {kept} entries, dropped {dropped} "
            f"({dropped_bytes / 1e6:.1f} MB uncompressed), "
            f"{before / 1e6:.1f} -> {after / 1e6:.1f} MB on disk"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
