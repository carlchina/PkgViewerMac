#!/usr/bin/env python3
"""Extract the members of a PS5 `.ucp` trophy archive.

Layout: 64-byte big-endian records from 0x40, each
`{u32 ?, u32 offset, u32 ?, u32 size, 16 reserved, char name[32]}`.
Names are ASCII; a record with an empty name marks the end of the table.

    ./ucp_extract.py <trophy.ucp> [outdir]

Only the neutral `trop####.png` icons are written by default — a pack repeats
the same art once per locale (`icon0_en-US.png` and friends). Pass `--all` to
dump every member verbatim.
"""
import json
import os
import struct
import sys

MAGIC = b"\xb2\x28\xc6\x0a"
REC = 64
HEADER = 0x40


def read_members(data):
    """Yield (name, offset, size) for each file record.

    The table ends when a record's payload would run past the end of the file,
    which happens well before the name field is blank: the last member is a
    large PNG whose bytes look like more records. So the bound is checked
    first, and a record is only accepted when the name is printable ASCII.
    """
    if len(data) < HEADER or data[:4] != MAGIC:
        raise SystemExit("not a UCP archive (magic %s)" % data[:4].hex())
    out = []
    base = HEADER
    while base + REC <= len(data) and len(out) < 10_000:
        _flags, off, _pad, size = struct.unpack_from(">4I", data, base)
        raw = data[base + 32:base + 64]

        # Past the last member the payload itself is being read as records;
        # those bytes give an absurd offset, so stop.
        if off + size > len(data):
            break

        # Names are ASCII; anything else means we are in the payload.
        if not raw or not all(0x20 <= b < 0x7F for b in raw.split(b"\x00")[0]):
            break
        name = raw.split(b"\x00")[0].decode("ascii")

        if size == 0 and off == 0:
            base += REC               # tombstone (a zero-size icon0)
            continue
        out.append((name, off, size))
        base += REC
    return out


def safe(name):
    """Keep the archive's own names, minus anything path-like."""
    for ch in ("/", "\\"):
        name = name.replace(ch, "_")
    return name.strip().lstrip(".") or "unnamed"


def is_locale_copy(name):
    """True for the per-locale duplicates of the same art.

    A pack ships `trop0000.png` once and, for some titles, `icon0_en-US.png`
    and `gr0001_ja-JP.png` alongside it. The neutral `trop####.png` set is what
    the app shows, so the localised copies are skipped by default.
    """
    lower = name.lower()
    if not lower.startswith("trop") or not lower.endswith(".png"):
        return False
    stem = name.rsplit(".", 1)[0]
    return "_" in stem


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not args:
        raise SystemExit(__doc__)
    dump_all = "--all" in sys.argv
    src = args[0]
    outdir = args[1] if len(args) > 1 else os.path.join(
        os.path.dirname(os.path.abspath(src)),
        os.path.splitext(os.path.basename(src))[0] + "_extracted")

    data = open(src, "rb").read()
    members = read_members(data)
    os.makedirs(outdir, exist_ok=True)

    written, skipped = 0, 0
    for name, off, size in members:
        if not dump_all and is_locale_copy(name):
            skipped += 1
            continue
        blob = data[off:off + size]
        dest = os.path.join(outdir, safe(name))
        with open(dest, "wb") as f:
            f.write(blob)
        written += 1

    print("source : %s (%.1f MB)" % (src, len(data) / 1048576))
    print("members: %d" % len(members))
    print("written: %d -> %s" % (written, outdir))
    if skipped:
        print("skipped: %d localised copies (--all to include)" % skipped)

    # Some packs name an image `tropconf.json`; trust the bytes over the name
    # so the dump opens in a normal image viewer.
    for name, off, size in members:
        p = os.path.join(outdir, safe(name))
        if not os.path.exists(p):
            continue
        with open(p, "rb") as f:
            if f.read(8) == b"\x89PNG\r\n\x1a\n" and not name.lower().endswith(".png"):
                fixed = p + ".png"
                os.rename(p, fixed)
                print("note   : %s is a PNG despite its name -> %s"
                      % (name, os.path.basename(fixed)))

    # A short manifest so the dump is self-describing.
    manifest = {
        "source": os.path.abspath(src),
        "members": [
            {"name": n, "offset": o, "size": s,
             "extracted": not (not dump_all and is_locale_copy(n))}
            for n, o, s in members
        ],
    }
    mpath = os.path.join(outdir, "MANIFEST.json")
    with open(mpath, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2, ensure_ascii=False)
    print("manifest: %s" % mpath)

    # Point out the trophy metadata, which is what the app reads.
    metas = [n for n, _, _ in members if n.startswith("tropmeta_")
             and n.endswith(".json")]
    if metas:
        print("\ntrophies : %d languages" % len(metas))
        for n in sorted(metas):
            print("   %s" % n.replace("tropmeta_", "").replace(".json", ""))


if __name__ == "__main__":
    main()
