#!/usr/bin/env bash
# Compare this app's output against the original Python tool for the bundled
# sample files, field by field. Run after ./build.sh.
set -uo pipefail
cd "$(dirname "$0")"

BIN="build/PkgViewer.app/Contents/MacOS/PkgViewer"
PY_REF="../pkg-viewer/pkgviewer.py"
SAMPLES="../pkg-viewer/samples"

[ -x "$BIN" ] || { echo "build the app first: ./build.sh"; exit 1; }
[ -f "$PY_REF" ] || { echo "reference checkout not found at $PY_REF"; exit 1; }

python3 - "$BIN" "$PY_REF" "$SAMPLES" <<'PY'
import subprocess, sys, os
binp, ref, samples = sys.argv[1], sys.argv[2], sys.argv[3]

ns = {}
src = open(ref).read().split("if __name__")[0]
exec(src, ns)
parse_pkg, print_info = ns["parse_pkg"], ns["print_info"]

# Fields we require to agree. Size is intentionally excluded: this build uses
# 1024-based units (macOS convention) while the Python tool uses 1000-based.
FIELDS = ["Platform", "Package", "Content ID", "Title ID", "Region", "Type",
          "Version", "Min. System", "SDK", "DRM", "Content Ver"]

def swift_rows(path):
    out = subprocess.run([binp, "--info", path], capture_output=True, text=True).stdout
    rows = {}
    for line in out.splitlines():
        if ":" in line and not line.startswith("  "):
            k, v = line.split(":", 1)
            if k in FIELDS:
                rows[k] = v.strip()
    return rows

def py_rows(path):
    r = parse_pkg(path)
    return {k: v for k, v in (r.get("rows") or []) if k in FIELDS}

def names(path):
    r = parse_pkg(path)
    return [(e["name"], e["size"]) for e in r.get("entries", [])]

fails = 0
targets = [os.path.join(samples, f) for f in ("sample.pkg", "sample.exfat")]
for t in targets:
    if not os.path.exists(t):
        continue
    print(f"\n=== {os.path.basename(t)} ===")
    sw, py = swift_rows(t), py_rows(t)
    for k in FIELDS:
        a, b = sw.get(k), py.get(k)
        if b is None:
            continue
        if (a or "") == (b or ""):
            print(f"  ok   {k}: {b}")
        else:
            print(f"  FAIL {k}: swift={a!r} python={b!r}")
            fails += 1
    # Entry listing: names + sizes must match.
    out = subprocess.run([binp, "--info", t], capture_output=True, text=True).stdout
    sw_names = []
    started = False
    for line in out.splitlines():
        if line.startswith("--- entries"):
            started = True; continue
        if started and line.startswith("  id="):
            body = line.split("name=", 1)[1]
            nm = body.strip().strip("'")
            sz = int(line.split("size=")[1].split()[0])
            sw_names.append((nm, sz))
    py_names = names(t)
    # Python leaves the name table entry nameless; we fall back to entry_<id>.
    norm = lambda n: tuple(sorted((x[1], "" if x[0].startswith("entry_") else x[0]) for x in n))
    if norm(sw_names) == norm(py_names):
        print(f"  ok   entries ({len(py_names)} files, names+sizes match)")
    else:
        print(f"  FAIL entries:\n    swift  ={sw_names}\n    python ={py_names}")
        fails += 1

print("\n" + ("ALL FIELDS MATCH" if fails == 0 else f"{fails} MISMATCHES"))
sys.exit(1 if fails else 0)
PY
