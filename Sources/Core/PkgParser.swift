import Foundation

/// CNT (PS4/PS5) container table entries: 8 big-endian u32 per record.
struct CntEntry {
    var id: UInt32
    var nameOff: UInt32
    var off: UInt64
    var size: UInt64
    var name: String = ""
    /// Offset relative to the start of the whole file (container base + off).
    var absOff: UInt64 = 0

    var isDirectory: Bool { (id & 0x8000_0000) != 0 }
}

enum PkgFormat {
    static let fihMagic: [UInt8] = [0x7F, 0x46, 0x49, 0x48]  // \x7FFIH
    static let cntMagic: [UInt8] = [0x7F, 0x43, 0x4E, 0x54]  // \x7FCNT
    /// PS3 NPDRM packages are `\x7FPKG` — the letter K, not N. This was
    /// previously `\x7FPNG`, which matched no real file and sent every PS3
    /// package down the "unrecognised magic" path.
    static let ps3Magic: [UInt8] = [0x7F, 0x50, 0x4B, 0x47]  // \x7FPKG
}

/// Random-access byte source over a file on disk. Keeps the handle open and
/// seeks per read, matching the Python implementation's behaviour and keeping
/// memory flat for multi-GB PKGs.
final class FileHandleReader: @unchecked Sendable {
    let url: URL
    let fileSize: Int64
    private let handle: FileHandle?
    private let posix: UnsafeMutablePointer<FILE>?

    init?(url: URL) {
        self.url = url
        guard let h = FileHandle(forReadingAtPath: url.path) else { return nil }
        self.handle = h
        self.posix = nil
        var st = stat()
        fileSize = stat(url.path, &st) == 0 ? Int64(st.st_size) : 0
        try? h.seek(toOffset: 0)
    }

    private init?(fd: UnsafeMutablePointer<FILE>, size: Int64, url: URL) {
        self.url = url
        self.handle = nil
        self.posix = fd
        self.fileSize = size
    }

    /// Open a read-only POSIX handle — used for exFAT images opened via a
    /// descriptor rather than a path.
    convenience init?(fileDescriptor: Int32, url: URL) {
        guard let fp = fdopen(fileDescriptor, "rb") else { return nil }
        var st = stat()
        let size = fstat(fileDescriptor, &st) == 0 ? Int64(st.st_size) : 0
        self.init(fd: fp, size: size, url: url)
    }

    deinit { close() }

    static func == (l: FileHandleReader, r: FileHandleReader) -> Bool { l === r }
    func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(self)) }

    func close() {
        if let h = handle { try? h.close() }
        if let fp = posix { fclose(fp) }
    }

    func read(at offset: UInt64, count: Int) -> Data? {
        guard count >= 0, offset <= UInt64(fileSize) else { return nil }
        let end = offset + UInt64(count)
        if end > UInt64(fileSize) { return nil }
        if let h = handle {
            do {
                try h.seek(toOffset: offset)
                let d = try h.read(upToCount: count) ?? Data()
                return d.count == count ? d : nil
            } catch { return nil }
        }
        if let fp = posix {
            guard fseeko(fp, off_t(offset), SEEK_SET) == 0 else { return nil }
            var buf = [UInt8](repeating: 0, count: count)
            let n = fread(&buf, 1, count, fp)
            return n == count ? Data(buf) : nil
        }
        return nil
    }
}

enum PkgParser {

    /// Detect the container flavour from the first bytes.
    static func detect(_ magic: Data) -> PkgFormat2 {
        let b = [UInt8](magic)
        if b.count >= 4 {
            let head = Array(b[0..<4])
            if head == PkgFormat.fihMagic { return .fih }
            if head == PkgFormat.cntMagic { return .cnt }
            if head == PkgFormat.ps3Magic { return .ps3 }
            if head == UCP.magic { return .ucp }
        }
        if b.count >= 11, Array(b[3..<11]) == Array("EXFAT   ".utf8) { return .exfat }
        return .unknown
    }

    enum PkgFormat2 { case fih, cnt, ps3, exfat, ucp, unknown }

    // MARK: Entry tables

    static func parseCntEntries(_ reader: FileHandleReader, base: UInt64, count: Int, tableOff: UInt64) -> [CntEntry] {
        guard count > 0, count < 1_000_000, let raw = reader.read(at: base &+ tableOff, count: count * 32) else { return [] }
        let r = ByteReader(raw)
        var out: [CntEntry] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let o = i * 32
            guard let id = r.u32be(at: o), let nameOff = r.u32be(at: o + 4),
                  let off = r.u32be(at: o + 16), let size = r.u32be(at: o + 20) else { continue }
            out.append(CntEntry(id: id, nameOff: nameOff, off: UInt64(off), size: UInt64(size)))
        }
        return out
    }

    /// The name table is the entry with id 512.
    static func readNameTable(_ reader: FileHandleReader, base: UInt64, _ ents: [CntEntry]) -> Data {
        guard let nt = ents.first(where: { $0.id == 512 }) else { return Data() }
        return reader.read(at: base &+ nt.off, count: Int(nt.size)) ?? Data()
    }

    static func entryName(_ nt: Data, off: UInt32) -> String {
        guard nt.count >= Int(off) else { return "" }
        let tail = nt[Int(off)...]
        guard let end = tail.firstIndex(of: 0) else { return "" }
        return String(decoding: tail[tail.startIndex..<end], as: UTF8.self)
    }

    // MARK: PS5 FIH

    /// PS5 retail/dump PKG: FIH header wrapping a CNT container.
    static func parseFIH(_ reader: FileHandleReader, size: Int64) -> PkgResult {
        guard let hdr = reader.read(at: 0, count: 256) else {
            return PkgResult(kind: "ps5", path: reader.url, fileSize: size, title: reader.url.lastPathComponent, rows: [], failed: Message("err.cannotReadHeader"))
        }
        let r = ByteReader(hdr)
        let emb = r.u64le(at: 0x58) ?? 0
        let signed = r.u8(at: 5) ?? 0
        let pfsOff = r.u64le(at: 0x10) ?? 0
        let pfsSize = r.u64le(at: 0x18) ?? 0

        guard let chdr = reader.read(at: emb, count: 0x80),
              let cr = ByteReader(chdr).u32be(at: 0x10),
              let et = ByteReader(chdr).u32be(at: 0x18) else {
            return PkgResult(kind: "ps5", path: reader.url, fileSize: size, title: reader.url.lastPathComponent,
                             rows: [], failed: Message("err.noCNT"))
        }
        let n = Int(cr)
        let cid = ByteReader(chdr).fixedString(at: 0x40, length: 48) ?? ""
        var ents = parseCntEntries(reader, base: emb, count: n, tableOff: UInt64(et))
        let nt = readNameTable(reader, base: emb, ents)
        for i in ents.indices {
            ents[i].name = nt.isEmpty ? "" : entryName(nt, off: ents[i].nameOff)
            ents[i].absOff = emb &+ ents[i].off
        }

        var meta: [String: MetaValue] = [:]
        var title = ""
        var extra: [(String, String)] = []
        if let pj = ents.first(where: { $0.name == "param.json" || $0.id == 8192 }), pj.size > 0, pj.size < 100_000,
           let raw = reader.read(at: emb &+ pj.off, count: Int(pj.size)),
           let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] {
            meta = Dictionary(uniqueKeysWithValues: obj.map { ($0.key, MetaValue.from($0.value)) })
            let t = ParamJSON.meta(from: obj)
            title = t.title
            extra = t.rows
        }

        var rows: [(String, String)] = [
            ("Platform", "PS5 (finalized FIH)"),
            ("Package", signed == 0x80 ? "OFC (Official)" : "FPKG (Fake)"),
            ("Signature", signed == 0x80 ? "official" : "debug"),
            ("Size", Fmt.size(size)),
            ("PFS image", "\(Fmt.size(Int64(pfsSize))) @ \(hex(pfsOff))"),
            ("Entries", String(ents.count)),
        ]
        rows += extra
        if !rows.contains(where: { $0.0 == "Content ID" }) {
            rows.insert(("Content ID", cid), at: 2)
        }

        return PkgResult(
            kind: "ps5", path: reader.url, fileSize: size,
            title: title.isEmpty ? reader.url.lastPathComponent : title,
            rows: rows,
            entries: toEntries(ents),
            meta: meta,
            iconName: "icon0.png",
            patchTid: meta.str("titleId"),
            ownVersion: meta.str("contentVersion")
        )
    }

    // MARK: PS4 CNT

    /// PS4 PKG: bare CNT container (optionally wrapped in a 512-byte body pad).
    static func parseCNT(_ reader: FileHandleReader, size: Int64) -> PkgResult {
        guard let hdr = reader.read(at: 0, count: 0x500) else {
            return PkgResult(kind: "ps4", path: reader.url, fileSize: size, title: reader.url.lastPathComponent, rows: [], failed: Message("err.cannotReadHeader"))
        }
        let r = ByteReader(hdr)
        let n = Int(r.u32be(at: 0x10) ?? 0)
        let sysCount = Int(r.u16be(at: 0x14) ?? 0)
        let et = r.u32be(at: 0x18) ?? 0
        let bodyOff = r.u64be(at: 0x20) ?? 0
        let cid = r.fixedString(at: 0x40, length: 48) ?? ""

        var ents = parseCntEntries(reader, base: 0, count: n, tableOff: UInt64(et))
        let nt = readNameTable(reader, base: 0, ents)
        for i in ents.indices {
            ents[i].name = nt.isEmpty ? "" : entryName(nt, off: ents[i].nameOff)
            ents[i].absOff = ents[i].off
        }

        var sfo: [String: MetaValue] = [:]
        if let sfoEnt = ents.first(where: { $0.id == 4096 || $0.name == "param.sfo" }), sfoEnt.size > 0,
           let raw = reader.read(at: sfoEnt.off, count: Int(sfoEnt.size)) {
            sfo = SFO.parse(raw)
        }

        var meta: [String: MetaValue] = [:]
        var title = ""
        var extra: [(String, String)] = []
        var showVer = ""
        let haveSFO = sfo["_error"] == nil && !sfo.isEmpty

        if haveSFO {
            title = sfo.str("TITLE")
            let cid4 = sfo.firstStr(["CONTENT_ID"]).isEmpty ? cid : sfo.str("CONTENT_ID")
            let cat = sfo.str("CATEGORY")
            // Update PKGs (gp): VERSION is the base it applies to, APP_VER the
            // actual patch version -> show APP_VER.
            showVer = sfo.str("VERSION")
            if cat.lowercased() == "gp" && !sfo.str("APP_VER").isEmpty {
                showVer = sfo.str("APP_VER")
            }
            var langs = 0
            for (k, v) in sfo where (k == "TITLE" || k.hasPrefix("TITLE_")) {
                if !v.displayString.trimmingCharacters(in: .whitespaces).isEmpty { langs += 1 }
            }
            // Build date from PUBTOOLINFO c_date=YYYYMMDD
            var built = "-"
            let info = sfo.str("PUBTOOLINFO")
            if let r = info.range(of: #"c_date=(\d{4})(\d{2})(\d{2})"#, options: .regularExpression) {
                built = String(info[r]).replacingOccurrences(of: "c_date=", with: "")
                    .replacingOccurrences(of: "(\\d{4})(\\d{2})(\\d{2})", with: "$1-$2-$3", options: .regularExpression)
            }
            extra.append(("Title ID", sfo.str("TITLE_ID")))
            extra.append(("Content ID", cid4))
            extra.append(("Region", Meta.contentRegion(cid4)))
            extra.append(("Type", Meta.ps4PkgType(cat)))
            extra.append(("Version", showVer))
            if cat.lowercased() == "gp" && !sfo.str("VERSION").isEmpty {
                extra.append(("Base Version", sfo.str("VERSION")))
            }
            extra.append(("Min. System", sfo.str("SYSTEM_VER").isEmpty ? "-" : sfo.str("SYSTEM_VER")))
            extra.append(("Languages", langs > 0 ? String(langs) : "-"))
            extra.append(("Built", built))
            // FPKG hint: which passcode a full extract needs.
            if let pt = r.u32be(at: 0x04), (pt & 0x8000_0000) == 0 {
                extra.append(("Passcode", "zeros (FPKG default)"))
            }
        } else if let pj = ents.first(where: { $0.name == "param.json" || $0.id == 8192 }),
                  pj.size > 0, pj.size < 100_000,
                  let raw = reader.read(at: pj.off, count: Int(pj.size)),
                  let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] {
            meta = Dictionary(uniqueKeysWithValues: obj.map { ($0.key, MetaValue.from($0.value)) })
            let t = ParamJSON.meta(from: obj)
            title = t.title
            extra = t.rows
        }

        let kind = haveSFO ? "PS4" : "CNT"
        var rows: [(String, String)] = [
            ("Platform", "\(kind) (CNT metadata)"),
            ("Package", Meta.cntPackageType(hdr)),
            ("Size", Fmt.size(size)),
            ("Entries", "\(n) (\(sysCount) sys)"),
        ]
        rows += extra
        if !rows.contains(where: { $0.0 == "Content ID" }) {
            rows.insert(("Content ID", haveSFO ? sfo.str("CONTENT_ID") : cid), at: 2)
        }

        return PkgResult(
            kind: "ps4", path: reader.url, fileSize: size,
            title: title.isEmpty ? reader.url.lastPathComponent : title,
            rows: rows,
            entries: toEntries(ents),
            meta: haveSFO ? sfo : meta,
            iconName: "icon0.png",
            patchTid: sfo.str("TITLE_ID"),
            ownVersion: haveSFO ? showVer : "",
            bodyOffset: bodyOff
        )
    }

    // MARK: Helpers

    static func toEntries(_ ents: [CntEntry]) -> [PkgEntry] {
        ents.filter { !$0.isDirectory }.enumerated().map { (i, e) in
            let name = e.name.isEmpty ? "entry_\(e.id)" : e.name
            return PkgEntry(id: i, name: name, size: Int64(e.size),
                            source: .offset(e.absOff),
                            isTrophyPack: isTrophyPackName(name))
        }
    }

    /// A trophy archive is a .trp/.ucp that is not a user-data pack.
    /// PS5 dumps ship both `trophy2/trophy00.ucp` and `uds/uds00.ucp`.
    static func isTrophyPackName(_ name: String) -> Bool {
        let n = name.lowercased()
        guard n.hasSuffix(".trp") || n.hasSuffix(".ucp") else { return false }
        return !n.hasPrefix("uds")
    }

    static func hex(_ v: UInt64) -> String { "0x" + String(v, radix: 16) }
}
