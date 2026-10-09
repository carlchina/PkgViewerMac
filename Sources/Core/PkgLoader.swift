import Foundation

/// Format dispatch + cover-art / file extraction. Mirrors parse_pkg() in the
/// Python original, minus the formats that need third-party binaries
/// (ffpfsc needs mkpfs, ffpkg needs pytsk3) which now report a clear message.
enum PkgLoader {

    static let supportedExtensions = ["pkg", "exfat", "ffpfsc", "ffpkg", "nsp", "xci"]

    static func load(url: URL) -> PkgResult {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return failure(url, Message("err.notFound"))
        }
        if isDir.boolValue {
            // Downloads on exFAT often store a package as a *directory* holding
            // one file of the same name (the filesystem cannot hold both a file
            // and a directory with identical names). Parsing the wrapper yields
            // an empty PS5 app folder, so step into it and read the real file.
            if let inner = unwrapSingleFileDirectory(url) {
                return load(url: inner)
            }
            return parseFolder(url)
        }
        let size = fileSize(url)
        let ext = url.pathExtension.lowercased()

        if ext == "ffpfsc" {
            return failure(url, Message("err.ffpfscUnsupported"))
        }
        if ext == "ffpkg" {
            return failure(url, Message("err.ffpkgUnsupported"))
        }
        // A bare trophy archive, as pulled out of a package by a dumper.
        if ext == "ucp" || ext == "trp" {
            return parseTrophyContainer(url, reader: nil, size: size)
        }

        guard let reader = FileHandleReader(url: url) else { return failure(url, Message("err.cannotOpen")) }
        defer { reader.close() }
        guard let magic = reader.read(at: 0, count: 16) else { return failure(url, Message("err.cannotRead")) }

        // Nintendo Switch, detected from bytes rather than the extension so a
        // renamed dump still opens. An NSP is a PFS0 container at offset 0; an
        // XCI keeps its magic at 0x100 and starts with a padding block.
        if magic.prefix(4) == Switch.pfs0Magic {
            let res = Switch.parseNSP(url, reader, size: size)
            // A real NSZ keeps a PFS0 header, but its file table points into
            // compressed NCZ blocks, so the table does not add up. Report the
            // actual cause instead of blaming the container — "not a valid
            // NSP" sends you looking for a corrupt file that is fine.
            if res.failed != nil, ["nsz", "xcz"].contains(ext) {
                return failure(url, Message("err.badNsz"))
            }
            return res
        }
        if let at100 = reader.read(at: 0x100, count: 4), at100 == Switch.xciMagic {
            return Switch.parseXCI(url, reader, size: size)
        }

        switch PkgParser.detect(magic) {
        case .fih:  return PkgParser.parseFIH(reader, size: size)
        case .lih:  return PkgParser.parseLIH(reader, size: size)
        case .cnt:  return PkgParser.parseCNT(reader, size: size)
        case .ps3:  return PkgParser.parsePS3(reader, size: size)
        case .exfat: return parseExfat(reader, size: size)
        case .ucp:   return parseTrophyContainer(url, reader: reader, size: size)
        case .unknown:
            // Split retail part with no header: resolve via sibling _0.
            if let stub = splitPartStub(url, size: size) { return stub }
            let m = magic.prefix(4).map { String(format: "%02x", $0) }.joined(separator: " ")
            return failure(url, Message("err.unknownMagic", m))
        }
    }

    /// A standalone `.ucp` / `.trp` trophy archive, with no surrounding PKG.
    static func parseTrophyContainer(_ url: URL, reader: FileHandleReader?, size: Int64) -> PkgResult {
        let r = reader ?? FileHandleReader(url: url)
        guard let handle = r else { return failure(url, Message("err.cannotOpen")) }
        defer { if reader == nil { handle.close() } }

        // Memory-map the whole archive instead of copying it into a fresh
        // buffer. A trophy pack's bulk is PNG icons, and UCP.read only subdata's
        // the members it wants (tropmeta/tropconf/PNGs), so a >64MB archive is
        // read on demand rather than all at once. The old cap silently turned
        // any larger pack into an empty Data() and the trophy list came back
        // empty with no error.
        let blob: Data
        do {
            blob = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            return failure(url, Message("err.cannotRead"))
        }

        let isTRP = url.pathExtension.lowercased() == "trp"
        // The system language decides which tropmeta file is read. A pinned UI
        // language is applied by the view model, which re-reads on change.
        let wants = TrophyLanguage.preference(for: Locale.preferredLanguages)
        let c = UCP.read(blob, wanted: isTRP ? ["en-US"] : wants)
        let trophies = isTRP ? [] : c.trophies
        let title = c.title.isEmpty ? url.deletingPathExtension().lastPathComponent : c.title

        var rows: [(String, String)] = [("Container", isTRP ? "TRP" : "UCP")]
        if !c.npcommid.isEmpty { rows.append(("NPCommID", c.npcommid)) }
        if let tag = c.localeTag { rows.append(("Language", tag)) }
        rows.append(("Trophies", "\(trophies.count)"))
        rows.append(("Icons", "\(c.icons.count)"))
        rows.append(("Source", url.lastPathComponent))

        return PkgResult(kind: isTRP ? "TRP" : "UCP", path: url, fileSize: size,
                         title: title, rows: rows,
                         entries: [PkgEntry(id: 0, name: url.lastPathComponent,
                                            size: size, source: .file(url),
                                            codec: nil, isTrophyPack: true)],
                         meta: [:])
    }

    static func failure(_ url: URL, _ msg: Message) -> PkgResult {
        PkgResult(kind: "unknown", path: url, fileSize: 0,
                  title: url.lastPathComponent, rows: [], failed: msg)
    }

    // MARK: exFAT wrapper directories

    /// A directory that exists only to hold one same-named file, as exFAT
    /// dumps of PS3 packages often are. Returns that file, or nil when the
    /// directory is a real game/app folder.
    ///
    /// The guards are deliberately strict. A genuine PS5 app folder holds
    /// `sce_sys/param.json`, and a PS3 extract holds `PS3_GAME/`, `USRDIR/`
    /// or `PARAM.SFO` — none of those may be mistaken for a wrapper. Anything
    /// with several files, or with a subdirectory, is left alone.
    static func unwrapSingleFileDirectory(_ dir: URL) -> URL? {
        let fm = FileManager.default
        // A real game folder is identified by its own layout, not by its name.
        if fm.fileExists(atPath: dir.appendingPathComponent("sce_sys").path)
            || PS3.folderBase(dir.path) != nil {
            return nil
        }
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return nil }
        // AppleDouble `._name` sidecars are metadata, not content.
        let real = names.filter { !$0.hasPrefix("._") && $0 != ".DS_Store" }
        guard real.count == 1 else { return nil }
        let inner = dir.appendingPathComponent(real[0])
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: inner.path, isDirectory: &isDir), !isDir.boolValue else {
            return nil
        }
        return inner
    }

    // MARK: exFAT images

    static func parseExfat(_ reader: FileHandleReader, size: Int64) -> PkgResult {
        guard let fs = try? ExfatImage(reader: reader) else {
            return failure(reader.url, Message("err.badExfat"))
        }
        return exfatResult(fs, url: reader.url, size: size, platform: "PS5 exFAT image", innerName: nil)
    }

    static func exfatResult(_ fs: ExfatImage, url: URL, size: Int64, platform: String, innerName: String?) -> PkgResult {
        var meta: [String: MetaValue] = [:]
        var title = ""
        var extra: [(String, String)] = []

        if let pj = fs.find(["sce_sys", "param.json"]), !pj.isDir, pj.size < 100_000, pj.size > 0 {
            let raw = pj.noFat
                ? (fs.reader.read(at: fs.clusterOffset(pj.first), count: Int(pj.size)) ?? Data())
                : fs.readChain(first: pj.first, size: Int(pj.size))
            if let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] {
                meta = Dictionary(uniqueKeysWithValues: obj.map { ($0.key, MetaValue.from($0.value)) })
                let t = ParamJSON.meta(from: obj)
                title = t.title
                extra = t.rows
            } else if let s = String(data: raw, encoding: .utf8), !s.isEmpty {
                meta = ["_error": .string("bad param.json")]
            }
        }

        var entries: [PkgEntry] = []
        var eid = 0
        if let icon = fs.find(["sce_sys", "icon0.png"]), !icon.isDir, icon.size > 0 {
            entries.append(PkgEntry(id: eid, name: "icon0.png", size: Int64(icon.size),
                                    source: .exfat(first: icon.first, size: icon.size, noFat: icon.noFat),
                                    isTrophyPack: false))
            eid += 1
        }
        var seen: Set<String> = ["icon0.png"]
        for it in fs.listPath(["sce_sys"]) {
            let nm = it.name
            if it.isDir || seen.contains(nm) || !nm.lowercased().hasSuffix(".png") { continue }
            if it.size == 0 || it.size > 32_000_000 { continue }
            seen.insert(nm)
            entries.append(PkgEntry(id: eid, name: nm, size: Int64(it.size),
                                    source: .exfat(first: it.first, size: it.size, noFat: it.noFat),
                                    isTrophyPack: false))
            eid += 1
        }
        for (rel, first, sz, noFat) in fs.scanTrophyPacks() {
            entries.append(PkgEntry(id: eid, name: rel, size: Int64(sz),
                                    source: .exfat(first: first, size: sz, noFat: noFat),
                                    isTrophyPack: true))
            eid += 1
        }

        var rows: [(String, String)] = [("Platform", platform), ("Size", Fmt.size(size))]
        if let inner = innerName { rows.append(("Inner file", inner)) }
        rows += extra

        return PkgResult(kind: "ps5", path: url, fileSize: size,
                         title: title.isEmpty ? url.lastPathComponent : title,
                         rows: rows, entries: entries, meta: meta, iconName: "icon0.png")
    }

    // MARK: App / game folders

    static func parseFolder(_ url: URL) -> PkgResult {
        let sceSys = url.appendingPathComponent("sce_sys")
        var meta: [String: MetaValue] = [:]
        var title = ""
        var extra: [(String, String)] = []
        let pj = sceSys.appendingPathComponent("param.json")
        if let data = try? Data(contentsOf: pj),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            meta = Dictionary(uniqueKeysWithValues: obj.map { ($0.key, MetaValue.from($0.value)) })
            let t = ParamJSON.meta(from: obj)
            title = t.title
            extra = t.rows
        }

        let (total, nFiles) = folderStats(url)
        var rows: [(String, String)] = [
            ("Platform", "PS5 app folder"),
            ("Size", "\(Fmt.size(total)) (\(nFiles) files)"),
        ]
        let ampr = scanAMPR(url)
        if !ampr.isEmpty {
            let lz4 = ampr.filter { $0.codec == "LZ4" }.count
            let hc = ampr.filter { $0.codec == "LZ4HC" }.count
            var label = "\(ampr.count) AMPR containers (\(Fmt.size(ampr.reduce(0) { $0 + $1.size })))"
            var codecs: [String] = []
            if lz4 > 0 { codecs.append(lz4 > 1 ? "LZ4 x\(lz4)" : "LZ4") }
            if hc > 0 { codecs.append(hc > 1 ? "LZ4HC x\(hc)" : "LZ4HC") }
            if !codecs.isEmpty { label += " · " + codecs.joined(separator: " · ") }
            rows.append(("Assets", label))
        }
        rows += extra

        var entries: [PkgEntry] = []
        var eid = 0
        let icon = sceSys.appendingPathComponent("icon0.png")
        if fmExists(icon) {
            entries.append(PkgEntry(id: eid, name: "icon0.png", size: fileSize(icon),
                                    source: .file(icon), isTrophyPack: false))
            eid += 1
        }
        if let names = try? FileManager.default.contentsOfDirectory(atPath: sceSys.path) {
            for nm in names.sorted() where nm != "icon0.png" && nm.lowercased().hasSuffix(".png") {
                let fp = sceSys.appendingPathComponent(nm)
                var isDir: ObjCBool = false
                guard fmExists(fp), (fmIsDir(fp, &isDir) ? false : true) else { continue }
                let sz = fileSize(fp)
                if sz <= 0 { continue }
                entries.append(PkgEntry(id: eid, name: nm, size: sz, source: .file(fp), isTrophyPack: false))
                eid += 1
            }
        }
        for (rel, url) in walkTrophyPacks(url) {
            let sz = fileSize(url)
            if sz <= 0 || sz >= 300_000_000 { continue }
            entries.append(PkgEntry(id: eid, name: rel, size: sz, source: .file(url), isTrophyPack: true))
            eid += 1
        }
        for (nm, sz, _, codec) in ampr {
            let display = codec.isEmpty ? nm : "\(nm)  [\(codec)]"
            entries.append(PkgEntry(id: eid, name: display, size: sz,
                                    source: .file(url.appendingPathComponent(nm)),
                                    codec: codec.isEmpty ? nil : codec, isTrophyPack: false))
            eid += 1
        }

        return PkgResult(kind: "ps5", path: url, fileSize: total,
                         title: title.isEmpty ? url.lastPathComponent : title,
                         rows: rows, entries: entries, meta: meta, iconName: "icon0.png")
    }

    // MARK: AMPR / LZ4 asset containers

    static let amprMagics: Set<String> = ["AMPRPAK4", "AMPRDAT3", "AMPRIDX3", "AMPRCRC1", "AMPRCFG1"]

    static func scanAMPR(_ root: URL) -> [(name: String, size: Int64, magic: String, codec: String)] {
        var out: [(String, String, Int64, String)] = []
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                          options: [.skipsHiddenFiles]) else { return [] }
        let unityMarkers: Set<Data> = [
            Data("UnityFS\0".utf8), Data("2022.3.57f1".utf8), Data("CAB-".utf8),
            Data("AssetBundle".utf8), Data(".resS".utf8), Data("globalgamemanagers".utf8),
        ]
        for case let f as URL in walker {
            let nm = f.lastPathComponent
            guard let head = try? Data(contentsOf: f, options: .mappedIfSafe).prefix(8),
                  head.count >= 8 else { continue }
            let magic = String(decoding: head.prefix(8), as: UTF8.self)
            guard amprMagics.contains(magic) else { continue }
            // Probe a UnityFS header inside to identify the codec.
            var codec = ""
            if let data = try? Data(contentsOf: f, options: .mappedIfSafe) {
                codec = unityCodec(in: data, markers: unityMarkers)
            }
            out.append((nm, magic, fileSize(f), codec))
            if out.count > 400 { break }
        }
        return out.map { (name: $0.0, size: $0.2, magic: $0.1, codec: $0.3) }
    }
    private static let unityComp: [Int: String] = [0: "raw", 1: "LZMA", 2: "LZ4", 3: "LZ4HC"]

    /// Look for a UnityFS header and read its compression flag.
    private static func unityCodec(in buf: Data, markers: Set<Data>) -> String {
        let sig = Data("UnityFS\0".utf8)
        var found: Int?
        if let r = buf.range(of: sig) {
            found = r.upperBound
        } else {
            for m in markers where m.count >= 4 {
                if let r = buf.range(of: m) { found = r.upperBound; break }
            }
        }
        guard var pos = found else { return "" }
        // UnityFS: sig(8) version(4) cver(4) ... we need the block-info
        // compression byte, which sits past the header strings; scan forward a
        // bounded window for a plausible small integer in 0...3.
        let limit = min(buf.count, pos + 512)
        let r = ByteReader(buf)
        while pos + 1 <= limit {
            guard let v = r.u32be(at: pos) else { break }
            if v <= 3, let name = unityComp[Int(v)], name != "raw" {
                return name
            }
            pos += 1
        }
        return ""
    }

    // MARK: Split sets

    /// A `game_1.pkg` with no parseable header: retry against sibling `game_0.pkg`.
    static func splitPartStub(_ url: URL, size: Int64) -> PkgResult? {
        let sibs = splitSiblings(url)
        guard sibs.count > 1, sibs[0].lastPathComponent != url.lastPathComponent else { return nil }
        return load(url: sibs[0])
    }

    /// All parts of a split set (`game_0.pkg`, `game_1.pkg`, …) or just [url].
    static func splitSiblings(_ url: URL) -> [URL] {
        let fm = FileManager.default
        guard url.pathExtension.lowercased() == "pkg" else { return [url] }
        let stem = url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent()
        // Only the `_N` convention marks a split set.
        guard let t = stem.lastIndex(of: "_") else { return [url] }
        let suffix = stem[stem.index(after: t)...]
        guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber),
              let n = Int(suffix), n >= 0, n < 64 else { return [url] }
        let base = String(stem[stem.startIndex..<t])
        var out: [URL] = []
        for i in 0..<64 {
            let cand = dir.appendingPathComponent("\(base)_\(i).pkg")
            guard fm.fileExists(atPath: cand.path) else { break }
            out.append(cand)
        }
        return out.isEmpty ? [url] : out
    }

    // MARK: File reading

    /// One open handle per PS3 package, shared by every entry read from it.
    ///
    /// Entry sources name the package by path, so without this each of the
    /// hundred-odd reads in a listing would reopen the file. Keyed by path and
    /// never evicted — a result is replaced wholesale on the next open, and
    /// the OS reclaims the descriptors when the process exits.
    private static let ps3Handles = NSLockBox<[String: FileHandleReader]>([:])

    private static func ps3Reader(_ url: URL) -> FileHandleReader? {
        let key = url.path
        return ps3Handles.withLock { store in
            if let existing = store[key] { return existing }
            guard let fresh = FileHandleReader(url: url) else { return nil }
            store[key] = fresh
            return fresh
        }
    }

    /// Read the bytes of an entry, regardless of where it lives.
    /// `reader` is required for offset-sourced entries (plain PKG files).
    static func readEntry(_ e: PkgEntry, reader: FileHandleReader?) -> Data? {
        switch e.source {
        case .offset(let off):
            guard let reader = reader else { return nil }
            return reader.read(at: off, count: Int(e.size))
        case .file(let u):
            return try? Data(contentsOf: u, options: .mappedIfSafe)
        case .ps3(let url, let dataOff, let retail, let keymat, let fileOff):
            guard let r = ps3Reader(url) else { return nil }
            return PS3.decrypt(r, dataOff: dataOff, retail: retail,
                               keymat: keymat, pos: Int(fileOff), size: Int(e.size))
        case .cached(let d):
            return d
        case .exfat:
            return nil  // needs the live image; handled by readExfatEntry
        }
    }

    /// Read an entry that lives inside an exFAT image. `fs` must be the open image.
    static func readExfatEntry(_ e: PkgEntry, fs: ExfatImage) -> Data? {
        guard case .exfat(let first, let size, let noFat) = e.source else { return nil }
        if noFat {
            return fs.reader.read(at: fs.clusterOffset(first), count: Int(size))
        }
        return fs.readChain(first: first, size: Int(size))
    }

    // MARK: Clean naming

    /// `Title - TID - vVersion - Region`, dropping empty parts.
    static func buildCleanName(_ result: PkgResult, parts: (title: Bool, tid: Bool, ver: Bool, region: Bool)? = nil) -> String {
        let on = parts ?? (true, true, true, true)
        let rd = result.rowDict
        let title = result.title.trimmingCharacters(in: .whitespaces)
        let tid = (rd["Title ID"] ?? "").trimmingCharacters(in: .whitespaces)
        var ver = (rd["Version"] ?? rd["Content Ver"] ?? "").trimmingCharacters(in: .whitespaces)
        if ver.lowercased().hasPrefix("v") { ver.removeFirst() }
        ver = Fmt.normalizeVersion(ver)
        var region = (rd["Region"] ?? "").trimmingCharacters(in: .whitespaces)
        if let s = Meta.regionShort[region] { region = s }

        var out: [String] = []
        if !title.isEmpty && on.title { out.append(title) }
        if !tid.isEmpty && tid != title && on.tid { out.append(tid) }
        if !ver.isEmpty && ver != "-" && on.ver { out.append("v" + ver) }
        if !region.isEmpty && region != "-" && on.region { out.append(region) }
        // Non-base packages get a suffix so a base game and its update of the
        // same version do not collide on one filename.
        let ptype = (rd["Type"] ?? "").trimmingCharacters(in: .whitespaces)
        if ptype.lowercased() == "update" || ptype.lowercased() == "dlc" { out.append(ptype) }
        guard !out.isEmpty else { return "" }
        return Fmt.sanitizeFilenamePart(out.joined(separator: " - "))
    }

    /// LMAN-style one-line summary: `Type (Fake) (EU) - v1.06 - System 2.50`.
    static func summaryLine(_ result: PkgResult) -> String {
        let rd = result.rowDict
        var typ = (rd["Type"] ?? "").trimmingCharacters(in: .whitespaces)
        let pkg = (rd["Package"] ?? rd["Signature"] ?? "")
        if typ.isEmpty { typ = pkg }
        let base = typ.components(separatedBy: "(").first?.trimmingCharacters(in: .whitespaces) ?? typ
        var fake = ""
        let pl = pkg.lowercased()
        if pl.contains("fake") || pl.contains("fpkg") { fake = " (Fake)" }
        else if pl.contains("official") || pl.hasPrefix("ofc") { fake = " (Official)" }
        let region = (rd["Region"] ?? "").trimmingCharacters(in: .whitespaces)
        let short = Meta.regionShort[region] ?? (region.count >= 2 ? String(region.prefix(2)).uppercased() : "-")
        var ver = (rd["Version"] ?? rd["Content Ver"] ?? "-").trimmingCharacters(in: .whitespaces)
        if ver.isEmpty { ver = "-" }
        if ver != "-", !ver.lowercased().hasPrefix("v") { ver = "v" + ver }
        let sysv = (rd["Min. System"] ?? "").trimmingCharacters(in: .whitespaces)
        var out = "\(base)\(fake) (\(short)) - \(ver)"
        if !sysv.isEmpty && sysv != "-" { out += " - System \(sysv)" }
        return out
    }

    // MARK: Cover art

    /// Ordered cover candidates (entries, not bytes): the declared icon first,
    /// then any other PNG found in the container, capped like `extractCovers`.
    ///
    /// The GUI uses this to build a cover gallery lazily — it reads each entry
    /// on demand rather than pulling every PNG's bytes into memory up front.
    static func coverEntries(_ res: PkgResult, max: Int = 12) -> [PkgEntry] {
        let pngs = res.entries.filter { Self.isImage($0) }
        guard !pngs.isEmpty else { return [] }
        let ordered = pngs.filter { $0.name == res.iconName } + pngs.filter { $0.name != res.iconName }
        return Array(ordered.prefix(max))
    }

    /// True for entries that are cover art: PNG, or JPEG when a Switch NSP
    /// ships its per-language key art that way.
    static func isImage(_ e: PkgEntry) -> Bool {
        guard !e.isTrophyPack else { return false }
        let n = e.name.lowercased()
        return n.hasSuffix(".png") || n.hasSuffix(".jpg") || n.hasSuffix(".jpeg")
    }

    /// PNG or JPEG magic, so a truncated or mis-tagged entry is dropped.
    static func isImageData(_ d: Data) -> Bool {
        if d.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]) { return true }
        return d.prefix(3) == Data([0xFF, 0xD8, 0xFF])
    }

    /// Cover candidates: prefer the declared icon, then any other PNG found in
    /// the container. Runs on the parsing queue, so it takes the open handles
    /// rather than reaching into the view model.
    static func extractCovers(_ res: PkgResult, reader: FileHandleReader?, exfat: ExfatImage?) -> [(name: String, data: Data)] {
        var out: [(String, Data)] = []
        let pngs = res.entries.filter { Self.isImage($0) }
        guard !pngs.isEmpty else { return out }
        let ordered = pngs.filter { $0.name == res.iconName } + pngs.filter { $0.name != res.iconName }
        for e in ordered.prefix(12) {
            let data: Data?
            switch e.source {
            case .exfat: data = exfat.flatMap { readExfatEntry(e, fs: $0) }
            default: data = readEntry(e, reader: reader)
            }
            if let d = data, d.count > 8, Self.isImageData(d) {
                out.append((e.name, d))
            }
            if out.count >= 8 { break }
        }
        return out
    }

    // MARK: Small FS helpers

    private static func fmExists(_ u: URL) -> Bool { FileManager.default.fileExists(atPath: u.path) }
    private static func fmIsDir(_ u: URL, _ flag: inout ObjCBool) -> Bool {
        FileManager.default.fileExists(atPath: u.path, isDirectory: &flag)
    }

    static func fileSize(_ u: URL) -> Int64 {
        let a = try? FileManager.default.attributesOfItem(atPath: u.path)
        return (a?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func folderStats(_ root: URL) -> (Int64, Int) {
        var total: Int64 = 0
        var count = 0
        guard let w = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                                    options: [.skipsHiddenFiles]) else { return (0, 0) }
        for case let f as URL in w {
            let vals = try? f.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if vals?.isRegularFile == true {
                count += 1
                total += Int64(vals?.fileSize ?? 0)
            }
        }
        return (total, count)
    }

    private static func walkTrophyPacks(_ root: URL) -> [(String, URL)] {
        var out: [(String, URL)] = []
        guard let w = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                    options: [.skipsHiddenFiles]) else { return [] }
        for case let f as URL in w {
            let ln = f.lastPathComponent.lowercased()
            guard ln.hasSuffix(".trp") || ln.hasSuffix(".ucp") else { continue }
            let rel = f.path.replacingOccurrences(of: root.path + "/", with: "")
            out.append((rel, f))
        }
        return out
    }
}
