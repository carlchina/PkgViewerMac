import Foundation

/// Headless trophy inspection: `PkgViewer --trophies <pkg>`.
/// Prints what the Trophies tab would show, so the UCP/TRP paths can be
/// checked without launching the UI.
@MainActor
enum TrophyPrinter {
    /// `--ucp-dump`: print every non-image member and the shape of its JSON.
    static var dumpUCP = false

    /// Per-language metadata, side by side.
    ///
    /// A pack may store the grade in one file and the names in another, or a
    /// language file may simply omit fields the pack default carries. Printing
    /// each file's top-level keys and a sample trophy is what makes that
    /// visible.
    static func dumpMembers(_ files: [UCP.File], in data: Data) {
        print("\n--- UCP non-image members ---")
        for f in files where !f.name.lowercased().hasSuffix(".png") {
            print("   \(f.name)  \(f.size)")
        }
        print("\n--- JSON shapes ---")
        for f in files where f.name.lowercased().hasSuffix(".json") {
            guard f.offset >= 0, f.size > 0, f.offset + f.size <= data.count else { continue }
            let blob = data.subdata(in: f.offset..<(f.offset + f.size))
            guard let obj = try? JSONSerialization.jsonObject(with: blob) as? [String: Any] else {
                print("\n\(f.name): not JSON (first 200 bytes)")
                print("   \(String(decoding: blob.prefix(200), as: UTF8.self))")
                continue
            }
            print("\n\(f.name): keys = \(obj.keys.sorted().joined(separator: ", "))")
            if let list = obj["trophies"] as? [[String: Any]], let first = list.first {
                let sample = first.keys.sorted().joined(separator: ", ")
                print("   trophy[0] keys: \(sample)")
                // Report which of the fields the UI depends on are present.
                var have: [String] = []
                if list.contains(where: { $0["ttype"] != nil }) { have.append("ttype") }
                if list.contains(where: { $0["hidden"] != nil }) { have.append("hidden") }
                if list.contains(where: { $0["name"] != nil }) { have.append("name") }
                if list.contains(where: { $0["detail"] != nil }) { have.append("detail") }
                if list.contains(where: { ($0["grade"] as? Int) != nil }) { have.append("grade") }
                print("   count=\(list.count)  has: \(have.joined(separator: ", "))")
            }
            // The full schema hides the list one level down; show its shape
            // too, since that is where the grade has to live.
            if let md = obj["metadata"] as? [String: Any] {
                print("   metadata keys: \(md.keys.sorted().joined(separator: ", "))")
                if let tm = md["trophyMetadata"] as? [[String: Any]], let f0 = tm.first {
                    print("   trophyMetadata[0] keys: \(f0.keys.sorted().joined(separator: ", "))")
                    print("   trophyMetadata[0] value: \(f0)")
                }
            }
        }
    }

    static func run(_ url: URL, forcedLocales: [String] = []) {
        let res = PkgLoader.load(url: url)
        if let f = res.failed {
            print("ERROR: \(f.english())")
            return
        }
        let packs = res.entries.filter { $0.isTrophyPack }
        print("trophy-pack candidates: \(packs.count)")
        for p in packs { print("   \(p.name)  \(Fmt.size(p.size))") }

        guard let entry = bestPack(packs) else {
            print("RESULT: no trophy pack")
            return
        }
        print("chosen: \(entry.name)")

        guard let reader = FileHandleReader(url: url) else { print("cannot open"); return }
        defer { reader.close() }
        guard let data = PkgLoader.readEntry(entry, reader: reader), !data.isEmpty else {
            print("RESULT: cannot read pack bytes"); return
        }
        print("pack bytes: \(data.count)  magic: \(data.prefix(4).map { String(format: "%02x", $0) }.joined())")

        if entry.name.lowercased().hasSuffix(".ucp") {
            let files = UCP.parse(data)
            print("\nUCP members: \(files.count)")
            for f in files.prefix(12) { print("   \(f.name)  \(f.size)") }
            if files.count > 12 { print("   ... +\(files.count - 12) more") }

            // `--ucp-dump`: the per-language metadata side by side. Trophy
            // grade and hidden-flag live in fields that are not present in
            // every language's JSON, and this is the only way to see which
            // file actually carries them.
            if dumpUCP {
                dumpMembers(files, in: data)
                UCP.dumpHeader(data)
                return
            }

            let lg = L10n()
            if !forcedLocales.isEmpty { print("  forced   : \(forcedLocales)") }
            let want = forcedLocales.isEmpty
                ? TrophyLanguage.preference(for: lg.effectiveLanguageTags)
                : forcedLocales + TrophyLanguage.preference(for: lg.effectiveLanguageTags)
            let c = UCP.read(data, wanted: want)
            print("\nlocale selection:")
            print("  wanted   : \(want.prefix(4).joined(separator: ", "))")
            print("  chosen   : \(c.localeTag ?? "-")")
            let locs = UCP.availableLocales(data)
            print("  available: \(locs.count) files")
            for lc in locs.sorted(by: { $0.tag < $1.tag }) {
                let flag = lc.tag.lowercased().hasPrefix(c.localeTag?.lowercased() ?? "?") ? " <-- shown" : ""
                print("    \(lc.tag)\(flag)")
            }
            print("\nNpCommId : \(c.npcommid)")
            print("Title    : \(c.title)")
            print("Trophies : \(c.trophies.count)")
            print("Icons    : \(c.icons.count) in archive, \(UCP.displayIcons(c.icons).count) shown in UI")
            let map = UCP.displayIconMap(c.icons)
            print("Icon map : \(map.count) id->image pairs")
            let ids = Set(c.trophies.map(\.id))
            let missing = ids.subtracting(Set(map.keys)).sorted()
            print("Matched  : \(ids.count - missing.count)/\(ids.count) trophies have art")
            if !missing.isEmpty {
                print("No art   : \(missing.prefix(10).joined(separator: ", "))\(missing.count > 10 ? " ..." : "")")
            }
            // sanity: a couple of specific mappings
            for probe in ["0000", "0004", "0063"] where ids.contains(probe) {
                print("  \(probe) -> \(map[probe].map { "\($0.count) bytes" } ?? "MISSING")")
            }
            for (n, d) in c.icons.sorted(by: { $0.key < $1.key }).prefix(3) {
                print("   \(n)  \(d.count) bytes")
            }
            for t in c.trophies.prefix(8) {
                // CLI stays English: resolve the grade key against en.lproj.
                let b = Message.englishBundle
                print("   id=\(t.id) grade=\(t.gradeText { b.localizedString(forKey: $0, value: $0, table: nil) }) name=\(t.name)  —  \(t.detail)")
            }
            print(c.trophies.isEmpty ? "\nRESULT: FAILED" : "\nRESULT: OK")
        } else {
            let files = TRP.parse(data)
            print("\nTRP members: \(files.count)")
            for f in files.prefix(12) { print("   \(f.name)  \(f.size)") }
            let carved = PNGCarve.carve(data)
            print("carved PNGs: \(carved.count)")

            // PS4/PS5 name the members `TROP.ESFM`; PS3 omits the E (`TROP.SFM`).
            if let sfm = files.first(where: {
                let u = $0.name.uppercased()
                return u.hasPrefix("TROP") && u.hasSuffix("SFM") && $0.size > 0
            }) {
                let blob = data.subdata(in: sfm.offset..<(sfm.offset + sfm.size))
                // PS3 members are plain XML; no key search is needed.
                if let plain = ESFM.plainXML(blob) {
                    // Prefer a blob that carries names: TROPCONF.SFM holds only
                    // the configuration, TROP.SFM has the text for each id.
                    let others = files.filter {
                        let u = $0.name.uppercased()
                        return u.hasSuffix("SFM") && $0.size > 0
                    }.map { data.subdata(in: $0.offset..<($0.offset + $0.size)) }
                    let best = others.compactMap { ESFM.plainXML($0) }
                        .first { TrophyXML.parse($0).contains { !$0.name.isEmpty } }
                    let use = best ?? plain
                    let l = TrophyXML.parse(use)
                    print("\nplain XML  : yes (no key needed)")
                    print("NpCommId   : \(TrophyXML.npcommid(in: use))")
                    print("Title      : \(TrophyXML.titleName(in: use) ?? "-")")
                    print("Trophies   : \(l.count)")
                    for t in l.prefix(10) {
                        print("   \(t.id)  \(t.gradeText { $0 })  \(t.name)  —  \(t.detail)")
                    }
                    print(l.isEmpty ? "\nRESULT: FAILED" : "\nRESULT: OK")
                    return
                }
                let t0 = Date()
                if let hit = ESFM.bruteForceNPID(blob: blob, range: 0...20_000) {
                    let list = TrophyXML.parse(hit.1)
                    print(String(format: "\nkey search : %.3fs", Date().timeIntervalSince(t0)))
                    print("NpCommId   : \(hit.0)")
                    print("Trophies   : \(list.count)")
                    // The name/detail text lives in a second ESFM blob.
                    if let named = files.first(where: { $0.name.uppercased().contains("_00") }),
                       named.size > 0 {
                        let nb = data.subdata(in: named.offset..<(named.offset + named.size))
                        if let xml2 = ESFM.decrypt(blob: nb, npcommid: hit.0) {
                            let l2 = TrophyXML.parse(xml2)
                            print("named blob : \(named.name), \(l2.count) entries")
                            for t in l2.prefix(6) { print("   \(t.id)  \(t.name)") }
                        } else {
                            print("named blob : \(named.name) — could not decrypt")
                        }
                    }
                    for t in list.prefix(6) {
                        let b = Message.englishBundle
                        print("   conf id=\(t.id) grade=\(t.gradeText { b.localizedString(forKey: $0, value: $0, table: nil) }) hidden=\(t.hidden)")
                    }
                    print("\nRESULT: OK")
                } else {
                    print(String(format: "\nkey search : %.3fs — no key in range",
                                 Date().timeIntervalSince(t0)))
                    print("\nRESULT: FAILED")
                }
            }
        }
    }

    /// Mirror of PkgViewModel.bestPack so the CLI picks the same pack.
    static func bestPack(_ packs: [PkgEntry]) -> PkgEntry? {
        let real = packs.filter { e in
            let n = e.name.lowercased()
            return n.contains("trophy") && !n.hasPrefix("uds")
        }
        let pool = real.isEmpty ? packs : real
        return pool.max { a, b in score(a.name) < score(b.name) }
    }

    static func score(_ name: String) -> Int {
        let n = name.lowercased()
        if n.contains("trophy2") || n.contains("trophy00") { return 3 }
        if n.contains("trophy") { return 2 }
        if n.hasSuffix(".trp") { return 1 }
        return 0
    }
}
