import Foundation
import SwiftUI

/// Runtime localisation for the UI.
///
/// Strings live in `Sources/Resources/<lang>.lproj/Localizable.strings`, the
/// standard macOS layout, so they stay editable by translators and can be
/// extracted by `genstrings` / Xcode.
///
/// Two things this adds over plain `String(localized:)`:
///  - a **language picker**, so the interface language can be changed without
///    touching System Settings (macOS has no per-app language override);
///  - **system-language detection with sensible fallbacks**, e.g. `zh-Hant-TW`
///    resolves to Chinese Traditional rather than falling all the way back to
///    English.
@MainActor
final class L10n: ObservableObject {
    /// A language the app ships strings for.
    struct Language: Identifiable, Hashable {
        let code: String          // BCP-47, e.g. "zh-Hans"
        let englishName: String
        let nativeName: String

        var id: String { code }

        static let all: [Language] = [
            .init(code: "en",         englishName: "English",    nativeName: "English"),
            .init(code: "zh-Hans",    englishName: "Chinese (Simplified)", nativeName: "简体中文"),
            .init(code: "zh-Hant",    englishName: "Chinese (Traditional)", nativeName: "繁體中文"),
            .init(code: "ja",         englishName: "Japanese",    nativeName: "日本語"),
        ]
    }

    /// Stored choice; `nil` means "follow the system language".
    static let storageKey = "pkgviewer.language"

    @Published private(set) var languageCode: String
    private var overrideBundle: Bundle?

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.storageKey)
        if let stored, Self.language(for: stored) != nil {
            languageCode = stored
        } else {
            languageCode = Self.systemLanguage()
        }
        loadBundle()
    }

    // MARK: - Selection

    /// The languages the app actually has strings for, ordered as declared.
    @MainActor static var available: [Language] { Language.all }

    var current: Language {
        Self.language(for: languageCode) ?? Language.all[0]
    }

    /// True when the UI is following the system rather than a pinned choice.
    var followsSystem: Bool {
        UserDefaults.standard.string(forKey: Self.storageKey) == nil
    }

    /// Pin a language, or pass `nil` to follow the system again.
    func select(_ code: String?) {
        if let code, Self.language(for: code) != nil {
            UserDefaults.standard.set(code, forKey: Self.storageKey)
            languageCode = code
        } else {
            UserDefaults.standard.removeObject(forKey: Self.storageKey)
            languageCode = Self.systemLanguage()
        }
        loadBundle()
    }

    /// Best shipped language for a BCP-47 tag, or nil.
    @MainActor static func language(for code: String) -> Language? {
        let exact = Language.all.first { $0.code == code }
        if let exact { return exact }
        // Fall back on the primary subtag: "zh-Hant-TW" -> "zh-Hant".
        let primary = code.split(whereSeparator: { $0 == "-" }).first.map(String.init) ?? code
        return Language.all.first { $0.code == primary }
            ?? Language.all.first { $0.code.split(separator: "-").first.map(String.init) == primary }
    }

    /// Resolve the system language list against what we ship.
    @MainActor static func systemLanguage() -> String {
        for tag in preferredLanguages() {
            if let l = language(for: tag) { return l.code }
        }
        return "en"
    }

    /// The user's ordered language preferences as BCP-47 tags.
    ///
    /// `Locale.preferredLanguages` is the long-standing API and still the one
    /// that reflects System Settings ▸ General ▸ Language & Region, including
    /// the per-app "Language" override when the user has set one in Finder's
    /// Get Info ▸ Language. It is unavailable in some SDK slices, so fall back
    /// to the current locale's identifier.
    static func preferredLanguages() -> [String] {
        if !Locale.preferredLanguages.isEmpty { return Locale.preferredLanguages }
        return [Locale.current.identifier]
    }

    /// Locale tags for content that follows the interface language (trophy
    /// names, for example). A pinned language wins over the system list.
    /// The pinned code, if the user chose one in the Language menu.
    var pinnedCode: String? { UserDefaults.standard.string(forKey: Self.storageKey) }

    var effectiveLanguageTags: [String] {
        if UserDefaults.standard.string(forKey: Self.storageKey) == nil {
            return Self.preferredLanguages()
        }
        return [languageCode] + Self.preferredLanguages()
    }

    // MARK: - Bundle

    private func loadBundle() {
        // Always pin the bundle explicitly, including for English: `Bundle.module`
        // resolves against the user's preferred language, so a user whose
        // system is Chinese but who picks English here would otherwise still
        // get Chinese strings.
        if let path = Bundle.module.path(forResource: languageCode, ofType: "lproj"),
           let b = Bundle(path: path) {
            overrideBundle = b
        } else {
            overrideBundle = nil
        }
    }

    private var bundle: Bundle {
        overrideBundle ?? .module
    }

    /// Path of the bundle strings are read from — exposed for `--lang-check`.
    var bundlePathForDebug: String {
        (overrideBundle ?? .module).bundlePath
    }

    // MARK: - Lookup

    /// Look up a key, falling back to the key itself so a missing string is
    /// obvious rather than silently blank.
    func t(_ key: String) -> String {
        let s = bundle.localizedString(forKey: key, value: key, table: nil)
        return s
    }

    /// Look up a key and substitute `%@`/`%lld` style arguments.
    func t(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), arguments: args)
    }
}

// MARK: - SwiftUI plumbing

/// Injectable so a language change repaints every view.
extension View {
    func localized(_ l10n: L10n) -> some View {
        environmentObject(l10n)
    }
}
