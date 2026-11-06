#!/usr/bin/env python3
"""Slim the staged Silksong pad-skin art before it is packed into the app.

Run by dm/ios/tools/build_ipa.sh on the staged copies under Gen/dm; the repo's
source art in dm/ios/padskin* is never touched. Two steps, in this order:

1. Dedupe. A badge / black-iron file whose bytes are identical to the plain
   set's file of the same name is dropped from its own set. DmGamepad.m's
   skinImage falls back to the plain set on a miss, and a file is only ever
   dropped when the plain set holds the same bytes, so the pixels every skin
   mode serves are unchanged by construction. (Measured on the shipped sets:
   26 files, 17.08 MB.)
2. Half resolution and a lossless re-encode. Every remaining PNG whose long
   edge exceeds 512 px is packed at half size (Lanczos over premultiplied
   alpha -- the art is RGBA line art on transparency, and resizing straight
   alpha would smear the transparent pixels' colours into the edges), and
   every file is re-saved at the maximum zlib level, which by itself is a
   pixel-identical -3.7 %. The pad keys draw at roughly 190-280 px on a phone
   screen (the stick disc at ~450 px) while the source art is 880-1446 px --
   2-4.6x oversampled -- so half size still leaves 1.6-1.9x headroom.
   (Measured: -67 % per file for the resize.)

Usage: skin_pack_slim.py <plain set dir> [other set dir ...]
The first directory is the canonical (plain) set the loader falls back to;
the rest are deduped against it and slimmed the same way. A later directory
that does not exist is skipped (a build without that set staged).
"""

import hashlib
import io
import os
import sys

try:
    from PIL import Image
except ImportError:
    sys.exit("skin_pack_slim.py needs Pillow (python3 -m pip install Pillow)")

HALVE_ABOVE = 512   # a PNG whose long edge exceeds this is packed at half size


def file_bytes(path):
    with open(path, "rb") as f:
        return f.read()


def dedupe(canonical_dir, other_dirs):
    """Drop a file from a non-canonical set when the canonical set's file of
    the same name is byte-identical. Returns the bytes saved."""
    saved = 0
    for other in other_dirs:
        if not os.path.isdir(other):
            continue
        for name in sorted(os.listdir(other)):
            if not name.endswith(".png"):
                continue
            twin = os.path.join(canonical_dir, name)
            path = os.path.join(other, name)
            if os.path.isfile(twin) and hashlib.md5(file_bytes(twin)).digest() == hashlib.md5(file_bytes(path)).digest():
                saved += os.path.getsize(path)
                os.remove(path)
                print(f"  dedupe: {path} (the plain set's copy is byte-identical)")
    return saved


def slim_file(path):
    """Pack one PNG at half size (when large) with a lossless re-encode.
    Returns (bytes before, bytes after). The re-encode alone never changes a
    pixel: PNG is lossless and the pixels handed to the encoder are the
    decoded source's, or their half-size resample when the file is large."""
    raw = file_bytes(path)
    im = Image.open(io.BytesIO(raw))
    im.load()
    if max(im.size) > HALVE_ABOVE:
        w, h = im.size
        premultiplied = "A" in im.getbands()
        if premultiplied:
            im = im.convert("RGBa")   # premultiplied alpha, so the resample weights colours by coverage
        im = im.resize((max(1, w // 2), max(1, h // 2)), Image.LANCZOS)
        if premultiplied:
            im = im.convert("RGBA")
    im.save(path, format="PNG", optimize=True, compress_level=9)
    return len(raw), os.path.getsize(path)


def slim_set(set_dir):
    if not os.path.isdir(set_dir):
        return (0, 0, 0)
    before = after = 0
    names = [n for n in sorted(os.listdir(set_dir)) if n.endswith(".png")]
    for name in names:
        b, a = slim_file(os.path.join(set_dir, name))
        before += b
        after += a
    return (len(names), before, after)


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    canonical = argv[1]
    if not os.path.isdir(canonical):
        sys.exit(f"skin_pack_slim.py: no such skin set directory: {canonical}")
    others = argv[2:]
    saved = dedupe(canonical, others)
    total_files = total_before = total_after = 0
    for set_dir in [canonical] + others:
        n, before, after = slim_set(set_dir)
        if n:
            print(f"  {set_dir}: {n} files, {before / 1e6:.2f} MB -> {after / 1e6:.2f} MB")
        total_files += n
        total_before += before
        total_after += after
    print(f"skin art slimmed: {total_files} files, dedupe saved {saved / 1e6:.2f} MB, "
          f"resize + re-encode {total_before / 1e6:.2f} MB -> {total_after / 1e6:.2f} MB")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
