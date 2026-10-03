# PKG Viewer — macOS

A native macOS viewer for PlayStation packages. Inspects PS3/PS4/PS5 content
without extracting it.

Swift + SwiftUI, no Python, no runtime dependencies — the parsers, the crypto
and the UI all run in-process.

- **Original project:** [pkg-viewer](https://github.com/Loopayeh/pkg-viewer) by
  [Loopayeh](https://github.com/Loopayeh) (MIT)
- **macOS port:** CarlChina

## Build

```bash
./build.sh          # produces build/PkgViewer.app
open build/PkgViewer.app
```

The Swift toolchain is enough — Command Line Tools, no full Xcode required.

## Supported formats

| | Format | Notes |
|---|---|---|
| PS4 | `.pkg` (CNT) | metadata, entries, cover art |
| PS5 | `.pkg` (FIH + CNT) | metadata, entries, cover art, trophies |
| PS5 | `.exfat` images | read-only, cover art, trophy packs |
| PS3 | `.pkg` (NPDRM) | retail and debug, AES / SHA-1 decryption |
| PS5 | bare `.ucp` / `.trp` | trophy archives read on their own |
| — | game folders | `sce_sys/param.json`, `PS3_GAME/`, NPDRM extracts |
| PS5 | `.ffpfsc`, `.ffpkg` | not supported — need external tools |

The last row reports a clear reason in the UI rather than failing silently.

## Features

- **Cover art** with a thumbnail strip; save or copy to clipboard
- **Key art as the page backdrop** on the overview
- **Summary pills** — platform, region, size, type, package
- **Files tab** — every entry with a filter and inline preview
- **Trophies tab** — both archive formats, per-trophy art on click, export
- **Rename** — `Title - TID - vVersion - Region` with live preview
- **Screenshot** — saves the window as PNG at full Retina resolution
- **Drag & drop**, plus Open With and double-click support
- **Languages** — English, 简体中文, 繁體中文, 日本語

Trophy text follows the pack's own language list; the globe menu overrides it.
Switching language re-reads only the metadata, keeping loaded art.

## CLI

```bash
PkgViewer --info <file>          # package summary
PkgViewer --trophies <file>      # trophy pack dump
PkgViewer --covers <file>        # cover art, optionally --export-to <dir>
PkgViewer --languages            # list shipped localisations
PkgViewer --lang-check [code]    # dump every UI string for review
```

CLI output stays in English by design: the field names are a stable contract
that `verify.sh` diffs against the original.

## Adding a language

1. Copy `Sources/Resources/en.lproj` to `<code>.lproj` and translate the values.
2. Register the code in `L10n.Language.all`.
3. Add it to `CFBundleLocalizations` in `build.sh`.
4. Run `PkgViewer --lang-check <code>` — a missing key prints as the key itself.

`en` is the base language; the other files are expected to match it
key-for-key.

## Verifying

`verify.sh` runs this build and the Python original over the same files and
diffs every metadata field plus the entry listing:

```bash
./verify.sh          # → ALL FIELDS MATCH
```

## Notes for contributors

Implementation details worth knowing before changing the parsers — container
layouts, the NPDRM keystream, the ESFM key search, the UCP/TRP differences —
are documented in comments at the relevant code. Two that are easy to trip
over:

- **`Data.subdata(in:)` traps** on an out-of-range index rather than returning
  nil. Every read is bounds-checked; keep it that way.
- **Container entry tables are authoritative.** Both UCP and TRP carry a
  member count in their header. Read exactly that many entries rather than
  scanning until something looks wrong — a scan silently drops entries whose
  payload is zero-length.

## Licence

MIT, matching the original project.

Copyright © Loopayeh (original pkg-viewer) · Copyright © CarlChina (macOS port).
