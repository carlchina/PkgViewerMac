import Foundation
import SwiftUI
import AppKit

/// Bridges the synchronous parsers onto a background queue and owns the live
/// file handle needed to read entries out of the opened container.
@MainActor
final class PkgViewModel: ObservableObject {
    @Published var result: PkgResult?
    @Published var isLoading = false
    /// Localised failure text, resolved from `result.failed` for display.
    @Published var errorText: Message?
    @Published var coverImages: [(name: String, data: Data)] = []
    /// Bumped on every `open`, so views can tell "a different package" from
    /// "the same one reloaded" — `result.path` alone cannot, and any per-package
    /// view state (a picked cover, a scroll offset) must reset either way.
    @Published private(set) var loadGeneration: Int = 0
    @Published var selectedTab: Tab = .overview
    @Published var searchText = ""
    @Published var fileFilter = ""

    /// Open handle for the current container (PKG / exFAT), kept so entry
    /// bytes can be read on demand without reopening the file.
    private var reader: FileHandleReader?
    private var exfat: ExfatImage?

    enum Tab: String, CaseIterable, Identifiable {
        case overview, files, trophies, details
        var id: String { rawValue }
        /// Localisation key for the tab's title.
        var titleKey: String { "tab.\(rawValue)" }
    }

    var history: [URL] = []
    private let historyKey = "pkgviewer.history"

    // MARK: Loading

    /// Everything a background parse produces, handed back to the main actor
    /// as plain values plus the open handles needed for later entry reads.
    private struct Loaded {
        let result: PkgResult
        let covers: [(name: String, data: Data)]
        let reader: FileHandleReader?
        let exfat: ExfatImage?
    }

    func open(_ url: URL) {
        isLoading = true
        errorText = nil
        coverImages = []
        loadGeneration += 1
        selectedTab = .overview
        searchText = ""
        fileFilter = ""
        trophyLoaded = false
        trophies = []
        trophyIcons = []
        trophyLocale = nil
        trophyLocales = []
        trophyIconMap = [:]
        trophyStatus = nil

        Task.detached(priority: .userInitiated) { [weak self] in
            // Nothing actor-isolated is touched here: parse, open handles and
            // pull covers entirely off the main thread.
            let res = PkgLoader.load(url: url)
            // The handle must point at what was actually parsed, not at what
            // was dropped: an exFAT wrapper is a directory, and a PS3 package
            // inside it is the real file. `res.path` is that file, so cover art
            // and entry reads (which decrypt through the handle) work.
            let handle = FileHandleReader(url: res.path)
            var ex: ExfatImage?
            if let handle = handle, res.kind != "unknown" {
                ex = try? ExfatImage(reader: handle)
            }
            let covers = PkgLoader.extractCovers(res, reader: handle, exfat: ex)
            let loaded = Loaded(result: res, covers: covers, reader: handle, exfat: ex)

            await MainActor.run {
                guard let self = self else {
                    handle?.close()
                    return
                }
                self.adopt(loaded, url: url)
            }
        }
    }


    private func adopt(_ loaded: Loaded, url: URL) {
        reader?.close()
        reader = loaded.reader
        exfat = loaded.exfat
        result = loaded.result
        coverImages = loaded.covers
        isLoading = false
        if let f = loaded.result.failed { errorText = f }
        pushHistory(url)
    }

    func openMany(_ urls: [URL]) {
        guard let first = urls.first else { return }
        open(first)
    }

    // MARK: Entry reading


    /// Bytes of an entry, reading through whichever backing store it has.
    func read(_ entry: PkgEntry) -> Data? {
        switch entry.source {
        case .exfat:
            guard let ex = exfat else { return nil }
            return PkgLoader.readExfatEntry(entry, fs: ex)
        default:
            return PkgLoader.readEntry(entry, reader: reader)
        }
    }

    // MARK: Trophies

    @Published var trophies: [Trophy] = []
    @Published var trophyIcons: [Data] = []
    /// Trophy id -> icon, so a selected row can show its own art.
    @Published var trophyIconMap: [String: Data] = [:]
    @Published var trophyStatus: Message?
    /// NPCommID reported by the pack (UCP carries it in tropmeta).
    @Published var trophyNpCommId: String = ""
    @Published var trophyTitle: String = ""
    /// Locale of the trophy text, e.g. "ja-JP".
    @Published var trophyLocale: String?
    /// Locales the pack offers, for a manual override.
    @Published var trophyLocales: [TrophyLanguage.Candidate] = []
    /// User's pick from `trophyLocales`; nil means follow the pack default
    /// and then the interface language.
    @Published var trophyLocaleOverride: String?
    /// The pack's own `defaultLanguage`, shown in the language menu.
    @Published var trophyPackDefault: String?

    private var trophyLoaded = false
    /// The pack the current trophies came from, kept so the language can be
    /// re-read without re-parsing the container.
    private var trophyPack: (entry: PkgEntry, name: String, npcommid: String)?

    /// Re-read the trophy metadata in a different language.
    ///
    /// Only `.ucp` packs carry per-language files; a `.trp` has one encrypted
    /// list, so the menu is not offered for those in the first place.
    func reloadTrophies() {
        guard let pack = trophyPack else { return }
        guard let data = read(pack.entry), !data.isEmpty else {
            trophyStatus = Message("trophy.msg.unreadable", pack.name)
            return
        }
        trophies = []
        trophyIcons = []
        trophyIconMap = [:]
        trophyStatus = nil
        if pack.entry.name.lowercased().hasSuffix(".ucp") {
            loadUCP(data, name: pack.name, fallbackNpcommid: pack.npcommid)
        } else {
            loadTRP(data, name: pack.name, fallbackNpcommid: pack.npcommid)
        }
    }

    /// Pick the real trophy pack from the candidates.
    ///
    /// A PS5 dump ships both `trophy2/trophy00.ucp` (trophies) and
    /// `uds/uds00.ucp` (user data), so prefer an actual trophy pack and rank
    /// `trophy2/` above the PS4-era `sce_sys/trophy/`.
    private static func bestPack(_ packs: [PkgEntry]) -> PkgEntry? {
        let real = packs.filter { e in
            let n = e.name.lowercased()
            return n.contains("trophy") && !n.hasPrefix("uds")
        }
        let pool = real.isEmpty ? packs : real
        return pool.max { a, b in
            score(a.name) < score(b.name)
        }
    }

    private static func score(_ name: String) -> Int {
        let n = name.lowercased()
        if n.contains("trophy2") || n.contains("trophy00") { return 3 }
        if n.contains("trophy") { return 2 }
        if n.hasSuffix(".trp") { return 1 }
        return 0
    }

















    func loadTrophiesIfNeeded() {
        guard !trophyLoaded else { return }
        trophyLoaded = true
        guard let res = result else { return }
        let packs = res.entries.filter { $0.isTrophyPack }
        guard let entry = Self.bestPack(packs) else {
            trophyStatus = Message("trophy.msg.none")
            return
        }
        trophyStatus = Message("trophy.msg.reading", entry.name)
        let npcommid = Self.npcommid(from: res)
        Task(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            // Reading uses the already-open handles, so stay on this actor.
            guard let data = self.read(entry), !data.isEmpty else {
                self.trophyStatus = Message("trophy.msg.unreadable", entry.name)
                return
            }
            let lower = entry.name.lowercased()
            if lower.hasSuffix(".ucp") {
                self.trophyPack = (entry, entry.name, npcommid)
                self.loadUCP(data, name: entry.name, fallbackNpcommid: npcommid)
            } else {
                self.loadTRP(data, name: entry.name, fallbackNpcommid: npcommid)
            }
        }
    }

    /// PS5 `.ucp` archive: metadata and icons are plaintext, no decryption.
    /// Interface-language tags the trophies should follow.
    var l10nTags: [String] = Locale.preferredLanguages

    private func loadUCP(_ data: Data, name: String, fallbackNpcommid: String) {
        // Priority: the user's pick, then the pack's own default (what the
        // console would show), then the interface language, then English.
        // The override must go through `explicit:` — passing it as part of
        // `for:` would let `packDefault` jump ahead of it, and the Language
        // menu would silently have no effect.
        let packDefault = UCP.packDefaultLanguage(data)
        trophyPackDefault = packDefault
        let wanted = TrophyLanguage.preference(
            for: l10nTags, explicit: trophyLocaleOverride, packDefault: packDefault)
        let c = UCP.read(data, wanted: wanted)
        trophyLocales = UCP.availableLocales(data)
        trophyLocale = c.localeTag
        trophies = c.trophies
        trophyIconMap = UCP.displayIconMap(c.icons)
        trophyIcons = Array(trophyIconMap.values)
        trophyNpCommId = c.npcommid.isEmpty ? fallbackNpcommid : c.npcommid
        trophyTitle = c.title

        if c.trophies.isEmpty {
            let members = UCP.parse(data).count
            trophyStatus = members == 0
                ? Message("trophy.msg.badUCP", name)
                : Message("trophy.msg.noTropmeta", name, members)
        } else {
            trophyStatus = nil
        }
    }

    /// PS4/older-PS5 `.trp` archive: the trophy list lives in an ESFM blob
    /// encrypted per title, so a matching NPcommID is required.
    private func loadTRP(_ data: Data, name: String, fallbackNpcommid: String) {
        let files = TRP.parse(data)
        // Icons: prefer the entry table's `TROPnnn.PNG`, which names the trophy
        // it belongs to. Falling back to carving is only needed for archives
        // that do not list them — and carving can then only pair by position.
        let listed = trpIconsById(files, in: data)
        let carved = PNGCarve.carve(data).prefix(60).map {
            (data: data.subdata(in: $0.offset..<($0.offset + $0.size)),
             width: $0.width, height: $0.height)
        }
        // Show the art straight away; the list arrives when the search finishes.
        trophyIcons = listed.values.isEmpty ? carved.map(\.data) : Array(listed.values)
        trophyIconMap = listed

        // Per-language text blobs (`TROP_NN.SFM`) and the configuration member.
        let textEntries = TRP.textEntries(files)
        let nameBlobs = textEntries.compactMap { f in
            f.offset >= 0 && f.size > 0 && f.offset + f.size <= data.count
                ? data.subdata(in: f.offset..<(f.offset + f.size)) : nil
        }

        guard let sfm = TRP.metadataEntry(files), sfm.size > 0,
              sfm.offset >= 0, sfm.offset + sfm.size <= data.count else {
            trophyStatus = files.isEmpty
                ? Message("trophy.msg.badTRP", name)
                : Message("trophy.msg.noESFM", name)
            return
        }

        let blob = data.subdata(in: sfm.offset..<(sfm.offset + sfm.size))

        // PS3 stores the members as plain XML — no per-title AES at all. Try
        // that before anything else: it is both exact and instant, whereas the
        // key search below is a bounded brute force.
        //
        // Prefer a blob that actually carries names. `TROPCONF.SFM` holds only
        // the configuration (id/ttype/hidden) and would yield 38 nameless rows;
        // `TROP.SFM` repeats the same ids with <name>/<detail> for each, and
        // `TROP_NN.SFM` carries further languages.
        if let plain = ESFM.plainXML(blob) {
            let all = ([plain] + nameBlobs.compactMap { ESFM.plainXML($0) })
            // The richest blob wins: most named entries, then the largest.
            let best = all.max { a, b in
                let na = TrophyXML.parse(a).filter { !$0.name.isEmpty }.count
                let nb = TrophyXML.parse(b).filter { !$0.name.isEmpty }.count
                return na == nb ? a.count < b.count : na < nb
            } ?? plain
            finishPlainTRP(xml: best, name: sfm.name,
                           fallbackNpcommid: fallbackNpcommid, icons: listed)
            return
        }

        // A .trp does not store its NPcommID, so try the derived one first.
        if !fallbackNpcommid.isEmpty,
           let xml = ESFM.decrypt(blob: blob, npcommid: fallbackNpcommid) {
            finishTRP(config: xml, texts: nameBlobs, npcommid: fallbackNpcommid,
                      carved: carved, icons: listed)
            return
        }

        // The title ID is often not derivable, so a bounded search is needed.
        // It runs off the main actor: even optimised it is ~0.4s of AES, which
        // would otherwise stall the window.
        trophyStatus = Message("trophy.msg.searching", name)
        Task.detached(priority: .userInitiated) { [weak self] in
            let hit = ESFM.bruteForceNPID(blob: blob, range: 0...20_000)
            await MainActor.run {
                guard let self = self else { return }
                guard let hit = hit else {
                    self.trophyStatus = Message("trophy.msg.encrypted", name)
                    return
                }
                self.finishTRP(config: hit.1, texts: nameBlobs, npcommid: hit.0,
                               carved: carved, icons: listed)
            }
        }
    }

    /// Merge the configuration and text blobs, then pair the art to the ids.
    private func finishTRP(config: Data, texts: [Data], npcommid: String,
                           carved: [(data: Data, width: Int, height: Int)],
                           icons: [String: Data] = [:]) {
        let conf = TrophyXML.parse(config)

        // Text blobs repeat the same ids with names; several may exist for the
        // same id when a pack ships more than one language set.
        var named: [String: Trophy] = [:]
        for blob in texts {
            guard let xml = ESFM.decrypt(blob: blob, npcommid: npcommid) else { continue }
            for t in TrophyXML.parse(xml) where !t.name.isEmpty { named[t.id] = t }
        }

        // The configuration stays authoritative for grade and hidden; only the
        // text comes from the other blobs.
        var list = conf.map { t -> Trophy in
            guard let n = named[t.id] else { return t }
            return Trophy(id: t.id, name: n.name, detail: n.detail,
                          type: t.type, hidden: t.hidden)
        }
        // Some titles declare trophies only in the text blob.
        if list.isEmpty {
            list = named.values
                .sorted { $0.id < $1.id }
                .map { Trophy(id: $0.id, name: $0.name, detail: $0.detail,
                              type: $0.type, hidden: $0.hidden) }
        }

        trophies = list
        trophyNpCommId = npcommid
        // Prefer the entry table's id-named icons; fall back to positional
        // pairing only for archives that do not list them.
        if icons.isEmpty {
            trophyIconMap = UCP.pairCarvedIcons(carved, with: list)
            trophyIcons = carved.map(\.data)
        } else {
            trophyIconMap = icons
            trophyIcons = list.compactMap { icons[$0.id] } + carved
                .filter { c in !list.contains { icons[$0.id] == c.data } }
                .map(\.data)
        }
        trophyStatus = list.isEmpty ? Message("trophy.msg.encrypted", npcommid) : nil
    }

    /// `TROP000.PNG` -> "000", read straight from the entry table.
    ///
    /// The archive names each icon after its trophy, so the mapping is exact.
    /// Positional pairing (used when an archive omits the entries) is a guess
    /// by comparison, and it breaks on packs whose icons are not in id order.
    private func trpIconsById(_ files: [TrpFile], in data: Data) -> [String: Data] {
        var out: [String: Data] = [:]
        for f in files {
            let stem = (f.name as NSString).deletingPathExtension.uppercased()
            guard stem.hasPrefix("TROP"), f.size > 8,
                  f.offset >= 0, f.offset + f.size <= data.count else { continue }
            let digits = stem.dropFirst("TROP".count)
            guard !digits.isEmpty, digits.allSatisfy(\.isNumber),
                  digits.count <= 4 else { continue }
            let blob = data.subdata(in: f.offset..<(f.offset + f.size))
            // Group art is named `GR…`; anything that is not a PNG is skipped.
            guard blob.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]) else { continue }
            out[String(digits)] = blob
        }
        return out
    }

    /// A PS3 `.trp`: the members are plain XML, so no key is involved and the
    /// NPCommID is read straight out of the document.
    private func finishPlainTRP(xml: Data, name: String, fallbackNpcommid: String,
                                icons: [String: Data]) {
        let list = TrophyXML.parse(xml)
        let stated = TrophyXML.npcommid(in: xml)
        let title = TrophyXML.titleName(in: xml) ?? ""
        if !title.isEmpty { trophyTitle = title }
        trophies = list
        trophyNpCommId = stated.isEmpty ? fallbackNpcommid : stated
        // The entry table names each icon after its trophy, so this mapping is
        // exact — no reliance on the images happening to be in id order.
        trophyIconMap = icons
        trophyStatus = list.isEmpty ? Message("trophy.msg.badTRP", name) : nil
    }

    /// Best-effort NPcommID guess from the result's Title ID.
    private static func npcommid(from res: PkgResult?) -> String {
        guard let res = res else { return "" }
        // A trophy pack names the communication id in its own path —
        // `TROPDIR/NPWR08388_00/TROPHY.TRP` on PS3, `trophy2/NPWR…_00.ucp` on
        // PS5. That is the authoritative value; deriving one from the title id
        // guesses wrong whenever they differ.
        for e in res.entries where e.isTrophyPack {
            for part in e.name.split(whereSeparator: { $0 == "/" }) where part.uppercased().hasPrefix("NPWR") {
                let tag = String(part).uppercased()
                if tag.count >= 9 { return String(tag.prefix(9)) }   // NPWR08388_00
            }
        }
        let tid = res.patchTid.isEmpty ? (res.rowDict["Title ID"] ?? "") : res.patchTid
        let digits = tid.uppercased().filter(\.isNumber)
        guard digits.count >= 5 else { return "" }
        let n = String(digits.prefix(5))
        return "NPWR\(n)_00"
    }

    // MARK: History

    private func pushHistory(_ url: URL) {
        history.removeAll { $0 == url }
        history.insert(url, at: 0)
        if history.count > 20 { history.removeLast(history.count - 20) }
        UserDefaults.standard.set(history.map(\.path), forKey: historyKey)
    }

    func loadHistory() {
        guard history.isEmpty else { return }
        history = (UserDefaults.standard.stringArray(forKey: historyKey) ?? []).map { URL(fileURLWithPath: $0) }
    }

    // MARK: Derived UI state

    var filteredEntries: [PkgEntry] {
        guard let res = result else { return [] }
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let f = fileFilter.trimmingCharacters(in: .whitespaces).lowercased()
        return res.entries.filter { e in
            (q.isEmpty || e.name.lowercased().contains(q)) &&
            (f.isEmpty || (e.codec?.lowercased().contains(f) ?? false))
        }
    }

    var primaryCover: Data? { coverImages.first?.data }

    /// The publisher logo, when the package ships one.
    ///
    /// Most retail packages do not — `sce_sys` holds only `icon0` and the
    /// `pic*` key art — so this is usually nil. Some first-party titles include
    /// `logo0.png` / `logo1.png`, and those are worth showing above the title.
    /// `.dds` variants and PS3's `PS3LOGO.DAT` are deliberately excluded: the
    /// former need a decoder, the latter is boot data rather than an image.
    var logoCover: Data? {
        let names = ["logo0.png", "logo1.png", "logo.png", "publisher.png"]
        for n in names {
            if let hit = coverImages.first(where: { $0.name.lowercased() == n }) {
                return hit.data
            }
        }
        // A dump may carry a different but unambiguous name; only accept one
        // that is clearly a logo and is not key art or an app icon.
        return coverImages.first { item in
            let n = item.name.lowercased()
            guard n.hasSuffix(".png"), n.contains("logo") else { return false }
            return !n.hasPrefix("pic") && !n.hasPrefix("icon")
        }?.data
    }

    /// The wide key art (`pic1.png`), used as the Overview backdrop.
    ///
    /// `pic0`/`pic1` are 3840x2160 on a retail package and read very differently
    /// from the square `icon0`; the artwork is meant to sit behind the content,
    /// so the explicit name is preferred over "the biggest one available".
    var backdropCover: Data? {
        if let hit = coverImages.first(where: { $0.name.lowercased() == "pic1.png" }) {
            return hit.data
        }
        // A dump may have renamed it; fall back to the largest landscape image.
        let wide = coverImages
            .filter { ($0.name.lowercased()).hasSuffix(".png") }
            .max { a, b in
                pngWidth(a.data) * pngHeight(a.data) < pngWidth(b.data) * pngHeight(b.data)
            }
        guard let wide else { return nil }
        let w = pngWidth(wide.data), h = pngHeight(wide.data)
        return (h > 0 && w > h * 4 / 3) ? wide.data : nil
    }

    /// PNG dimensions from the IHDR chunk, or 0 when the blob is not a PNG.
    private func pngWidth(_ d: Data) -> Int {
        guard d.count > 24, d.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]) else { return 0 }
        return d[16...19].reduce(0) { ($0 << 8) | Int($1) }
    }

    private func pngHeight(_ d: Data) -> Int {
        guard d.count > 24, d.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]) else { return 0 }
        return d[20...23].reduce(0) { ($0 << 8) | Int($1) }
    }
}
