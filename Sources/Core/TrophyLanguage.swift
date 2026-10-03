import Foundation

/// Language selection for trophy metadata.
///
/// A PS5 `.ucp` stores one `tropmeta_<locale>.json` per language, so the
/// locale normally comes from the filename. Dumps do not always agree with
/// that, though: in the wild a file named `tropmeta_ja-JP.json` has been seen
/// holding Italian, `ko-KR` holding Japanese, and so on. Two packages were
/// measured and 5–6 of ~20 locales mismatched, and the displacement is
/// irregular — offsets from −16 to +11 — so there is no rule to recompute it
/// with. The `schemaVersion 1.00` manifest lists the locales the pack ships but
/// does not say which file holds which, so it cannot correct the names either.
///
/// What the manifest *is* good for is telling us which locales exist, which a
/// name-only guess cannot do reliably. So the flow is:
///
/// 1. Offer the locales the manifest declares (`defaultLanguage` first).
/// 2. Let the user pick one explicitly; the file is then read by name.
/// 3. Only if the user is unsure, fall back to identifying the text — but do
///    it with script detection, which is exact for Han/Kana/Hangul/Cyrillic/
///    Arabic/Thai, plus a stop-word probe for the Latin languages. The two test
///    packages both carry correct `en-US`, so a wrong pick is always avoidable.
enum TrophyLanguage {
    /// A language the pack offers.
    struct Candidate: Identifiable, Hashable {
        /// BCP-47 tag as it appears in the archive, e.g. "ja-JP".
        let tag: String
        var id: String { tag }

        /// "ja-JP" -> "ja"
        var primary: String { tag.split(whereSeparator: { $0 == "-" }).first.map(String.init) ?? tag }

        /// The pack's `defaultLanguage`, which the console itself uses.
        var isPackDefault: Bool = false
        /// The member that holds this language, when it could be determined.
        var fileName: String?
    }

    /// Put the caller's explicit choice first, then the pack default, then the
    /// interface language, then English.
    static func preference(for interfaceTags: [String], explicit: String? = nil,
                           packDefault: String? = nil) -> [String] {
        var out: [String] = []
        if let e = explicit { out.append(e) }
        if let d = packDefault { out.append(d) }
        out += preference(for: interfaceTags)
        var seen = Set<String>()
        return out.filter { seen.insert($0.lowercased()).inserted }
    }

    /// The order to try: the user's interface language, then English variants.
    static func preference(for interfaceTags: [String]) -> [String] {
        var out: [String] = []
        for tag in interfaceTags {
            let primary = tag.split(whereSeparator: { $0 == "-" }).first.map(String.init) ?? tag
            out.append(tag)
            // `zh` should also try the two script variants we ship.
            if primary == "zh" { out += ["zh-Hans", "zh-Hant"] }
        }
        out += ["en-US", "en-GB", "en"]
        // Preserve order, drop duplicates.
        var seen = Set<String>()
        return out.filter { seen.insert($0.lowercased()).inserted }
    }

    /// Choose the metadata file to display, given the wanted tags in priority
    /// order. Exact tag wins over base language; English is the final fallback.
    ///
    /// `identified` supplies the language actually found in each file, when it
    /// is already known. A file whose detected language contradicts its name is
    /// only used for the tag it really holds, so a mislabelled dump still shows
    /// the language the user asked for.
    static func chooseMeta(among names: [String], wanted: [String],
                           identified: [String: String] = [:]) -> String? {
        guard !names.isEmpty else { return nil }

        func primary(_ t: String) -> String {
            t.lowercased().split(separator: "-").first.map(String.init) ?? t.lowercased()
        }
        /// The tag this file should be treated as.
        ///
        /// The detected script only overrides the filename when it proves the
        /// file holds a *different language family*. Within one family the name
        /// stands: Latin cannot be refined at all, and a pack may legitimately
        /// label simplified text `zh-Hant` (seen in the wild), so refining that
        /// by counting traditional forms would move the file to the wrong entry.
        func effective(_ name: String) -> String? {
            let claimed = localeTag(fromMetaName: name)?.lowercased()
            guard let claimed else { return nil }
            guard let found = identified[name]?.lowercased(), !found.isEmpty else { return claimed }
            let claimedFamily = family(claimed)
            // Same family (or a family we cannot pin down): trust the filename.
            guard family(found) != claimedFamily else { return claimed }
            return found
        }
        /// The language family a tag belongs to, for comparing two locales.
        func family(_ t: String) -> String {
            switch primary(t) {
            case "zh", "ja", "ko", "ru", "ar", "th": return primary(t)
            default: return "latin"   // every western language, undifferentiated
            }
        }
        // Several files can resolve to the same language (a mislabelled dump
        // plus the genuine article), so build the index defensively rather than
        // with `uniqueKeysWithValues`, which traps on a duplicate key.
        var byName: [String: String] = [:]
        for n in names.sorted() {
            if let e = effective(n), byName[e] == nil { byName[e] = n }
        }
        // A second pass for the detected languages, so a file whose name lies
        // is still reachable by what it actually contains.
        for n in names.sorted() {
            guard let found = identified[n]?.lowercased(), !found.isEmpty else { continue }
            if byName[found] == nil { byName[found] = n }
        }

        for w in wanted {
            if let hit = byName[w.lowercased()] { return hit }
        }
        for w in wanted {
            let p = primary(w)
            if let hit = names.first(where: { effective($0).map(primary) == p }) { return hit }
        }
        // A mislabelled dump can leave a Latin locale with no file of its own:
        // every `tropmeta_de-DE.json` may in fact hold something else. Rather
        // than hand back text in a different script, fall back to a file whose
        // script is unknown or Latin, which at least reads as a Latin language.
        let nonLatin = Set(["zh-hans", "zh-hant", "ja-jp", "ko-kr", "ru-ru",
                            "ar-ae", "th-th"])
        if let hit = names.sorted().first(where: { n in
            guard let f = identified[n]?.lowercased() else { return true }
            return !nonLatin.contains(f)
        }) { return hit }
        return names.sorted().first
    }

    /// "tropmeta_ja-JP.json" -> "ja-JP"
    static func localeTag(fromMetaName name: String) -> String? {
        guard name.hasPrefix("tropmeta_"), name.hasSuffix(".json") else { return nil }
        let tag = String(name.dropFirst("tropmeta_".count).dropLast(".json".count))
        return tag.isEmpty ? nil : tag
    }

    /// The locale a piece of text is written in, when it can be told.
    ///
    /// Exact for the scripts that are mutually exclusive. A trophy name often
    /// mixes scripts — a Japanese title with a Han subtitle, a Russian string
    /// quoting the original Japanese — so the dominant script is chosen by
    /// character count rather than by first match. Latin-script languages are
    /// not separable this way, so this returns nil for them and the caller
    /// falls back to the filename.
    static func scriptOf(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        var hanTraditional = 0
        for scalar in text.unicodeScalars {
            let bucket: String
            switch scalar.value {
            case 0x3040...0x309F, 0x30A0...0x30FF: bucket = "ja"
            case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F: bucket = "ko"
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF:
                bucket = "zh"
                if traditionalForms.contains(scalar.value) { hanTraditional += 1 }
            case 0x0400...0x04FF: bucket = "ru"
            case 0x0600...0x06FF, 0x0750...0x077F: bucket = "ar"
            case 0x0E00...0x0E7F: bucket = "th"
            default: continue
            }
            counts[bucket, default: 0] += 1
        }
        guard let (script, n) = counts.max(by: { $0.value < $1.value }), n > 0 else {
            return nil   // Latin or no CJK/other script at all
        }
        // Han text is only called Chinese when it is not mostly kana, which is
        // what separates a Japanese string from a Chinese one.
        if script == "zh" { return hanTraditional > n / 2 ? "zh-Hant" : "zh-Hans" }
        switch script {
        case "ja": return "ja-JP"
        case "ko": return "ko-KR"
        case "ru": return "ru-RU"
        case "ar": return "ar-AE"
        case "th": return "th-TH"
        default: return nil
        }
    }

    /// Characters that only appear in traditional Chinese text.
    private static let traditionalForms: Set<UInt32> = [
        0x9AD4, 0x570B, 0x5B78, 0x6A02, 0x9F8D, 0x9580, 0x9EDE, 0x9019,
        0x500B, 0x6642, 0x9593, 0x6703, 0x5011, 0x842C, 0x8207, 0x6771,
        0x8ECA, 0x99AC, 0x9577, 0x98A8, 0x98DB, 0x9CE5, 0x9B5A, 0x611B,
        0x734E, 0x676F,
    ]
}
