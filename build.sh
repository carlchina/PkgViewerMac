#!/usr/bin/env bash
# Build PkgViewerMac.app from source.
#
# SDK choice is pinned to 26.5 for a reason that is easy to get wrong.
#
# Command Line Tools ships no macro plugins at all — no PreviewsMacros, no
# SwiftUIMacros — and neither does any SDK in /Library/Developer. The macOS 27
# SDK cannot compile a single `@State`: its SwiftUICore interface declares 24
# `#externalMacro(module: "SwiftUIMacros", …)` references (26.5 declares 10,
# none of which the compiler must expand), so every property wrapper fails with
# "plugin for module 'SwiftUIMacros' not found". 26.5 compiles clean.
#
# Both SDKs ship the same module architectures (arm64e + x86_64 only, no plain
# arm64), so "has arm64 modules" is not the test — 27 passes that and still
# fails. The only real fix is installing the full Xcode, which bundles the
# plugins. Until then: override with SDK=/path/to/SDK.
set -euo pipefail

cd "$(dirname "$0")"

SDK="${SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
if [ ! -d "$SDK" ]; then
  # Fall back to the newest SDK that does not require a missing macro plugin.
  # Keyed on the version, not on module layout: 26.x works, 27+ does not (as of
  # CLT 16.4 / Swift 6.4). Verified by compiling a @State probe against each.
  for c in $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk 2>/dev/null | sort -Vr); do
    SDK="$c"; break
  done
fi
echo "==> SDK: $SDK"

CONFIG="${CONFIG:-release}"
echo "==> Building ($CONFIG)…"
# SwiftPM's manifest step spawns its own sandbox, which fails when this
# script already runs inside one. `defaultLocalization` in Package.swift also
# makes the manifest stricter, so pass --disable-sandbox by default and allow
# opting out via SWIFT_SANDBOX=1.
#
# ARCHS controls the target architectures. SwiftPM builds only for the host
# architecture unless told otherwise, so a plain `swift build` yields a
# single-arch binary that runs on Apple silicon and nothing else. The default
# here is a universal binary, because "open the .app and it works" should not
# depend on which Mac it was downloaded from — Intel Macs are still a real
# audience and Rosetta is not something to require of them.
#
#   ARCHS=arm64 ./build.sh              native only, faster
#   ARCHS=x86_64 ./build.sh             Intel only
#   ARCHS="arm64 x86_64" ./build.sh     universal (default)
ARCH_LIST="${ARCHS:-arm64 x86_64}"
HOST_ARCH="$(uname -m)"
BUILD_DIR=".build"

TARGETS=()
BINS=()

# One --triple per architecture, each with its own build directory: SwiftPM
# shares state per build path, and sharing one between arches makes it reuse
# object files compiled for the wrong target.
TARGETS=()
for a in $ARCH_LIST; do
  case "$a" in
    arm64)  triple="arm64-apple-macosx12.0" ;;
    x86_64) triple="x86_64-apple-macosx12.0" ;;
    *) echo "warning: unsupported ARCHS entry '$a' (expected arm64 or x86_64), skipping" >&2; continue ;;
  esac
  bp="$BUILD_DIR/$a"
  extra_flags=""
  if [ "$a" = "x86_64" ]; then
    # CLT on Apple Silicon lacks x86_64 slices for libswiftCompatibility56.a;
    # allow dynamic lookup for force-loaded compatibility symbols.
    extra_flags="-Xlinker -undefined -Xlinker dynamic_lookup"
  fi
  if [ "${SWIFT_SANDBOX:-0}" = "1" ]; then
    TARGETS+=("swift build -c $CONFIG --sdk $SDK --triple $triple --build-path $bp $extra_flags")
  else
    TARGETS+=("swift build --disable-sandbox -c $CONFIG --sdk $SDK --triple $triple --build-path $bp $extra_flags")
  fi
  BINS+=("$bp/$CONFIG/PkgViewerMac")
done

if [ ${#TARGETS[@]} -eq 0 ]; then
  echo "error: no usable architectures in ARCHS='$ARCH_LIST'" >&2
  exit 1
fi

# The per-arch build dirs differ from the old shared .build path, so a stale
# arm64-only tree can be sitting there and get picked up as if it were current.
# Only prune the paths this script owns; leave anything else alone.
for d in "$BUILD_DIR"/arm64 "$BUILD_DIR"/x86_64; do
  [ -d "$d" ] && rm -rf "$d"
done

for t in "${TARGETS[@]}"; do
  $t
done

APP="build/PkgViewer.app"

# CFBundleVersion is the build counter shown in parentheses next to the version
# (1.1 (7)). It is bumped on every run so a screenshot or bug report can be tied
# to an exact binary.
#
# The previous number is read from the app bundle that is about to be replaced,
# so this must happen *before* the rm -rf below — afterwards the plist is gone
# and every build would silently restart at 1.
#
#   NO_BUMP=1 ./build.sh     keep the current number (release builds)
#   BUILD=42 ./build.sh      force an exact number
CUR_BUILD=0
if [ -f "$APP/Contents/Info.plist" ]; then
  CUR_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist" 2>/dev/null || echo 0)
  # PlistBuddy echoes an error for a missing key; fall back rather than trust it.
  case "$CUR_BUILD" in ''|*[!0-9]*) CUR_BUILD=0 ;; esac
fi
if [ -n "${BUILD:-}" ]; then
  NEXT_BUILD="$BUILD"
elif [ "${NO_BUMP:-0}" = "1" ]; then
  NEXT_BUILD="$((CUR_BUILD > 0 ? CUR_BUILD : 1))"
else
  NEXT_BUILD=$((CUR_BUILD + 1))
fi
echo "==> Build number: $CUR_BUILD -> $NEXT_BUILD"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [ ${#BINS[@]} -eq 1 ]; then
  cp "${BINS[0]}" "$APP/Contents/MacOS/PkgViewer"
else
  # lipo, not lipo_thick: one thin slice per arch, which is what a universal
  # binary is. Verified afterwards so a silent single-arch result cannot ship.
  lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/PkgViewer"
  echo "    architectures: $(lipo -archs "$APP/Contents/MacOS/PkgViewer")"
fi

# The resource bundle is architecture-independent, so any build dir will do.
BIN_DIR="$BUILD_DIR/$([ "$HOST_ARCH" = "x86_64" ] && echo x86_64 || echo arm64)/$CONFIG"

# SwiftPM emits a resource bundle next to the binary; ship it inside the app.
# It carries the compiled <lang>.lproj directories.
BUNDLE="$BIN_DIR/PkgViewerMac_PkgViewerMac.bundle"
if [ ! -d "$BUNDLE" ]; then
  for bp in $BUILD_DIR/*/"$CONFIG"; do
    [ -d "$bp/PkgViewerMac_PkgViewerMac.bundle" ] && BUNDLE="$bp/PkgViewerMac_PkgViewerMac.bundle" && break
  done
fi
if [ -d "$BUNDLE" ]; then
  cp -R "$BUNDLE" "$APP/Contents/Resources/"
  LOCALES=$(find "$BUNDLE" -name '*.lproj' -type d -exec basename {} .lproj \; 2>/dev/null | sort | tr '\n' ' ')
  echo "    localisations: ${LOCALES:-none}"
fi

cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>                  <string>PKG Viewer</string>
  <key>CFBundleDisplayName</key>           <string>PKG Viewer</string>
  <key>CFBundleExecutable</key>            <string>PkgViewer</string>
  <key>CFBundleIdentifier</key>            <string>com.local.pkgviewermac</string>
  <key>CFBundleVersion</key>               <string>$NEXT_BUILD</string>
  <key>CFBundleShortVersionString</key>    <string>1.1</string>
  <key>CFBundlePackageType</key>           <string>APPL</string>
  <key>CFBundleIconFile</key>              <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>        <string>12.0</string>
  <key>NSHighResolutionCapable</key>       <true/>
  <key>NSHumanReadableCopyright</key>      <string>Original pkg-viewer by Loopayeh (MIT) · macOS port by CarlChina</string>
  <key>CFBundleDevelopmentRegion</key>     <string>en</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>en</string>
    <string>zh-Hans</string>
    <string>zh-Hant</string>
    <string>ja</string>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>PlayStation Package</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Owner</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>com.loopayeh.pkgviewer.pkg</string>
        <string>com.loopayeh.pkgviewer.exfat</string>
        <string>com.loopayeh.pkgviewer.ffpfsc</string>
        <string>com.loopayeh.pkgviewer.ffpkg</string>
      </array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Folder</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>None</string>
      <key>LSItemContentTypes</key><array><string>public.folder</string></array>
    </dict>
  </array>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>com.loopayeh.pkgviewer.pkg</string>
      <key>UTTypeDescription</key><string>PlayStation Package</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string></array>
      <key>UTTypeTagSpecification</key>
      <dict><key>public.filename-extension</key><array><string>pkg</string></array></dict>
    </dict>
    <dict>
      <key>UTTypeIdentifier</key><string>com.loopayeh.pkgviewer.exfat</string>
      <key>UTTypeDescription</key><string>PS5 exFAT Disk Image</string>
      <key>UTTypeConformsTo</key><array><string>public.disk-image</string></array>
      <key>UTTypeTagSpecification</key>
      <dict><key>public.filename-extension</key><array><string>exfat</string></array></dict>
    </dict>
    <dict>
      <key>UTTypeIdentifier</key><string>com.loopayeh.pkgviewer.ffpfsc</string>
      <key>UTTypeDescription</key><string>PS5 Compressed PFS Image</string>
      <key>UTTypeConformsTo</key><array><string>public.disk-image</string></array>
      <key>UTTypeTagSpecification</key>
      <dict><key>public.filename-extension</key><array><string>ffpfsc</string></array></dict>
    </dict>
    <dict>
      <key>UTTypeIdentifier</key><string>com.loopayeh.pkgviewer.ffpkg</string>
      <key>UTTypeDescription</key><string>PS5 UFS2 Disk Image</string>
      <key>UTTypeConformsTo</key><array><string>public.disk-image</string></array>
      <key>UTTypeTagSpecification</key>
      <dict><key>public.filename-extension</key><array><string>ffpkg</string></array></dict>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Fail loudly if the binary does not cover the requested architectures.
# A silent single-arch result is the failure mode worth guarding: the build
# would otherwise succeed and ship something that cannot start on half the
# Macs it claims to support.
GOT="$(lipo -archs "$APP/Contents/MacOS/PkgViewer" 2>/dev/null | tr ' ' '\n' | sort | tr '\n' ' ')"
WANT="$(printf '%s\n' $ARCH_LIST | sort | tr '\n' ' ')"
if [ "$GOT" != "$WANT" ]; then
  echo "error: architecture mismatch — wanted [$WANT], got [$GOT]" >&2
  exit 1
fi
echo "==> Verified architectures: $GOT"

# Ad-hoc signature so Gatekeeper lets a locally built app run.
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "   (codesign skipped)"

echo "==> Built $APP"
du -sh "$APP"
