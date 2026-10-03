import Foundation

/// Single source of truth for the app version.
///
/// Read from `Info.plist` at runtime rather than hard-coded, so the number in
/// the About window, the toolbar and the bundle can never drift apart.
enum AppInfo {
    /// Marketing version, e.g. "1.0".
    static let version: String = {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return (v?.isEmpty == false) ? v! : "1.0"
    }()

    /// Build number, shown only when it adds information over `version`.
    static let build: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }()

    /// `1.0 (123)` when the build differs from the version, else `1.0`.
    static var versionWithBuild: String {
        build.isEmpty || build == version ? version : "\(version) (\(build))"
    }

    static let name = "PKG Viewer"
}
