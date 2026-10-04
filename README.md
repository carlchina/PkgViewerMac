# PKG Viewer — macOS

A native macOS viewer for PlayStation packages. Inspects PS3/PS4/PS5 content
without extracting it.

Swift + SwiftUI, no Python, no runtime dependencies — the parsers, the crypto
and the UI all run in-process.

- **Original project:** [pkg-viewer](https://github.com/Loopayeh/pkg-viewer) by
  [Loopayeh](https://github.com/Loopayeh) (MIT)
- **macOS port:** CarlChina

See [Acknowledgements](#acknowledgements) for the projects this port also
learned from.

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
  - **Multilingual trophy text** — the Trophies tab has a language menu listing
    every locale the pack actually ships, so a title with 17 translations can be
    read in any of them without leaving the app. Selection starts from the pack's
    own default (what the console shows) and falls back to the interface
    language, then English; an explicit pick always wins. Switching re-reads only
    the metadata, so the loaded art is kept and the list does not re-scan.
    Dump tools do not always keep `tropmeta_<locale>.json` matched to its
    contents, so each file's script is detected and a label that contradicts the
    text is corrected — exact for Han/Kana/Hangul/Cyrillic/Arabic/Thai.
  - Trophy grade and hidden flags are read from the pack's configuration rather
    than per language file, so they stay correct whichever locale is selected.
- **Rename** — `Title - TID - vVersion - Region` with live preview
- **Screenshot** — saves the window as PNG at full Retina resolution
- **Drag & drop**, plus Open With and double-click support
- **Languages** — English, 简体中文, 繁體中文, 日本語

Note the two are independent: the *interface* language (this list) and the
*trophy* language (whatever the pack provides) are chosen separately.

### Appearance

Follows the system, both Light and Dark, using semantic colours and materials
throughout, so Reduce Transparency and Increase Contrast are honoured rather
than worked around. On macOS 26+ the tab strip is Liquid Glass and one pane of
it slides between tabs; older systems get the flat fill. Deployment target is
macOS 14.

Colours that carry meaning are declared per appearance rather than fixed. The
badge and trophy-grade palettes were originally picked for a dark UI — PS5's
near-white pill reads as "newest console" there — and on a light background the
same values are white on white. Each has a darkened counterpart for Light,
verified by contrast measurement rather than by eye.

Metadata values are shown as the package stores them; only field labels are
translated. A Chinese label beside an English value keeps this pane consistent
with the file itself, the CLI output and Copy Info.

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

## Acknowledgements

This port exists because of, and was built by reading:

- **[Loopayeh/pkg-viewer](https://github.com/Loopayeh/pkg-viewer)** — the original
  project. The parsers, the CLI shape, the summary badges and the overall feature
  set follow it; this is a Swift/SwiftUI rewrite rather than a fork.
- **[pearlxcore/PkgViewer](https://github.com/pearlxcore/PkgViewer)** and the
  [PS4PKGTool](https://github.com/pearlxcore/PS4PKGTool) /
  [PS5PKGTool](https://github.com/pearlxcore/PS5PKGTool) libraries it builds on.
  Their readers are the reference for the **TRP and UCP container layouts** —
  field offsets, header versions, entry sizes — and for the config/text split in
  PS5 trophy metadata. Those offsets were wrong here until they were checked
  against this work; the comments at `Trophy.swift` cite them.
- **[psdevwiki](https://psdev.wiki)** and the wider homebrew scene for the NPDRM
  and ESFM format documentation, including the public trophy master key.

Thanks also to everyone who reported a package that would not parse — several of
the bugs fixed during this port were found that way.

## Licence

MIT, matching the original project.

Copyright © Loopayeh (original pkg-viewer) · Copyright © CarlChina (macOS port).
