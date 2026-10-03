import Foundation

// MARK: - TRP container

struct TrpFile {
    let name: String
    let offset: Int
    let size: Int
    /// `flags == 3` marks an encrypted ESFM payload.
    let flags: UInt32
}

enum TRP {
    /// Inner files of a `.trp` trophy archive (PS3/PS4/PS5).
    ///
    /// Layout, matching PS4PKGTool's reader (via pearlxcore/PkgViewer):
    ///
    ///   0x00  u32le  magic 0x004DA2DC  ("DCA24D00")
    ///   0x04  u32be  version 1...3
    ///   0x08  u64be  total size — must equal the file length
    ///   0x10  u32be  entry count
    ///   0x14  u32be  entry size (>= 64)
    ///   0x18  32-byte digest
    ///   header = 0x60 for version 3, else 0x40
    ///   entries, each: `char name[36]`, u32be offset @36, u64be size @40,
    ///                  u32be flags @48
    ///
    /// An earlier version of this read the count from offset 4 — which is
    /// actually the *version* — so a 45-entry archive reported 2 members and
    /// the real payload (per-language `TROP_NN.SFM` blobs and the
    /// `TROPnnn.PNG` icon set) was never read.
    static func parse(_ data: Data) -> [TrpFile] {
        guard data.count >= 0x40 else { return [] }
        let r = ByteReader(data)
        guard let magic = r.u32le(at: 0), magic == 0x004D_A2DC else { return [] }
        guard let version = r.u32be(at: 4), (1...3).contains(version),
              let total = r.u64be(at: 8),
              let count = r.u32be(at: 0x10),
              let esize = r.u32be(at: 0x14) else { return [] }
        guard Int(total) == data.count,
              esize >= 64, esize <= 4096,
              (1...10_000).contains(count) else { return [] }

        let header = version == 3 ? 0x60 : 0x40
        // Reject a table that would run past the end before indexing into it.
        guard header <= data.count,
              Int(count) * Int(esize) <= data.count - header else { return [] }

        var out: [TrpFile] = []
        out.reserveCapacity(Int(count))
        for i in 0..<Int(count) {
            let eo = header + i * Int(esize)
            // The name is NUL-terminated within its 36-byte slot.
            guard let name = r.fixedString(at: eo, length: 36), !name.isEmpty else { return [] }
            guard let off = r.u32be(at: eo + 36), let size = r.u64be(at: eo + 40) else { return [] }
            let flags = r.u32be(at: eo + 48) ?? 0
            guard UInt64(off) + size <= UInt64(data.count) else { return [] }
            out.append(TrpFile(name: name, offset: Int(off), size: Int(size), flags: flags))
        }
        return out
    }

    /// The member carrying the trophy configuration, preferring the canonical
    /// names. PS3 writes `TROP.SFM` (no `E`), PS4/PS5 `TROP.ESFM`.
    static func metadataEntry(_ files: [TrpFile]) -> TrpFile? {
        let preferred = ["TROP.ESFM", "TROP.SFM", "TROPCONF.ESFM", "TROPCONF.SFM"]
        for name in preferred {
            if let hit = files.first(where: { $0.name.uppercased() == name }) { return hit }
        }
        return files.first { f in
            let u = f.name.uppercased()
            return (u.hasSuffix(".ESFM") || u.hasSuffix(".SFM")) && f.size > 0
        }
    }

    /// Per-language text blobs, named `TROP_NN.SFM` on every generation.
    static func textEntries(_ files: [TrpFile]) -> [TrpFile] {
        files.filter { f in
            let u = f.name.uppercased()
            return u.contains("_") && (u.hasSuffix(".ESFM") || u.hasSuffix(".SFM")) && f.size > 0
        }
    }
}

// MARK: - UCP container (PS5 trophy archives)

/// A file inside a `.ucp` archive. Newer PS5 dumps use this instead of `.trp`.
enum UCP {
    /// Container signature: `b2 28 c6 0a`.
    static let magic: [UInt8] = [0xB2, 0x28, 0xC6, 0x0A]

    struct File {
        let name: String
        let offset: Int
        let size: Int
    }

    /// Parse the UCP file table.
    ///
    /// Parse the UCP file table.
    ///
    /// Layout, matching PS5PKGTool's `UcpReader`:
    ///
    ///   0x00  magic b2 28 c6 0a
    ///   0x04  u32be version (1)
    ///   0x08  u64be declared size — must equal the file length
    ///   0x10  u32be file count
    ///   0x14  u32be entry size (>= 0x30)
    ///   0x1C  20-byte SHA-1 of the file with this field zeroed
    ///   0x60  entries, each: `char name[32]`, u64be offset @32, u64be size @40
    ///
    /// This used to walk the table heuristically from 0x40 — read a record, and
    /// stop as soon as the name stopped looking printable. Two things were
    /// wrong with that: 0x40 is *padding* after the hash, not a record, and
    /// stopping early silently dropped zero-length entries (a 58-entry archive
    /// reported 57). The count in the header is authoritative, so the table is
    /// read exactly that many times from 0x60, and anything inconsistent
    /// rejects the whole archive.
    static func parse(_ data: Data) -> [File] {
        let headerSize = 0x60
        guard data.count >= headerSize, data.count >= 4,
              Array(data[0..<4]) == magic else { return [] }
        let r = ByteReader(data)
        guard let version = r.u32be(at: 4), version == 1,
              let declared = r.u64be(at: 8),
              let count = r.u32be(at: 0x10),
              let esize = r.u32be(at: 0x14) else { return [] }
        guard declared == UInt64(data.count),
              esize >= 0x30, esize <= 0x1000,
              count <= 100_000 else { return [] }
        // The table must fit, so a bogus count cannot walk into the payload.
        let tableSize = Int(count) * Int(esize)
        guard headerSize + tableSize <= data.count else { return [] }

        var out: [File] = []
        out.reserveCapacity(Int(count))
        var previousEnd = headerSize + tableSize
        for i in 0..<Int(count) {
            let eo = headerSize + i * Int(esize)
            guard let name = r.fixedString(at: eo, length: 32), !name.isEmpty else { return [] }
            guard let off = r.u64be(at: eo + 32), let size = r.u64be(at: eo + 40) else { return [] }
            // Payloads are written in order, so each entry starts at or after
            // the previous one ends. This is what rejects a misread table.
            guard off >= UInt64(previousEnd), off + size <= UInt64(data.count) else { return [] }
            out.append(File(name: name, offset: Int(off), size: Int(size)))
            previousEnd = Int(off + size)
        }
        return out
    }

    /// Print the raw header fields. The parse is heuristic, so when a member
    /// count looks wrong these numbers say whether the header itself was read
    /// correctly — `version`/`count`/`entrySize` have narrow valid ranges.
    static func dumpHeader(_ data: Data) {
        func u32(_ o: Int) -> UInt32 { ByteReader(data).u32be(at: o) ?? 0 }
        func u64(_ o: Int) -> UInt64 { ByteReader(data).u64be(at: o) ?? 0 }
        print("\n--- UCP header ---")
        print(String(format: "  magic      : %@", data.prefix(4)
            .map { String(format: "%02x", $0) }.joined() as NSString))
        print("  version@4  : \(u32(4))")
        print("  size@8     : \(u64(8))  (file is \(data.count))")
        print("  count@16   : \(u32(16))")
        print("  entrySize@20: \(u32(20))")
        print("  sha1@0x1C  : \(data.count >= 0x30 ? data[0x1C..<0x30].map { String(format: "%02x", $0) }.joined() : "-")")
        print("  first 0x70 : \(data.prefix(0x70).map { String(format: "%02x", $0) }.joined())")
    }

    /// Everything the Trophies tab needs from a UCP archive.
    struct Contents {
        /// Locale actually used for the text, e.g. "ja-JP".
        var localeTag: String?
        var npcommid: String = ""
        var title: String = ""
        var trophies: [Trophy] = []
        /// Icon PNGs keyed by filename (trop0001.png, icon0_en-US.png, …).
        var icons: [String: Data] = [:]
        /// The pack's own `defaultLanguage`, from `tropconf.json`.
        var packDefault: String?
        /// The languages `tropconf.json` declares, when it lists them.
        var languages: [String] = []
    }

    /// Icons worth showing in a gallery, keyed by trophy id.
    ///
    /// A UCP ships the same art once per locale (`trop0001_en-US.png`,
    /// `icon0_ja-JP.png`, `gr0001_*.png`). Showing all of them just repeats
    /// the same image, so prefer the neutral `trop*.png` set and fall back to
    /// the en-US variants when a dump only has localised art.
    ///
    /// The key is the numeric id parsed out of `trop0007.png`, so the Trophies
    /// tab can show the right art when a row is clicked.
    static func displayIconMap(_ icons: [String: Data]) -> [String: Data] {
        guard !icons.isEmpty else { return [:] }
        let neutral = icons.keys.filter { name in
            let lower = name.lowercased()
            guard lower.hasPrefix("trop") else { return false }
            // A locale suffix shows up as _xx or _xx-YY before the extension.
            let stem = (name as NSString).deletingPathExtension
            return !stem.contains("_")
        }
        let chosen: [String]
        if neutral.isEmpty {
            chosen = icons.keys.filter {
                let l = $0.lowercased()
                return l.contains("_en-us") || l.hasPrefix("trop")
            }
        } else {
            chosen = neutral
        }
        var out: [String: Data] = [:]
        for name in chosen.sorted() {
            if let id = trophyID(fromIconName: name) {
                out[id] = icons[name]!
            }
        }
        return out
    }

    /// Icons as a flat list, for the gallery and export.
    static func displayIcons(_ icons: [String: Data]) -> [Data] {
        Array(displayIconMap(icons).values)
    }

    /// Pair carved .trp images with trophy ids.
    ///
    /// Carving finds the images by scanning for PNG magics, so their filenames
    /// are gone. A .trp holds two kinds: square trophy icons (240x240 on PS4)
    /// and wide group banners (320x176). Only the icons are per-trophy, so the
    /// banners are dropped and the icons are paired in the order they appear —
    /// which is the order the trophies are declared in.
    static func pairCarvedIcons(_ images: [(data: Data, width: Int, height: Int)],
                                with trophies: [Trophy]) -> [String: Data] {
        guard !images.isEmpty, !trophies.isEmpty else { return [:] }
        // Square images are the per-trophy icons; wide ones are banners.
        let icons = images.filter { $0.width == $0.height && $0.width >= 64 }
        let pool = icons.isEmpty ? images : icons
        // Only pair when the counts line up; otherwise the mapping is a guess.
        guard pool.count == trophies.count else { return [:] }
        var out: [String: Data] = [:]
        for (t, img) in zip(trophies, pool) { out[t.id] = img.data }
        return out
    }

    /// "trop0007.png" -> "0007"; "trop12_en-US.png" -> "12".
    /// Returns nil for group/banner art (`gr0001_*`, `icon0_*`).
    static func trophyID(fromIconName name: String) -> String? {
        let stem = (name as NSString).deletingPathExtension
        guard stem.lowercased().hasPrefix("trop") else { return nil }
        let digits = String(stem.dropFirst(4))
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        // Trophy ids are zero-padded to 4; normalise so lookups always match.
        let n = Int(digits) ?? -1
        return n >= 0 ? String(format: "%04d", n) : nil
    }

    /// Locales the pack carries.
    ///
    /// The authoritative source is the `schemaVersion 1.00` manifest, whose
    /// `languages` array lists every locale the pack ships and whose
    /// `defaultLanguage` is what the console itself uses. That file is a
    /// manifest rather than a translation: it carries ids and grades but no
    /// names, and it is present in every dump measured so far. Filenames are
    /// used to fill any gap, and to map each manifest entry back to the file
    /// that actually holds it.
    static func availableLocales(_ data: Data) -> [TrophyLanguage.Candidate] {
        let files = parse(data)
        var named: [TrophyLanguage.Candidate] = []
        var seen = Set<String>()

        // Manifest first: it is the only list that cannot be wrong. It normally
        // lives in `tropconf.json`; some older packs repeat it per language file.
        for f in files {
            let lower = f.name.lowercased()
            let isConf = lower == "tropconf.json"
            guard isConf || (f.name.hasPrefix("tropmeta_") && lower.hasSuffix(".json")) else {
                continue
            }
            guard let obj = jsonObject(f, in: data) else { continue }
            let langs = obj["languages"] as? [String] ?? []
            let dflt = obj["defaultLanguage"] as? String
            guard !langs.isEmpty else { continue }
            for l in langs where seen.insert(l.lowercased()).inserted {
                named.append(TrophyLanguage.Candidate(tag: l, isPackDefault: l == dflt))
            }
        }

        if named.isEmpty {
            // No manifest: trust the filenames.
            for f in files {
                guard let tag = TrophyLanguage.localeTag(fromMetaName: f.name),
                      seen.insert(tag.lowercased()).inserted else { continue }
                named.append(TrophyLanguage.Candidate(tag: tag))
            }
        }
        // The pack default first, so the menu opens on what the console uses.
        return named.sorted { a, b in
            if a.isPackDefault != b.isPackDefault { return a.isPackDefault }
            return a.tag < b.tag
        }
    }

    /// The pack's own `defaultLanguage`.
    ///
    /// `tropconf.json` declares it, so that file is checked first; older packs
    /// only repeat it inside a language file, hence the fallback scan.
    static func packDefaultLanguage(_ data: Data) -> String? {
        for f in parse(data) {
            let lower = f.name.lowercased()
            guard lower == "tropconf.json"
                    || (f.name.hasPrefix("tropmeta_") && lower.hasSuffix(".json")) else { continue }
            guard let obj = jsonObject(f, in: data),
                  let d = obj["defaultLanguage"] as? String, !d.isEmpty else { continue }
            return d
        }
        return nil
    }

    private static func jsonObject(_ f: File, in data: Data) -> [String: Any]? {
        guard f.offset >= 0, f.size > 0, f.offset + f.size <= data.count else { return nil }
        let blob = data.subdata(in: f.offset..<(f.offset + f.size))
        return try? JSONSerialization.jsonObject(with: blob) as? [String: Any]
    }

    /// Read a UCP archive into trophy metadata plus icon blobs.
    ///
    /// `wanted` is an ordered list of locale tags to try; the first one the
    /// pack provides wins, falling back to any available metadata.
    static func read(_ data: Data, wanted: [String] = ["en-US"]) -> Contents {
        var out = Contents()
        let files = parse(data)
        guard !files.isEmpty else { return out }

        // Read only the members we need; the archive can be tens of megabytes.
        var blobs: [String: Data] = [:]
        var confBlobs: [Data] = []
        for f in files {
            let lower = f.name.lowercased()
            // `tropconf.json` is the pack's trophy *configuration*: the grade
            // and hidden flag for every id, plus `languages` / `defaultLanguage`.
            // It is not per-language, so it is read separately below.
            let isConf = lower == "tropconf.json"
            let isMeta = f.name.hasPrefix("tropmeta_") && lower.hasSuffix(".json")
            let isPng = lower.hasSuffix(".png")
            guard isConf || isMeta || isPng else { continue }
            guard f.offset >= 0, f.size >= 0, f.offset + f.size <= data.count else { continue }
            let blob = data.subdata(in: f.offset..<(f.offset + f.size))
            if isPng {
                if blob.count > 8, blob.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]) {
                    out.icons[f.name] = blob
                }
            } else if isConf {
                confBlobs.append(blob)
            } else {
                blobs[f.name] = blob
            }
        }

        // Dumped filenames do not always hold the language they claim, so each
        // file's script is noted where it is unambiguous. A file whose script
        // contradicts its name is then selected by what it really contains.
        var identified: [String: String] = [:]
        for (name, raw) in blobs {
            guard let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                  let s = sampleText(obj), let script = TrophyLanguage.scriptOf(s) else { continue }
            identified[name] = script
        }
        let pick = TrophyLanguage.chooseMeta(among: Array(blobs.keys), wanted: wanted,
                                             identified: identified)
        // Report the language actually shown, which is not always the file's
        // name: a mislabelled dump is corrected here so the UI can say so.
        out.localeTag = pick.flatMap { n -> String? in
            let claimed = TrophyLanguage.localeTag(fromMetaName: n)
            guard let found = identified[n], let claimed else { return claimed }
            // Correct the label whenever the text is in a different family,
            // whichever side the mismatch is on: `nl-NL` holding Korean counts
            // as much as `zh-Hans` holding Thai.
            let a = claimed.lowercased().split(separator: "-").first.map(String.init) ?? ""
            let b = found.lowercased().split(separator: "-").first.map(String.init) ?? ""
            let cjk = ["zh", "ja", "ko", "ru", "ar", "th"]
            let aCJK = cjk.contains(a), bCJK = cjk.contains(b)
            return (aCJK != bCJK || (aCJK && a != b)) ? found : claimed
        }

        guard let name = pick, let raw = blobs[name],
              let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            return out
        }
        out.npcommid = obj["trophyNpCommId"] as? String ?? ""
        let md = obj["metadata"] as? [String: Any] ?? [:]
        if let tm = md["titleMetadata"] as? [String: Any] {
            out.title = tm["name"] as? String ?? ""
        }

        // Grade and hidden live in `tropconf.json`, which is *not* per-language:
        // it is the pack's single trophy definition list. The `tropmeta_*.json`
        // files carry only id/name/detail, so reading the text alone leaves the
        // grade column blank. Taking the definition from the config file is
        // both authoritative and what the console itself does.
        //
        // The config's array is authoritative; a language file that happens to
        // carry its own `grade`/`hidden` still wins for that field, since it is
        // the more specific source.
        var grades: [String: String] = [:]
        var hiddenFlags: [String: Bool] = [:]
        for raw in confBlobs {
            guard let conf = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
                continue
            }
            if let declared = conf["defaultLanguage"] as? String, !declared.isEmpty,
               out.packDefault == nil {
                out.packDefault = declared
            }
            if let langs = conf["languages"] as? [String], !langs.isEmpty, out.languages.isEmpty {
                out.languages = langs
            }
            for t in trophyList(in: conf) {
                let tid = String(describing: t["id"] ?? "")
                if tid.isEmpty { continue }
                let g = gradeValue(t["grade"] ?? t["ttype"])
                if !g.isEmpty { grades[tid] = g }
                if let h = t["hidden"] { hiddenFlags[tid] = hiddenValue(h) }
            }
        }
        // Older packs put the definition inside a language file instead.
        if grades.isEmpty || hiddenFlags.isEmpty {
            for (_, rawBlob) in blobs {
                guard let other = try? JSONSerialization.jsonObject(with: rawBlob) as? [String: Any] else {
                    continue
                }
                for t in trophyList(in: other) {
                    let tid = String(describing: t["id"] ?? "")
                    if grades[tid]?.isEmpty ?? true {
                        let g = gradeValue(t["grade"] ?? t["ttype"])
                        if !g.isEmpty { grades[tid] = g }
                    }
                    if hiddenFlags[tid] == nil, let h = t["hidden"] {
                        hiddenFlags[tid] = hiddenValue(h)
                    }
                }
            }
        }

        for t in trophyList(in: obj) {
            let tid = String(describing: t["id"] ?? "?")
            // Prefer this file's own values; fall back to the shared ones.
            let own = gradeValue(t["grade"] ?? t["ttype"])
            let ownHidden = t["hidden"].map(hiddenValue)
            out.trophies.append(Trophy(
                id: tid,
                name: t["name"] as? String ?? "",
                detail: t["detail"] as? String ?? "",
                type: !own.isEmpty ? own : (grades[tid] ?? ""),
                hidden: ownHidden ?? hiddenFlags[tid] ?? false
            ))
        }
        return out
    }

    /// The trophy array, whichever schema the file uses.
    ///
    /// Most locales nest it as `metadata.trophyMetadata`, but some ship a
    /// reduced form with the entries directly under `trophies` — Arabic and
    /// Hebrew do, carrying id/hidden/grade but no names.
    private static func trophyList(in obj: [String: Any]) -> [[String: Any]] {
        if let md = obj["metadata"] as? [String: Any],
           let list = md["trophyMetadata"] as? [[String: Any]], !list.isEmpty {
            return list
        }
        return obj["trophies"] as? [[String: Any]] ?? []
    }

    /// A sample of the text a file contains, for language identification.
    ///
    /// Trophy names frequently mix scripts (a Japanese title quoting the
    /// original, a Russian string keeping the game's Han subtitle), so the
    /// sample has to be wide enough for the dominant script to be clear.
    private static func sampleText(_ obj: [String: Any]) -> String? {
        let md = obj["metadata"] as? [String: Any] ?? [:]
        var parts: [String] = []
        if let t = (md["titleMetadata"] as? [String: Any])?["name"] as? String { parts.append(t) }
        for t in trophyList(in: obj) {
            if let n = t["name"] as? String { parts.append(n) }
            if let d = t["detail"] as? String { parts.append(d) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// `hidden` is a "Yes"/"No" string in the full schema and a bool here.
    private static func hiddenValue(_ any: Any?) -> Bool {
        if let b = any as? Bool { return b }
        return (any as? String ?? "").lowercased() == "yes"
    }

    /// The reduced schema's single-letter grade, mapped to the usual letters.
    private static func gradeValue(_ any: Any?) -> String {
        // `grade` is a letter in the reduced schema, but a numeric rank in
        // others (0 bronze … 3 platinum), and `ttype` is always a letter.
        var letter = (any as? String)?.uppercased() ?? ""
        if letter.isEmpty, let n = any as? Int {
            switch n {
            case 0: letter = "B"
            case 1: letter = "S"
            case 2: letter = "G"
            case 3: letter = "P"
            default: letter = ""
            }
        }
        if letter.isEmpty, let n = any as? NSNumber {
            return gradeValue(n.intValue)
        }
        switch letter {
        case "P": return "P"        // platinum
        case "G": return "G"
        case "S": return "S"
        case "B": return "B"
        default: return ""
        }
    }
}

// MARK: - ESFM decryption

enum ESFM {
    /// Public trophy key (psdevwiki). Per-title NPcommID like NPWR13863_00
    /// derives the content key.
    static let trophyKey: [UInt8] = [
        0x21, 0xF4, 0x1A, 0x6B, 0xAD, 0x8A, 0x1D, 0x3E,
        0xCA, 0x7A, 0xD5, 0x86, 0xC1, 0x01, 0xB7, 0xA9,
    ]

    /// Decrypt one ESFM blob into XML bytes. Returns nil on any failure.
    static func decrypt(blob: Data, npcommid: String) -> Data? {
        guard blob.count >= 32, blob.count % 16 == 0 else { return nil }
        guard let contentKey = contentKey(for: npcommid) else { return nil }
        let iv = [UInt8](blob.prefix(16))
        let body = [UInt8](blob.dropFirst(16))
        guard let plain = decryptBody(contentKey: contentKey, iv: iv, body: body),
              let xml = validate(plain) else { return nil }
        return xml
    }

    /// contentKey = AES-ECB(trophyKey, npid)
    private static func contentKey(for npcommid: String) -> [UInt8]? {
        var npid = [UInt8](npcommid.utf8.prefix(16))
        if npid.count < 16 { npid += [UInt8](repeating: 0, count: 16 - npid.count) }
        return Crypto.aesECBEncrypt(key: trophyKey, block: npid)
    }

    /// CBC-decrypt and strip PKCS#7 padding.
    private static func decryptBody(contentKey: [UInt8], iv: [UInt8], body: [UInt8]) -> [UInt8]? {
        guard var plain = Crypto.aesCBCDecrypt(key: contentKey, iv: iv, data: body) else { return nil }
        guard let pad = plain.last, (1...16).contains(Int(pad)) else { return nil }
        let padCount = Int(pad)
        guard plain.count >= padCount else { return nil }
        for i in 0..<padCount where plain[plain.count - 1 - i] != pad { return nil }
        plain.removeLast(padCount)
        return plain
    }

    /// True when the plaintext looks like trophy XML.
    private static func validate(_ plain: [UInt8]) -> Data? {
        let head = String(decoding: plain.prefix(200), as: UTF8.self).lowercased()
        guard head.contains("trophy") else { return nil }
        let printable = plain.reduce(0) { $0 + (($1 >= 32 && $1 < 127) || $1 == 9 || $1 == 10 || $1 == 13 ? 1 : 0) }
        guard Double(printable) > Double(plain.count) * 0.7 else { return nil }
        return Data(plain)
    }

    /// The blob as-is when it is already readable trophy XML.
    ///
    /// A PS3 `.trp` stores `TROPCONF.SFM` / `TROP.SFM` unencrypted, so no key
    /// is needed. Detecting that first turns a fruitless brute-force search
    /// into a direct read — and the search would fail anyway, since PS3
    /// NPCommIDs are not in the PS4 range.
    static func plainXML(_ blob: Data) -> Data? {
        guard blob.count >= 16 else { return nil }
        return validate([UInt8](blob))
    }

    /// Search NPWRxxxxx_00 for the key that opens this blob.
    ///
    /// Two stages, because a wrong key only shows up in the *last* plaintext
    /// block: a full decrypt costs ~2k tries/s, while checking just that block
    /// costs ~50k/s. The padding byte is a 1-in-256 filter, so only a handful
    /// of candidates ever reach the expensive full check. This is the same
    /// trade the retail key search makes, and it is what keeps the UI responsive
    /// when the derived NPcommID is wrong.
    ///
    /// PS4 title IDs cluster below ~20000, so the default range is generous.
    static func bruteForceNPID(blob: Data, range: ClosedRange<Int> = 0...19_999) -> (String, Data)? {
        guard blob.count >= 32, blob.count % 16 == 0 else { return nil }
        let iv = [UInt8](blob.prefix(16))
        let body = [UInt8](blob.dropFirst(16))
        // The last plaintext block carries the PKCS#7 padding. In CBC, that
        // block decrypts with the *previous ciphertext block* as the chaining
        // value, not the IV — so the filter needs the final two ciphertext
        // blocks, and the first of them as the starting chain. Two AES blocks
        // instead of the whole blob.
        guard body.count >= 32 else { return nil }
        let lastBlock = [UInt8](body[(body.count - 16)...])
        let chainForLast = [UInt8](body[(body.count - 32)..<(body.count - 16)])

        for i in range {
            let npid = String(format: "NPWR%05d_00", i)
            guard let key = contentKey(for: npid) else { continue }

            // Stage 1: decrypt just the last block and validate the padding.
            // A wrong key yields a random byte, so this passes ~1 time in 16.
            guard let last = Crypto.aesCBCDecryptWithChaining(
                    key: key, iv: chainForLast, data: lastBlock),
                  let pad = last.last, (1...16).contains(Int(pad)) else { continue }
            // Only the padding inside the last block can be checked here; a
            // longer run reaches back further, so let the full check decide.
            let padCount = min(Int(pad), 16)
            guard (0..<padCount).allSatisfy({ last[last.count - 1 - $0] == pad }) else { continue }

            // Stage 2: the real check, on the few survivors.
            if let plain = decryptBody(contentKey: key, iv: iv, body: body),
               let xml = validate(plain) {
                return (npid, xml)
            }
        }
        return nil
    }

    /// AES primitives live in `Crypto`.
    static func aesECBEncrypt(key: [UInt8], block: [UInt8]) -> [UInt8]? {
        Crypto.aesECBEncrypt(key: key, block: block)
    }

    static func aesCBCDecrypt(key: [UInt8], iv: [UInt8], data: [UInt8]) -> [UInt8]? {
        Crypto.aesCBCDecrypt(key: key, iv: iv, data: data)
    }
}

// MARK: - Trophy XML

struct Trophy: Identifiable {
    let id: String
    let name: String
    let detail: String
    let type: String
    let hidden: Bool

    /// Localisation key for the grade label, or nil when the grade is unknown
    /// and the raw `type` should be shown instead.
    ///
    /// `S` is platinum in the PS5 UCP schema and silver in the PS4 .trp XML,
    /// which is why the two are distinguished by which field the value came
    /// from; `P` only ever appears in the reduced UCP schema.
    var gradeKey: String? {
        switch type.uppercased() {
        case "P": return "trophy.grade.platinum"
        case "S": return "trophy.grade.platinum"
        case "G": return "trophy.grade.gold"
        case "SILVER": return "trophy.grade.silver"
        case "B": return "trophy.grade.bronze"
        default: return nil
        }
    }

    /// True when the pack did not record a grade (PS5 `.ucp` metadata).
    var gradeUnknown: Bool { type.isEmpty }

    /// Localised grade text. Falls back to the raw type, then an em dash.
    func gradeText(_ t: (String) -> String) -> String {
        if let k = gradeKey { return t(k) }
        return type.isEmpty ? t("trophy.grade.unknown") : type
    }
}

enum TrophyXML {
    /// TROP.SFM XML -> trophy list. Uses XMLParser; never throws.
    static func parse(_ data: Data) -> [Trophy] {
        final class Current {
            var id = "?"
            var name = ""
            var detail = ""
            var type = "?"
            var hidden = false
        }
        final class Delegate: NSObject, XMLParserDelegate {
            var out: [Trophy] = []
            var cur: Current?
            var text = ""

            func parser(_ parser: XMLParser, didStartElement name: String,
                        namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
                text = ""
                guard name == "trophy" else { return }
                let c = Current()
                c.id = attributes["id"] ?? "?"
                c.type = (attributes["ttype"] ?? "?").uppercased()
                c.hidden = (attributes["hidden"] ?? "").lowercased() == "yes"
                cur = c
            }

            func parser(_ parser: XMLParser, foundCharacters s: String) { text += s }

            func parser(_ parser: XMLParser, didEndElement name: String,
                        namespaceURI: String?, qualifiedName: String?) {
                guard let c = cur else { return }
                if name == "trophy" {
                    out.append(Trophy(id: c.id, name: c.name, detail: c.detail,
                                      type: c.type, hidden: c.hidden))
                    cur = nil
                } else if name == "name" {
                    c.name = text.trimmingCharacters(in: .whitespacesAndNewlines)
                } else if name == "detail" {
                    c.detail = text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        let d = Delegate()
        let p = XMLParser(data: data)
        p.delegate = d
        guard p.parse() else { return d.out }
        return d.out
    }

    /// The `<npcommid>` a PS3 document declares, e.g. `NPWR08388_00`.
    ///
    /// PS4 `.trp` blobs are encrypted and carry no readable id; PS3 ones are
    /// plain, so this is the authoritative value there.
    static func npcommid(in data: Data) -> String {
        element(named: "npcommid", in: data)
    }

    /// The `<title-name>` a PS3 document declares.
    static func titleName(in data: Data) -> String? {
        let v = element(named: "title-name", in: data)
        return v.isEmpty ? nil : v
    }

    /// Text of the first `<name>`-style element, without a full XML parse.
    private static func element(named tag: String, in data: Data) -> String {
        guard let r = data.range(of: Data("<\(tag)>".utf8)) else { return "" }
        let rest = data[r.upperBound...]
        guard let end = rest.range(of: Data("</\(tag)>".utf8)) else { return "" }
        return String(decoding: rest[..<end.lowerBound], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - PNG carving

enum PNGCarve {
    struct Carved {
        let offset: Int
        let size: Int
        let width: Int
        let height: Int
    }

    /// Trophy icons and banners are not in the TRP entry table — they are found
    /// by scanning for PNG magics and reading dimensions from the IHDR.
    static func carve(_ data: Data) -> [Carved] {
        let sig: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let bytes = [UInt8](data)
        var out: [Carved] = []
        var i = 0
        while i + 8 <= bytes.count {
            guard bytes[i..<(i + 8)].elementsEqual(sig) else { i += 1; continue }
            // IHDR must follow immediately.
            guard i + 33 <= bytes.count,
                  bytes[i + 12] == 0x49, bytes[i + 13] == 0x48, bytes[i + 14] == 0x44, bytes[i + 15] == 0x52 else {
                i += 8; continue
            }
            let w = Int(bytes[i + 16]) << 24 | Int(bytes[i + 17]) << 16 | Int(bytes[i + 18]) << 8 | Int(bytes[i + 19])
            let h = Int(bytes[i + 20]) << 24 | Int(bytes[i + 21]) << 16 | Int(bytes[i + 22]) << 8 | Int(bytes[i + 23])
            guard w > 0, w <= 8192, h > 0, h <= 8192 else { i += 8; continue }
            // Walk the chunk list to find IEND for the exact length.
            var p = i + 8
            var end = data.count
            while p + 8 <= data.count {
                let clen = Int(bytes[p]) << 24 | Int(bytes[p + 1]) << 16 | Int(bytes[p + 2]) << 8 | Int(bytes[p + 3])
                let type = String(bytes: bytes[(p + 4)..<(p + 8)], encoding: .ascii) ?? ""
                p += 8 + clen + 4
                if type == "IEND" { end = p; break }
                if clen < 0 || p > data.count { break }
            }
            if end <= i || end > data.count { i += 8; continue }
            out.append(Carved(offset: i, size: end - i, width: w, height: h))
            i = end
        }
        return out
    }
}
