// swift-tools-version:6.0
import PackageDescription

// Note: the default MacOSX.sdk in Command Line Tools ships no macro plugins
// at all — no PreviewsMacros, no SwiftUIMacros — and neither does any SDK in
// /Library/Developer. The macOS 27 SDK cannot compile a single `@State`: its
// SwiftUICore interface declares `#externalMacro(module: "SwiftUIMacros", …)`
// references that no CLT can expand, so every property wrapper fails. A 26.x
// SDK compiles clean. See build.sh for the full note.
let package = Package(
    name: "PkgViewerMac",
    // Marks en as the base language; UI strings live in
    // Sources/Resources/<lang>.lproj/Localizable.strings.
    defaultLocalization: "en",
    platforms: [.macOS(.v12)],
    targets: [
        // Thin wrapper over the system libz (zlib) — the Apple Compression
        // framework's COMPRESSION_ZLIB is broken in the 26.x SDK and only
        // emits a ~1:1 partial inflate, so PFSC blocks must go through libz
        // directly.
        .target(name: "CZlib", path: "CZlib", publicHeadersPath: "include"),
        .executableTarget(
            name: "PkgViewerMac",
            dependencies: ["CZlib"],
            path: "Sources",
            exclude: ["Core/ucp_extract.py"],
            // .process (not .copy) so SwiftPM compiles the .lproj directories
            // into localized resources inside the bundle.
            resources: [.process("Resources"), .copy("../Resources/AppIcon.icns")]
        )
    ]
)
