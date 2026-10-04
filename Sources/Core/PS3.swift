import Foundation

// MARK: - PS3 NPDRM

/// PS3 NPDRM package support. Debug packages decrypt with a SHA-1 keystream;
/// retail packages need AES-128-ECB counter-mode with the NPDRM key, which
/// CommonCrypto provides (no Python `cryptography` dependency needed here).
enum PS3 {
    static let magic: [UInt8] = [0x7F, 0x50, 0x4B, 0x47]  // \x7FPKG
    static let key: [UInt8] = [0x2e, 0x7b, 0x71, 0xd7, 0xc9, 0xc9, 0xa1, 0x4e,
                               0xa3, 0x22, 0x1f, 0x18, 0x88, 0x28, 0xb8, 0xf8]

    static let tidRegion: [String: String] = [
        "NPEB": "Europe", "BCES": "Europe", "NPHB": "Asia", "BCAS": "Asia",
        "NPJB": "Japan", "BCJS": "Japan", "NPUB": "Americas", "BCUS": "Americas",
    ]

    /// Root of a PS3 game folder: the dir itself (NPDRM extract) or PS3_GAME/
    /// (disc extract). Empty string = not a PS3 folder.
    static func folderBase(_ path: String) -> String? {
        let fm = FileManager.default
        var ps3game = (path as NSString).appendingPathComponent("PS3_GAME")
        if fm.fileExists(atPath: (ps3game as NSString).appendingPathComponent("PARAM.SFO")) {
            return ps3game
        }
        if fm.fileExists(atPath: (path as NSString).appendingPathComponent("PARAM.SFO")) {
            for d in ["USRDIR", "TROPDIR", "PS3_GAME", "PS3_UPDATE"] {
                if fm.fileExists(atPath: (path as NSString).appendingPathComponent(d)) { return path }
            }
        }
        return nil
    }

    /// True for a PS3 trophy archive.
    ///
    /// A PS3 package keeps its trophies at `TROPDIR/<NPWRxxxxx_00>/TROPHY.TRP`.
    /// Only real files count: the `TROPDIR` and `TROPDIR/<id>` entries are
    /// directories reported with size 0, and picking one of those would yield
    /// an empty pack that fails to parse.
    static func isTrophyPackName(_ name: String) -> Bool {
        let u = name.uppercased()
        guard u.hasSuffix(".TRP") else { return false }
        // Under TROPDIR, or a bare TRP that a dumper pulled out on its own.
        return u.contains("TROPDIR/") || !u.contains("/")
    }

    static func debugKeystream(_ qa: Data, blockIndex: UInt64) -> Data {
        let qa0 = qa.subdata(in: 0..<8)
        let qa1 = qa.subdata(in: 8..<16)
        var buf = Data(count: 64)
        buf.replaceSubrange(0..<8, with: qa0)
        buf.replaceSubrange(8..<16, with: qa0)
        buf.replaceSubrange(16..<24, with: qa1)
        buf.replaceSubrange(24..<32, with: qa1)
        var be = UInt64(blockIndex).bigEndian
        withUnsafeBytes(of: &be) { buf.replaceSubrange(56..<64, with: Data($0)) }
        return Data(Crypto.sha1(buf).prefix(16))
    }
    /// Decrypt a data-stream range; offsets are relative to `dataOff`.
    /// Returns empty Data on failure.
    static func decrypt(_ reader: FileHandleReader, dataOff: UInt64, retail: Bool,
                        keymat: Data, pos: Int, size: Int) -> Data? {
        guard size > 0, pos >= 0 else { return Data() }
        let bs = pos & ~0xF
        let pre = pos - bs
        let nb = (pre + size + 15) / 16
        guard nb <= 1 << 24, let enc = reader.read(at: dataOff &+ UInt64(bs), count: nb * 16), enc.count == nb * 16 else {
            return nil
        }
        var out = Data(count: 0)
        out.reserveCapacity(nb * 16)

        if !retail {
            let bi = bs / 16
            for i in 0..<nb {
                let ks = debugKeystream(keymat, blockIndex: UInt64(bi + i))
                for j in 0..<16 {
                    out.append(enc[i * 16 + j] ^ ks[j])
                }
            }
        } else {
            // Counter starts at the 128-bit big-endian key material, advanced
            // by the starting block index; each keystream block is AES-ECB of
            // the counter under the NPDRM key.
            var ctr = be128(keymat)
            add128(&ctr, UInt64(bs / 16))
            for i in 0..<nb {
                guard let ks = Crypto.aesECBEncrypt(key: key, block: ctr) else { return nil }
                for j in 0..<16 { out.append(enc[i * 16 + j] ^ ks[j]) }
                add128(&ctr, 1)
            }
        }
        guard out.count >= pre + size else { return nil }
        return out.subdata(in: pre..<(pre + size))
    }

    private static func be128(_ d: Data) -> [UInt8] {
        var a = [UInt8](repeating: 0, count: 16)
        for i in 0..<min(16, d.count) { a[i] = d[d.count - 16 + i] }
        return a
    }

    /// Add a small delta to a 16-byte big-endian counter.
    private static func add128(_ a: inout [UInt8], _ delta: UInt64) {
        var carry = delta
        var i = 15
        while i >= 0 && carry > 0 {
            let sum = UInt64(a[i]) + (carry & 0xFF)
            a[i] = UInt8(sum & 0xFF)
            carry = (carry >> 8) + (sum >> 8)
            i -= 1
        }
    }

    static func aesECBEncrypt(key: [UInt8], block: [UInt8]) -> [UInt8]? {
        Crypto.aesECBEncrypt(key: key, block: block)
    }
}

extension PkgParser {

    /// PS3 NPDRM package (retail or debug).
    static func parsePS3(_ reader: FileHandleReader, size: Int64) -> PkgResult {
        func fail(_ msg: Message) -> PkgResult {
            PkgResult(kind: "ps3", path: reader.url, fileSize: size,
                      title: reader.url.lastPathComponent, rows: [], failed: msg)
        }
        // The header is exactly 128 bytes: 4+2+2+4*4+8*3+48+16+16. The RIV
        // (the retail counter seed) sits at 0x70..<0x80, inside that range.
        // Reading 0x80 bytes truncated it and `subdata(in:)` range-checks by
        // trapping, so a short read was a hard crash, not a clean failure.
        guard let hdr = reader.read(at: 0, count: 128), hdr.count >= 128 else {
            return fail(Message("err.ps3TooSmall"))
        }
        // Header layout, matching the Python original's
        // `>4sHHIIIIQQQ48s16s16s`:
        //   0x00 magic   0x04 rev    0x06 type
        //   0x08 mo      0x0C mc     0x10 header size
        //   0x14 item count `n`     0x18 total file size
        //   0x20 data offset `doff` 0x28 data size `dsz`
        //   0x30 content id (48)    0x60 QA (16)  0x70 RIV (16)
        // The previous offsets were shifted 4 bytes and read the count as 0,
        // which made every file-table lookup fail.
        let r = ByteReader(hdr)
        let rev = r.u16be(at: 4) ?? 0
        let typ = r.u16be(at: 6) ?? 0
        let n = Int(r.u32be(at: 0x14) ?? 0)
        let dataOff = r.u64be(at: 0x20) ?? 0
        let dataSize = r.u64be(at: 0x28) ?? 0
        let cid = r.fixedString(at: 0x30, length: 48) ?? ""
        let qa = hdr.subdata(in: 0x60..<0x70)
        let riv = hdr.subdata(in: 0x70..<0x80)

        guard typ == 1 else { return fail(Message("err.ps3NotNpDrm", String(format: "0x%X", typ))) }
        let retail = (rev == 0x8000)
        let keymat = retail ? riv : qa

        var sfo: [String: MetaValue] = [:]
        var entries: [PkgEntry] = []

        if n > 0, n < 1_000_000, dataOff > 0, dataSize > 0,
           let tab = PS3.decrypt(reader, dataOff: dataOff, retail: retail, keymat: keymat, pos: 0, size: n * 32),
           tab.count == n * 32 {
            let tr = ByteReader(tab)
            struct Rec { let name: String; let fileOff: UInt64; let fileSize: UInt64 }
            var recs: [Rec] = []
            for i in 0..<n {
                let o = i * 32
                guard let no = tr.u32be(at: o), let ns = tr.u32be(at: o + 4),
                      let fo = tr.u64be(at: o + 8), let fs = tr.u64be(at: o + 16) else { continue }
                // Reject records that fall outside the data region.
                if UInt64(ns) > dataSize || UInt64(no) + UInt64(ns) > dataSize
                    || fo + fs > dataSize { continue }
                var nm = ""
                if ns > 0, let d = PS3.decrypt(reader, dataOff: dataOff, retail: retail,
                                                keymat: keymat, pos: Int(no), size: Int(ns)) {
                    var bytes = [UInt8](d)
                    while bytes.last == 0 { bytes.removeLast() }
                    nm = String(decoding: bytes, as: UTF8.self)
                }
                recs.append(Rec(name: nm, fileOff: fo, fileSize: fs))
            }
            var eid = 0
            for rec in recs where !rec.name.isEmpty {
                entries.append(PkgEntry(id: eid, name: rec.name, size: Int64(rec.fileSize),
                                        source: .ps3(url: reader.url, dataOff: dataOff, retail: retail,
                                                      keymat: keymat, fileOff: rec.fileOff),
                                        isTrophyPack: PS3.isTrophyPackName(rec.name)))
                eid += 1
            }
            for rec in recs where rec.name.uppercased().hasSuffix("PARAM.SFO") && rec.fileSize > 0 && rec.fileSize < 1_000_000 {
                if let raw = PS3.decrypt(reader, dataOff: dataOff, retail: retail,
                                          keymat: keymat, pos: Int(rec.fileOff), size: Int(rec.fileSize)),
                   raw.count >= 4, raw.prefix(4) == Data([0x00, 0x50, 0x53, 0x46]) {
                    sfo = SFO.parse(raw)
                }
                break
            }
        }

        let title = sfo.str("TITLE")
        var tid = sfo.str("TITLE_ID")
        if tid.isEmpty {
            let parts = cid.split(separator: "-")
            if parts.count > 1 { tid = String(parts[1].split(separator: "_").first ?? "") }
        }
        var ver = sfo.str("VERSION")
        if ver.isEmpty { ver = sfo.str("APP_VER") }
        let region = cid.contains("-")
            ? Meta.contentRegion(cid)
            : (PS3.tidRegion[String(tid.prefix(4)).uppercased()] ?? "-")

        var rows: [(String, String)] = [
            ("Platform", "PS3 NPDRM (\(retail ? "retail" : "debug"))"),
            ("Content ID", cid.isEmpty ? "-" : cid),
            ("Title ID", tid.isEmpty ? "-" : tid),
            ("Region", region),
            ("Version", ver.isEmpty ? "-" : ver),
            // PS3 firmware versions are always dotted text ("04.7000"); the BCD integer
            // form only appears on PS4/PS5, so no decoding is wanted here — but
            // displayString is still read so an int-typed value shows as a
            // number rather than a blank cell.
            ("Min. System", Meta.systemVersion(sfo, key: "PS3_SYSTEM_VER")),
            ("Size", Fmt.size(size)),
            ("Files", entries.isEmpty ? "\(n) (encrypted)" : String(entries.count)),
        ]
        if entries.isEmpty {
            rows.append(("Note", "file table unreadable"))
        }
        let icon = entries.first { $0.name.uppercased() == "ICON0.PNG" }?.name ?? ""

        return PkgResult(kind: "ps3", path: reader.url, fileSize: size,
                         title: title.isEmpty ? (tid.isEmpty ? reader.url.lastPathComponent : tid) : title,
                         rows: rows, entries: entries, meta: sfo,
                         iconName: icon.isEmpty ? "icon0.png" : icon)
    }
}
