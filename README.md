# PKG Viewer — macOS

A native macOS port of [Loopayeh/pkg-viewer](https://github.com/Loopayeh/pkg-viewer),
the Windows tool that inspects PS3/PS4/PS5 packages without extracting them.

Rewritten in Swift + SwiftUI. No Python, no runtime dependencies — the parsers,
the crypto and the UI are all in-process.

- **Original project:** pkg-viewer by [Loopayeh](https://github.com/Loopayeh) (MIT)
- **macOS port:** CarlChina

## Build

```bash
./build.sh          # produces build/PkgViewer.app
open build/PkgViewer.app
```

Requires the Swift toolchain (Command Line Tools is enough — no full Xcode).

## What works

| | Format | Status |
|---|---|---|
| PS4 | `.pkg` (bare CNT) | ✅ metadata, entries, cover art |
| PS5 | `.pkg` (FIH + CNT) | ✅ metadata, entries, cover art, **UCP trophies** |
| PS5 | `.exfat` disk images | ✅ read-only FAT walk, cover art, trophy packs |
| PS3 | `.pkg` (NPDRM, retail + debug) | ✅ AES / SHA-1 keystream decryption |
| — | game folders (NPDRM, `PS3_GAME/`, app dumps) | ✅ `sce_sys/param.json` + PNGs |
| PS5 | bare `.ucp` / `.trp` trophy archives | ✅ readable on their own, without a wrapping PKG |
| PS5 | `.ffpfsc` (compressed PFS) | ⚠️ not bundled — needs the `mkpfs` decompressor |
| PS5 | `.ffpkg` (UFS2) | ⚠️ not bundled — needs a UFS2 reader |

Both unsupported formats report a clear reason in the UI rather than failing
silently.

## Features

- **Cover art** from `sce_sys/*.png`, with a thumbnail strip to switch between
  images; Save or Copy to clipboard
- **Format badge** — the small icon under the cover showing the container
  flavour (pkg / exfat / ffpfsc / ffpkg / app folder / PS3 folder)
- **Summary pills** — the five colour-coded badges from the original tool:
  platform, region, size, type, package. Colours follow the original palette
  (exFAT teal, ffpfsc amber, ffpkg violet, PS3 orange, PS4 blue, PS5 white;
  FPKG red vs OFC green; Update blue, DLC orange, base game green). Empty
  values are dropped rather than leaving a blank pill, and the spec grid skips
  whatever the pills already show.
- **Spec card** — Title ID, Content ID, region, version, min. system, SDK, DRM,
  OFC/FPKG detection
- **Files tab** — every entry with id and size, live filter, single-file preview
  (images render inline, everything else hex-dumps), Save
- **Trophies tab** — handles both archive formats:
  - **`.ucp`** (PS5): plaintext `tropmeta_*.json` → full trophy list with names
    and details, plus the pack's own `trophyNpCommId`. Verified on a 31.79 GB
    retail-style dump: 64 trophies, 64 icons, 64/64 matched to art.
  - **Language resolution.** Priority: the user's pick in the globe menu, then
    the pack's own `defaultLanguage` (from its `schemaVersion 1.00` manifest —
    what the console itself shows), then the interface language (`zh-Hans-CN`
    also tries `zh-Hans` and `zh-Hant`), then English. The user's pick is passed
    through `preference(for:explicit:packDefault:)`'s `explicit` parameter — it
    has to outrank the pack default, or the menu silently does nothing.
    Switching re-reads only the metadata, keeping the icons already loaded.
  - **Mislabelled dumps.** Dump tools do not always keep `tropmeta_<locale>.json`
    matched to its contents; measured across two packs, 5–6 of ~20 locales were
    displaced (`ja-JP` holding Italian, `ko-KR` Japanese, `zh-Hans` Russian).
    The displacement has no formula — offsets ran from −16 to +11 — and the
    manifest lists locales without saying which file holds which, so it cannot
    correct the names. What the app does instead is *identify* each file: the
    script is counted across the title and every trophy name, and a file whose
    script contradicts its name is selected by what it really contains. This is
    exact for Han/Kana/Hangul/Cyrillic/Arabic/Thai; the Latin languages share a
    script and cannot be told apart, so those fall back to the filename. A pack
    always ships a correct `en-US`, which is what the English fallback uses.
  - **`.trp`** (PS4 / older PS5): the list lives in ESFM blobs encrypted per
    title. `TROP.ESFM` carries the configuration (id, grade, hidden) and
    `TROP_NN.ESFM` the names; both are decrypted and merged. The NPcommID is not
    stored, so it is derived from the title ID or found by a bounded search —
    see *Trophy key search* below.
  - Picks the real trophy pack, skipping `uds/uds00.ucp` (user data), and
    de-duplicates the per-locale art (`trop0001_en-US.png` ×18 → one image).
  - **The layout never jumps.** A pack with no readable metadata — including one
    whose selected language has no `tropmeta` file — keeps the two-pane shape:
    title, NPCommID, column headers, an inline note, and the preview pane. Only
    the contents change, so switching language cannot resize the window's whole
    appearance.
  - **The icon gallery scrolls.** A pack can carry 40+ icons, so the grid lives
    in a `ScrollView` with its count pinned above it; the tiles are capped at
    104 pt so a wide pane does not stretch them into banners. Without the scroll
    view the grid grew past the window and spilled over the toolbar.
  - **Click a trophy to see its image.** Clicking a row highlights it and shows
    its art, name and description in the right pane; clicking again clears the
    preview. `Export icons` names files after the trophy they belong to.
    - `.ucp`: paired by the `trop####.png` ↔ trophy-id filename convention.
    - `.trp`: the art is *carved* (found by scanning for PNG magics), so the
      filenames are gone. A `.trp` holds two kinds of image — square per-trophy
      icons (240×240 on PS4) and wide group banners (320×176) — so the square
      ones are paired to the trophies in declaration order, and the counts must
      line up. Without a match the pane says so rather than showing the wrong
      art.
- **Details tab** — curated `param.sfo` / `param.json` fields, with a toggle for
  the full dump and a key filter
- **Screenshot** — toolbar button saves the current window as a PNG at full
  Retina resolution, named `<title> - <timestamp>.png`. Captures the real
  backing store, so it matches what is on screen (scroll offset, selected row,
  active tab) and needs no screen-recording permission. The title bar and any
  modal sheet are not included — a sheet is a separate window.
- **Rename** — `Title - TID - vVersion - Region` with per-part toggles, live
  preview, and split-set handling (all parts of `game_0/_1.pkg` move together)
- **Drag & drop** packages, images or folders onto the window
- **Open With / double-click / command-line** support for `.pkg`, `.exfat`,
  `.ffpfsc`, `.ffpkg`
- **Languages** — English, 简体中文, 繁體中文, 日本語. Follows the system
  language by default; override from the **Language** menu in the menu bar.
- **Extracting a `.ucp` by hand** — `Sources/Core/ucp_extract.py <file.ucp> [outdir]`
  dumps every member plus a `MANIFEST.json`; `--all` includes the per-locale
  copies of the art. The Trophies tab's **Export icons** button covers the
  common case (just the icons) without leaving the app.
- **CLI** —
  - `PkgViewer --info <file>` — package summary
  - `PkgViewer --trophies <file>` — trophy pack dump (what the tab shows)
  - `PkgViewer --languages` — list shipped localisations
  - `PkgViewer --lang-check [code]` — dump every UI string for review
  - `PkgViewer --lang <code|system> <file>` — pin the language for a run

  CLI diagnostics stay in English by design: their field names are a stable,
  greppable contract that `verify.sh` diffs against the Python original.

## Localisation

UI strings live in the standard macOS layout:

```
Sources/Resources/
  en.lproj/Localizable.strings        <- base language, complete
  zh-Hans.lproj/Localizable.strings
  zh-Hant.lproj/Localizable.strings
  ja.lproj/Localizable.strings
```

`en` is the base: every key must exist there, and the other files are expected
to match it key-for-key.

**Adding a language**

1. Copy `en.lproj` to `<code>.lproj` and translate the values.
2. Register it in `L10n.Language.all`.
3. Add the code to `CFBundleLocalizations` in `build.sh`.
4. `PkgViewer --lang-check <code>` to review every string; a missing key prints
   the key itself, so gaps are obvious.

**How lookup works**

- `L10n` detects the system language from `Locale.preferredLanguages` and
  matches it against the shipped list, falling back on the primary subtag so
  `zh-Hant-TW` resolves to Chinese Traditional rather than English.
- The menu bar **Language** item pins a language (stored in
  `UserDefaults` under `pkgviewer.language`); "Follow System" clears it.
  The bundle is always pinned explicitly — `Bundle.module` resolves against
  the *system* language, so without this an English pick on a Chinese system
  would still show Chinese.
- `MetaLabel` maps the parsers' English labels (`"Title ID"`, `"Min. System"`)
  to `meta.*` keys at display time, so parser logic can keep matching on
  `rowDict["Region"]` regardless of UI language. A few rows carry English
  *values* that are really UI text (`official`/`debug`, `paid`/`standard`), so
  `displayValue` translates those too. The Details tab passes `localize: false`
  because it shows raw `param.sfo` / `param.json` keys.
- `Message` carries a key + format arguments out of `Core` (which has no
  SwiftUI access) and is resolved by the UI at render time — this is how the
  trophy status lines and parse errors are localised.
- `WindowCapture` uses `NSView.cacheDisplay(in:to:)`, which reads the live
  backing store. `ImageRenderer` would re-render the view tree instead, losing
  scroll position and selection; ScreenCaptureKit would need a permission grant.

**Build note:** `Package.swift` sets `defaultLocalization: "en"`, which makes
SwiftPM's manifest stricter, and `.process("Resources")` is required (not
`.copy`) for the `.lproj` directories to be compiled into the bundle.
`build.sh` therefore passes `--disable-sandbox`; set `SWIFT_SANDBOX=1` to opt
out.

## Trophy key search

A PS4 `.trp` does not store its NPcommID, so the derived title ID often misses
and a search over `NPWR00000_00`…`NPWR19999_00` is needed. Decrypting the whole
blob per candidate costs ~2 000 tries/s, which is ~10 s of work.

The search instead decrypts only the **last ciphertext block** — the one that
carries the PKCS#7 padding — and checks that. A wrong key produces a random
byte there, so roughly 1 candidate in 16 survives to the full check:

| | throughput | 20 000 candidates |
|---|---|---|
| full blob per candidate | ~2 000/s | 10.0 s |
| **last block only** | **~50 000/s** | **0.36 s** |

The last block must be decrypted with the *previous* ciphertext block as the
CBC chaining value, not the IV — `Crypto.aesCBCDecryptWithChaining` exists for
that. The search also runs off the main actor, so the window stays responsive
and shows "Searching for the trophy key…" meanwhile.

## Verifying against the original

`verify.sh` runs this build and the Python original over the same sample files
and diffs every metadata field plus the entry listing:

```bash
./verify.sh
```

Current output on the bundled samples: **all fields match**. (File sizes are
excluded — this build uses 1024-based units per macOS convention, the original
uses 1000-based.)

## Notes on the port

- **No CommonCrypto / CryptoKit dependency.** The CLT SDK does not export the
  CBC/ECB mode constants, and CryptoKit has no raw AES, so SHA-1 and AES-128
  are implemented in `Sources/Core/Crypto.swift`. Both are verified against the
  FIPS-180 and FIPS-197 vectors in the test harness; if you swap in a
  system-backed implementation, re-run the vectors first.
- **SFO header offsets** are `0x08` key table, `0x0C` data table, `0x10` entry
  count — all little-endian. (The magic is `\0PSF`, so compare raw bytes; a
  NUL-trimming string helper will never match it.)
- **exFAT builder quirk preserved:** dumpers often leave the FAT zeroed while
  writing files contiguously, so a zero FAT entry falls through to the next
  cluster instead of ending the chain.
- **Two trophy archive formats.** PS5 dumps ship `.ucp` (magic `b2 28 c6 0a`,
  64-byte big-endian records from `0x40`), whose `tropmeta_*.json` is plaintext
  and carries `trophyNpCommId`; PS4 and older PS5 use `.trp` (magic
  `0x004DA2DC`), whose `TROP.ESFM` is AES-CBC encrypted per title. Do not treat
  one as the other — an `.ucp` never needs the ESFM path, and its metadata has
  no grade field, so grades stay blank rather than being invented.
- **Trophy pack selection:** prefer a pack whose path mentions `trophy`, skip
  `uds*.ucp`, and rank `trophy2/trophy00.ucp` above the PS4-era
  `sce_sys/trophy/`. Entry *ids* are not a reliable signal — a real pack was id
  5248 while id 1034 was unrelated data.
- **A bare path argument is `args[1]`, not `args.first(where:)`** — `args[0]`
  is the executable path and does not start with `-`, so a naive filter picks
  the binary's own path and the real argument is never seen.
- **`WindowGroup(for: URL.self)`** routes double-click and `open -a` through
  `onOpenURL`; a path typed on the command line is not delivered that way, so
  `init()` stashes it and the first window consumes it.

## Layout

```
Sources/
  Core/
    Bytes.swift        bounds-checked readers, size/version/region formatting
    Crypto.swift       SHA-1 + AES-128 (ECB, CBC)
    L10n.swift         language detection, bundle selection, lookup
    SummaryBadge.swift format badge + colour-coded summary pills
    WindowCapture.swift window -> PNG (cacheDisplay, Retina, no permission)
    Message.swift      localisable message (key + format args)
    MetaLabel.swift    metadata label -> localisation key
    LangCheck.swift    --lang-check string dump
    PkgModel.swift     result model, param.sfo, param.json
    PkgParser.swift    FIH + CNT containers, format detection
    PkgLoader.swift    format dispatch, folders, AMPR scan, clean naming
    Exfat.swift        read-only exFAT
    PS3.swift          NPDRM decrypt + parse
    Trophy.swift       UCP + TRP containers, ESFM decrypt, trophy XML, PNG carving
    TrophyLanguage.swift locale-tag matching for trophy metadata
    PkgViewModel.swift async loading, entry reads, trophy dispatch, history
    InfoPrinter.swift  --info CLI
    TrophyPrinter.swift --trophies CLI
  Resources/
    en.lproj/ zh-Hans.lproj/ zh-Hant.lproj/ ja.lproj/   Localizable.strings
  UI/
    Theme.swift        colours, pills, cards
    ContentView.swift  app entry, document scene, language menu, toolbar, panes
    Tabs.swift         overview / files / details, rename sheet
  UI/TrophiesTab.swift  trophy list + click-to-preview art pane
```

## Licence

MIT, matching the original project.

Copyright © Loopayeh (original pkg-viewer) · Copyright © CarlChina (macOS port).
