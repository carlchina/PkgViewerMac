#!/usr/bin/env bash
# Build PkgViewerMac.app from source.
#
# Uses the MacOSX26.5 SDK by default: the MacOSX.sdk symlink in Command Line
# Tools only ships arm64e SwiftUI modules, which require the SwiftUIMacros
# plugin that CLT does not install. Override with SDK=/path/to/SDK.
set -euo pipefail

cd "$(dirname "$0")"

SDK="${SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
if [ ! -d "$SDK" ]; then
  # Fall back to any SDK that still has plain arm64 SwiftUI modules.
  for c in /Library/Developer/CommandLineTools/SDKs/MacOSX2*.sdk; do
    if [ -d "$c/System/Library/Frameworks/SwiftUI.framework/Modules/SwiftUI.swiftmodule" ]; then
      SDK="$c"; break
    fi
  done
fi
echo "==> SDK: $SDK"

CONFIG="${CONFIG:-release}"
echo "==> Building ($CONFIG)…"
# SwiftPM's manifest step spawns its own sandbox, which fails when this
# script already runs inside one. `defaultLocalization` in Package.swift also
# makes the manifest stricter, so pass --disable-sandbox by default and allow
# opting out via SWIFT_SANDBOX=1.
if [ "${SWIFT_SANDBOX:-0}" = "1" ]; then
  SWIFT=(swift build -c "$CONFIG" --sdk "$SDK")
else
  SWIFT=(swift build --disable-sandbox -c "$CONFIG" --sdk "$SDK")
fi

"${SWIFT[@]}"

BIN_DIR="$("${SWIFT[@]}" --show-bin-path)"
BIN="$BIN_DIR/PkgViewerMac"
APP="build/PkgViewer.app"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PkgViewer"

# SwiftPM emits a resource bundle next to the binary; ship it inside the app.
# It carries the compiled <lang>.lproj directories.
BUNDLE="$BIN_DIR/PkgViewerMac_PkgViewerMac.bundle"
if [ -d "$BUNDLE" ]; then
  cp -R "$BUNDLE" "$APP/Contents/Resources/"
  LOCALES=$(find "$BUNDLE" -name '*.lproj' -type d -exec basename {} .lproj \; 2>/dev/null | sort | tr '\n' ' ')
  echo "    localisations: ${LOCALES:-none}"
fi

cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>                  <string>PKG Viewer</string>
  <key>CFBundleDisplayName</key>           <string>PKG Viewer</string>
  <key>CFBundleExecutable</key>            <string>PkgViewer</string>
  <key>CFBundleIdentifier</key>            <string>com.local.pkgviewermac</string>
  <key>CFBundleVersion</key>               <string>1</string>
  <key>CFBundleShortVersionString</key>    <string>1.0</string>
  <key>CFBundlePackageType</key>           <string>APPL</string>
  <key>CFBundleIconFile</key>              <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>        <string>14.0</string>
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

# Ad-hoc signature so Gatekeeper lets a locally built app run.
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "   (codesign skipped)"

echo "==> Built $APP"
du -sh "$APP"
