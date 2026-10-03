import Foundation

/// A user-facing message identified by a localisation key plus format
/// arguments.
///
/// The parsers live in `Core` and have no access to SwiftUI, so they emit a
/// `Message` instead of a finished string; the UI resolves it through `L10n`
/// at render time. That keeps every visible string in the `.strings` files.
struct Message {
    let key: String
    let args: [CVarArg]

    /// The `en.lproj` bundle, used for CLI output and logs.
    static let englishBundle: Bundle = {
        if let p = Bundle.module.path(forResource: "en", ofType: "lproj"),
           let b = Bundle(path: p) {
            return b
        }
        return Bundle.module
    }()

    init(_ key: String, _ args: CVarArg...) {
        self.key = key
        self.args = args
    }

    /// Resolve against a translator. A key with no matching string falls back
    /// to the key itself so the gap is visible rather than silent.
    func text(_ t: (String) -> String) -> String {
        let format = t(key)
        guard !args.isEmpty else { return format }
        return String(format: format, arguments: args)
    }

    /// Resolve against the base (English) bundle, for CLI output and logs.
    ///
    /// `Bundle.module` resolves against the user's preferred language, so pin
    /// the `en` sub-bundle to keep CLI diagnostics in English regardless of the
    /// system setting — `verify.sh` diffs these strings against the Python
    /// original.
    func english() -> String {
        text { Self.englishBundle.localizedString(forKey: $0, value: $0, table: nil) }
    }
}
