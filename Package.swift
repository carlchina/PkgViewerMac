// swift-tools-version:6.0
import PackageDescription

// Note: the default MacOSX.sdk in Command Line Tools only ships arm64e
// SwiftUI modules, which drag in the SwiftUIMacros plugin that CLT does not
// ship. Pinning an SDK that still has the plain arm64 modules lets the app
// build without a full Xcode install. See build.sh.
let package = Package(
    name: "PkgViewerMac",
    // Marks en as the base language; UI strings live in
    // Sources/Resources/<lang>.lproj/Localizable.strings.
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PkgViewerMac",
            path: "Sources",
            // .process (not .copy) so SwiftPM compiles the .lproj directories
            // into localized resources inside the bundle.
            resources: [.process("Resources"), .copy("../Resources/AppIcon.icns")]
        )
    ]
)
