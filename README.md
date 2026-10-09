# PKG Viewer — macOS

<img width="940" height="648" alt="image" src="https://github.com/user-attachments/assets/31085614-f2e9-48f6-bdab-86c661ea260d" />


A native macOS viewer for PlayStation packages. Inspects PS3/PS4/PS5 content
without extracting it.

Swift + SwiftUI, no Python, no runtime dependencies — the parsers, the crypto
and the UI all run in-process.

- **Original project:** [pkg-viewer](https://github.com/Loopayeh/pkg-viewer) by
  [Loopayeh](https://github.com/Loopayeh) (MIT)
- **macOS port:** CarlChina

See [Acknowledgements](#acknowledgements) for the projects this port also
learned from.

## Install

Download `PkgViewer-1.2.1-universal.zip` from the [releases](https://github.com/carlchina/PkgViewerMac/releases), then:

```bash
unzip PkgViewer-1.2.1-universal.zip
xattr -r -d com.apple.quarantine PkgViewer.app     # see the note below
open PkgViewer.app
```

**Why the `xattr` step is needed.** The download is **ad-hoc signed**, not
signed with a Developer ID certificate, and has not been notarised. macOS
therefore treats it as an unverified developer: `spctl` reports `rejected` and
Gatekeeper blocks the launch. The `com.apple.quarantine` attribute is the flag
that triggers this, and clearing it is what tells Gatekeeper you have made your
own decision.

Building from source (below) sidesteps the question entirely — the app is
produced locally and never gets a quarantine flag.

Building from source is the better choice whenever you can: it is
straightforward on any Mac with Command Line Tools, you can read exactly what
you run, and you are trusting a compiler you already have rather than a
prebuilt binary. Use the download when you want a quick look or you are on a
machine where setting up a toolchain is not worth it.

First launch can also be done by right-clicking the app and choosing **Open**
once, which is the same decision expressed through the UI.

## Build

```bash
./build.sh          # produces build/PkgViewer.app
open build/PkgViewer.app
```

The Swift toolchain is enough — Command Line Tools, no full Xcode required.

The default build is **universal** (arm64 + x86_64) so the app runs on Apple
silicon and Intel alike. Cross-compiling is what takes the extra time; narrow it
when you do not need both:

```bash
ARCHS=arm64 ./build.sh          # native only, faster
ARCHS=x86_64 ./build.sh         # Intel only
```

The script verifies the architectures in the finished binary against `ARCHS`
and fails if they do not match, so a single-arch result cannot ship unnoticed.

Each build bumps the number in parentheses after the version (`1.2.1 (1)`), so a
screenshot or a bug report can be tied to an exact binary. The counter is read
back from the previous bundle, which means a fresh clone starts at `1` and a
deleted `build/` restarts there too. For a release, freeze it:

```bash
NO_BUMP=1 ./build.sh       # keep the current number
BUILD=42 ./build.sh        # set an exact one
```

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
| Switch | `.nsp`, `.xci` | packages and gamecard images |
| Switch | `.nsz`, `.xcz` | the compressed forms of the above |

The last unsupported row reports a clear reason in the UI rather than failing
silently.

Switch metadata comes from the package's `cnmt.xml` or the binary CNMT inside
its Meta NCA. Installing `prod.keys` at `~/.switch/prod.keys` additionally
unlocks the official NACP title, publisher, display version and icon, and the
authoritative per-NCA types. Entries an NSZ re-packed as `.ncz` are listed as
compressed — their headers go with the compression.

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
macOS 12.

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
