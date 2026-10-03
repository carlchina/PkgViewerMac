import Foundation

/// Dumps the resolved UI strings for a given language so the translations can
/// be eyeballed without launching the app:
///     PkgViewer --lang-check [code]
@MainActor
struct LangCheck {
    /// Inspect the current localisation state. `code` pins a language first;
    /// without it, whatever is already stored (or the system) is used.
    static func run(_ code: String?) {
        if let code {
            UserDefaults.standard.set(code == "system" ? nil : code, forKey: L10n.storageKey)
        }
        let l = L10n()
        print("system    : \(L10n.preferredLanguages().joined(separator: ", "))")
        print("resolved  : \(l.languageCode)  (\(l.current.nativeName))")
        print("follows system: \(l.followsSystem)")
        print("bundle lproj  : \(l.bundlePathForDebug)")
        print("available : \(L10n.available.map(\.code).joined(separator: ", "))")
        print("")

        // A representative sample across every tab.
        let keys = [
            "app.name", "app.open", "app.rename", "app.copyInfo",
            "app.screenshot", "app.screenshotHelp", "alert.ok",
            "tab.overview", "tab.files", "tab.trophies", "tab.details",
            "drop.title", "drop.formats", "drop.blurb",
            "loading.reading", "error.title", "error.chooseAnother",
            "overview.save", "overview.copy", "overview.noCover", "overview.spec",
            "files.filter", "files.noMatch", "files.selectOne",
            "detail.name", "detail.size", "detail.trophyPack",
            "trophy.export.saveOne", "trophy.export.all", "trophy.none",
            "shot.saveMessage", "shot.savePrompt", "shot.failed", "shot.saveFailed",
            "trophy.grade.platinum", "trophy.grade.gold", "trophy.grade.unknown",
            "details.showAll", "details.filterKeys", "details.none",
            "rename.title", "rename.include", "rename.preview",
            "rename.part.title", "rename.part.version", "rename.part.region",
            "rename.cancel", "rename.confirm", "rename.custom",
            "lang.menu", "lang.follow",
        ]
        var missing: [String] = []
        for k in keys {
            let v = l.t(k)
            if v == k { missing.append(k) }
            print(String(format: "  %-26@ %@", k as NSString, v as NSString))
        }
        if !missing.isEmpty {
            print("\nMISSING KEYS: \(missing.joined(separator: ", "))")
        } else {
            print("\nall sampled keys resolved")
        }
    }
}
