#!/usr/bin/env python3
"""Headless regression for PkgViewerMac against the packages in TEST/.

Runs the app's CLI (--info / --covers / --trophies) against each fixture and
asserts the fields that must agree. Pass the folder that holds the .pkg files:

    python3 tests/run_test_cases.py "/Volumes/512 1/TEST"
    python3 tests/run_test_cases.py            # defaults to /Volumes/512 1/TEST

Every assertion is a substring match on the CLI output with runs of whitespace
collapsed to one space, so spacing in the printer cannot break a check.

Exit code is 0 when every check passes, 1 otherwise.
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(ROOT, "build", "PkgViewer.app", "Contents", "MacOS", "PkgViewer")
DEFAULT_DIR = "/Volumes/512/TEST"

# The external drive is not always mounted under the same name (it appears as
# both "512" and "512 1"), so fall back to the other spelling before giving up.
DIR_CANDIDATES = [DEFAULT_DIR, "/Volumes/512 1/TEST"]

# Each fixture: id, the .pkg (or directory) path inside TEST, an --info path
# (already the payload after unwrap, shown in "resolved path"), plus the fields
# the three CLI modes must produce. Patterns are matched after whitespace is
# collapsed, and must appear in the output.
FIXTURES = [
    {
        "id": "PS4-BaseGame-A0100",
        "file": "JP0571-CUSA13694_00-HAMPRDC000000001-A0100-V0100-CyB1K.pkg",
        "info": [
            "TITLE: ACA NEOGEO THE KING OF FIGHTERS 2002",
            "Platform: PS4 (CNT metadata)",
            "Package: FPKG (Fake)",
            "Title ID: CUSA13694",
            "Content ID: JP0571-CUSA13694_00-HAMPRDC000000001",
            "Region: Japan",
            "Type: Base Game",
            "Version: 01.00",
            # SYSTEM_VER is a packed BCD integer (0x05508000) that must decode
            # to 5.50, not print raw as 89161728.
            "Min. System: 5.50",
            "Entries: 31",
            "format badge: ps4",
        ],
        "covers": [
            "icon entry    : icon0.png",
            "candidates    : 6",
            "icon0.png  126183 bytes",
            "pic1.png  1541666 bytes",
        ],
        "trophy": [
            "chosen: trophy/trophy00.trp",
            "NpCommId   : NPWR16488_00",
            "Trophies   : 6",
            "RESULT: OK",
        ],
    },
    {
        "id": "PS4-Update-A0101",
        "file": "JP0571-CUSA13694_00-HAMPRDC000000001-A0101-V0100-CyB1K.pkg",
        "info": [
            "TITLE: ACA NEOGEO THE KING OF FIGHTERS 2002",
            "Platform: PS4 (CNT metadata)",
            "Package: FPKG (Fake)",
            "Title ID: CUSA13694",
            "Region: Japan",
            "Type: Update",
            "Version: 01.01",
            "Base Version: 01.00",
            "Min. System: 5.50",
            "Entries: 38",
            "format badge: ps4",
        ],
        "covers": [
            "icon entry    : icon0.png",
            "candidates    : 6",
        ],
        "trophy": [
            "chosen: trophy/trophy00.trp",
            "RESULT: OK",
        ],
    },
    {
        "id": "PS5-App-Hades2",
        "file": "PPSA36082-Hades2.pkg",
        "info": [
            "TITLE: Hades II",
            "Platform: PS5 (finalized FIH)",
            "Package: FPKG (Fake)",
            "Signature: debug",
            "Title ID: PPSA36082",
            "Content ID: EP4484-PPSA36082_00-0912328937643383",
            "Region: Europe",
            "Type: Application (APP)",
            "Content Ver: 01.006.000",
            "Master Ver: 01.00",
            "Concept ID: 10018449",
            "Min. System: 9.00",
            "DRM: Standard",
            "Entries: 29",
            "format badge: ps5",
        ],
        "covers": [
            "icon entry    : icon0.png",
            "candidates    : 5",
            "icon0.png  428958 bytes",
            "pic1.png  4977596 bytes",
        ],
        "trophy": [
            "chosen: trophy2/trophy00.ucp",
            "NpCommId   : NPWR59398_00",
            "Trophies   : 50",
            "RESULT: OK",
        ],
    },
    {
        "id": "PS3-DirWrap-ShovelKnight",
        "file": "UP2200-NPUB31682_00-SHOVELKNIGHT0001_bg_1_d5854e26ace94df80a5ecffccf09473660a4f010.pkg",
        "info": [
            "TITLE: Shovel Knight",
            "Platform: PS3 NPDRM (retail)",
            "Content ID: UP2200-NPUB31682_00-SHOVELKNIGHT0001",
            "Title ID: NPUB31682",
            "Region: Americas",
            "Version: 01.02",
            "Min. System: 04.7000",
            "Files: 102",
            "format badge: ps3",
        ],
        "covers": [
            "resolved path:",
            "icon entry    : ICON0.PNG",
            "candidates    : 3",
        ],
        "trophy": [
            "chosen: TROPDIR/NPWR08388_00/TROPHY.TRP",
            "plain XML  : yes (no key needed)",
            "NpCommId   : NPWR08388_00",
            "Trophies   : 38",
            "RESULT: OK",
        ],
    },
]


def run(binpath, *args):
    return subprocess.run([binpath, *args], capture_output=True, text=True)


def norm(s):
    return " ".join(s.split())


def check(name, output, patterns):
    out = norm(output)
    for p in patterns:
        if norm(p) not in out:
            return (False, f"missing: {p}")
    return (True, "")


def main():
    test_dir = sys.argv[1] if len(sys.argv) > 1 else None
    if test_dir is None:
        test_dir = next((d for d in DIR_CANDIDATES if os.path.isdir(d)), None)
    if not test_dir or not os.path.isdir(test_dir):
        print("error: TEST dir not found (tried: %s)" % ", ".join(DIR_CANDIDATES))
        print("       pass it explicitly: python3 tests/run_test_cases.py <dir>")
        sys.exit(2)
    if not os.access(BIN, os.X_OK):
        print(f"error: build the app first  ({BIN})")
        sys.exit(2)

    total = fails = 0
    print(f"binary : {BIN}")
    print(f"dir    : {test_dir}\n")

    for fx in FIXTURES:
        path = os.path.join(test_dir, fx["file"])
        if not os.path.exists(path):
            print(f"== {fx['id']} ==  SKIP (missing {fx['file']})")
            fails += 1
            continue
        print(f"== {fx['id']} == {os.path.basename(path)}")

        r = run(BIN, "--info", path)
        ok, why = check("info", r.stdout, fx["info"])
        total += 1
        if ok:
            print(f"  [PASS] info")
        else:
            print(f"  [FAIL] info — {why}")
            fails += 1

        r = run(BIN, "--covers", path)
        ok, why = check("covers", r.stdout, fx["covers"])
        total += 1
        if ok:
            print(f"  [PASS] covers")
        else:
            print(f"  [FAIL] covers — {why}")
            fails += 1

        r = run(BIN, "--trophies", path)
        ok, why = check("trophy", r.stdout, fx["trophy"])
        total += 1
        if ok:
            print(f"  [PASS] trophies")
        else:
            print(f"  [FAIL] trophies — {why}")
            fails += 1
        print()

    print(f"== {total - fails}/{total} checks passed ==")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
