import Foundation

/// Nintendo Switch containers: NSP (a PFS0 package) and XCI (a gamecard image).
///
/// Ported from the Python original's v1.15.0 Switch support. Two tiers:
///
///   - **No keys needed** — the PFS0/HFS0 file listing, and any plaintext
///     `*.cnmt.xml`, give the title ID, version, type and required firmware.
///     Without keys the title falls back to the filename.
///   - **With `prod.keys`** — NCA headers decrypt with AES-XTS, which yields
///     the authoritative per-NCA content type (Program/Meta/Control/…) and its
///     key generation. Binary CNMT inside the Meta NCA covers packages that
///     ship no `cnmt.xml`.
///
/// Every step is defensive: a container that cannot be read reports a message
/// rather than throwing, and missing keys degrade the view instead of failing.
enum Switch {

    static let pfs0Magic = Data("PFS0".utf8)   // NSP
    static let hfs0Magic = Data("HFS0".utf8)   // XCI partition table
    static let xciMagic  = Data("HEAD".utf8)   // XCI header magic at 0x100

    /// NCA content types, read from the decrypted header byte at 0x205.
    static let ncaTypes: [UInt8: String] = [0: "Program", 1: "Meta", 2: "Control",
                                            3: "Manual", 4: "Data", 5: "PublicData"]
    static let cnmtTypes: [UInt8: String] = [0x01: "System", 0x02: "SystemData",
                                             0x03: "SystemUpdate", 0x80: "Application",
                                             0x81: "Patch", 0x82: "AddOnContent"]
    /// Gamecard capacity, keyed by the XCI header byte at 0x10D.
    static let cartSizes: [UInt8: String] = [0xFA: "1GB", 0xF8: "2GB", 0xF0: "4GB",
                                             0xE0: "8GB", 0xE1: "16GB", 0xE2: "32GB"]

    // MARK: - Container entries

    struct RawEntry {
        var name: String
        var size: UInt64
        var absOff: UInt64
        /// Human note shown in the Files tab (NCA type, ticket/cert, …).
        var codec: String?
        /// Longer form shown with the codec, e.g. "keygen 3, standard crypto".
        var ncaDetail: String?
    }

    // MARK: - prod.keys

    struct Keys {
        var headerKey: [UInt8] = []
        /// "application_3" -> 16-byte key area encryption key.
        var kaek: [String: [UInt8]] = [:]
        /// Key generation -> 16-byte titlekek.
        var titlekek: [Int: [UInt8]] = [:]

        func kaek(_ kind: String, _ crypto: Int) -> [UInt8]? { kaek["\(kind)_\(crypto)"] }
    }

    /// Cached so a package with dozens of NCAs reads the key file once.
    ///
    /// Held in a lock box rather than bare statics: `loadKeys` runs on the
    /// parsing queue, and Swift 6 rejects unsynchronised mutable globals.
    private struct KeysCache {
        var loaded = false
        var value: Keys?
    }
    private static let keysBox = NSLockBox(KeysCache())

    /// Load `prod.keys`, or nil when no usable key file is installed.
    ///
    /// The search order mirrors the original: an explicit environment override,
    /// then the user's `~/.switch/prod.keys` (where every Switch tool expects
    /// it), then next to the app and in the working directory. A file without
    /// a 32-byte `header_key` is ignored — the NCA path cannot work without it,
    /// and silently proceeding would produce empty results that look like bugs.
    static func loadKeys() -> Keys? {
        keysBox.withLock { cache in
            if cache.loaded { return cache.value }
            cache.loaded = true
            cache.value = Self.readKeys()
            return cache.value
        }
    }

    private static func readKeys() -> Keys? {
        var candidates: [String] = []
        for v in ["SWITCH_PROD_KEYS", "PROD_KEYS"] {
            if let p = ProcessInfo.processInfo.environment[v], !p.isEmpty { candidates.append(p) }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        candidates.append(home + "/.switch/prod.keys")
        if let appDir = Bundle.main.resourceURL?.deletingLastPathComponent() {
            candidates.append(appDir.path + "/prod.keys")
        }
        candidates.append(FileManager.default.currentDirectoryPath + "/prod.keys")

        for path in candidates {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            var raw: [String: [UInt8]] = [:]
            for line in text.split(separator: "\n") {
                let l = line.trimmingCharacters(in: .whitespaces)
                if l.isEmpty || l.hasPrefix("#") || !l.contains("=") { continue }
                let parts = l.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let name = String(parts[0]).trimmingCharacters(in: .whitespaces)
                let hex = String(parts[1]).trimmingCharacters(in: .whitespaces)
                raw[name] = Self.hexBytes(hex)
            }
            guard let hk = raw["header_key"], hk.count == 32 else { continue }
            var keys = Keys(headerKey: hk)
            for (name, v) in raw where v.count == 16 {
                // key_area_key_application_03 / key_area_key_ocean_00 / …
                let parts = name.split(separator: "_")
                if parts.count == 5, parts[0] == "key", parts[1] == "area",
                   parts[2] == "key", let idx = Int(parts[4], radix: 16) {
                    keys.kaek["\(parts[3])_\(idx)"] = v
                } else if parts.count == 2, parts[0] == "titlekek",
                          let idx = Int(parts[1], radix: 16) {
                    keys.titlekek[idx] = v
                }
            }
            guard !keys.kaek.isEmpty else { continue }
            return keys
        }
        return nil
    }

    /// Parse an even-length hex string; odd or invalid input yields nil.
    private static func hexBytes(_ s: String) -> [UInt8] {
        let c = Array(s.utf8)
        guard c.count % 2 == 0 else { return [] }
        var out: [UInt8] = []
        var i = 0
        while i < c.count {
            guard let hi = Self.hexNibble(c[i]), let lo = Self.hexNibble(c[i + 1]) else { return [] }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    private static func hexNibble(_ b: UInt8) -> UInt8? {
        switch b {
        case 0x30...0x39: return b - 0x30          // 0-9
        case 0x61...0x66: return b - 0x61 + 10     // a-f
        case 0x41...0x46: return b - 0x41 + 10     // A-F
        default: return nil
        }
    }

    // MARK: - PFS0 (NSP)

    /// A PFS0 file table: `num` 24-byte records then the name string table.
    ///
    /// Returns the entries and the absolute offset where file data starts.
    /// Nil when the header is not PFS0 or any bound check fails — a bad count
    /// must not turn into a read past EOF.
    static func pfs0Entries(_ r: FileHandleReader, size: Int64) -> (items: [RawEntry], base: UInt64)? {
        guard let hdr = r.read(at: 0, count: 16), hdr.prefix(4) == pfs0Magic else { return nil }
        let num = Int(Self.u32le(hdr, 4))
        let strSize = Int(Self.u32le(hdr, 8))
        guard (1...100_000).contains(num), strSize <= 20_000_000 else { return nil }
        let tableBytes = num * 24
        guard let raw = r.read(at: 16, count: tableBytes),
              let strtab = r.read(at: UInt64(16 + tableBytes), count: strSize) else { return nil }
        let base = UInt64(16 + tableBytes + strSize)
        guard base <= UInt64(size) else { return nil }

        var items: [RawEntry] = []
        for i in 0..<num {
            let rec = i * 24
            let off = Self.u64le(raw, rec)
            let sz = Self.u64le(raw, rec + 8)
            let nameOff = Int(Self.u32le(raw, rec + 16))
            guard nameOff < strtab.count else { return nil }
            // A missing NUL terminator is real, not corruption: nsz declares
            // the string table a few bytes short of the names it holds, so the
            // last entry runs to the end of the table. Taking the remainder is
            // right; rejecting the whole container (as the original does) makes
            // those packages unreadable for a 4-byte discrepancy.
            let end = strtab[nameOff...].firstIndex(of: 0) ?? strtab.endIndex
            let name = String(decoding: strtab[nameOff..<end], as: UTF8.self)
            // Allow a little overrun (padding) but reject wild offsets.
            if off > UInt64(size) { return nil }
            items.append(RawEntry(name: name, size: sz, absOff: base + off))
        }
        return (items, base)
    }

    // MARK: - HFS0 (XCI partitions)

    /// One HFS0 partition table at `off`, entries optionally prefixed with the
    /// partition name (`secure/...`) so the Files tab shows where they live.
    static func hfs0Entries(_ r: FileHandleReader, at off: UInt64, size: Int64,
                            prefix: String = "") -> [RawEntry] {
        guard off + 16 <= UInt64(size),
              let hdr = r.read(at: off, count: 16), hdr.prefix(4) == hfs0Magic else { return [] }
        let num = Int(Self.u32le(hdr, 4))
        let strSize = Int(Self.u32le(hdr, 8))
        guard (0...100_000).contains(num), strSize <= 20_000_000 else { return [] }
        let tableBytes = num * 64
        guard let raw = r.read(at: off + 16, count: tableBytes),
              let strtab = r.read(at: off + UInt64(16 + tableBytes), count: strSize) else { return [] }
        let dataStart = off + UInt64(16 + tableBytes) + UInt64(strtab.count)

        var out: [RawEntry] = []
        for i in 0..<num {
            let rec = i * 64
            let eOff = Self.u64le(raw, rec)
            let sz = Self.u64le(raw, rec + 8)
            let nameOff = Int(Self.u32le(raw, rec + 16))
            guard nameOff < strtab.count else { continue }
            // Same tolerance as PFS0: an unterminated name takes the rest of
            // the table rather than dropping the entry.
            let end = strtab[nameOff...].firstIndex(of: 0) ?? strtab.endIndex
            let nm = String(decoding: strtab[nameOff..<end], as: UTF8.self)
            guard !nm.isEmpty else { continue }
            if eOff > UInt64(size) { continue }
            let full = prefix.isEmpty ? nm : "\(prefix)/\(nm)"
            out.append(RawEntry(name: full, size: sz, absOff: dataStart + eOff))
        }
        return out
    }

    // MARK: - CNMT

    struct Cnmt {
        var id = ""
        var version = ""
        var type = ""
        var requiredSystemVersion = ""
        var contents: [(type: String, id: String)] = []
    }

    /// Minimal `*.cnmt.xml` reader.
    ///
    /// Uses `XMLParser` rather than string slicing: the file is small, and a
    /// real parser copes with the whitespace and ordering variations dumps
    /// actually contain.
    static func parseCnmtXml(_ data: Data) -> Cnmt {
        let delegate = CnmtDelegate()
        let p = XMLParser(data: data)
        p.delegate = delegate
        p.parse()
        var out = Cnmt()
        out.id = delegate.values["Id"] ?? ""
        out.version = delegate.values["Version"] ?? ""
        out.type = delegate.values["Type"] ?? ""
        out.requiredSystemVersion = delegate.values["RequiredSystemVersion"] ?? ""
        for c in delegate.contents {
            out.contents.append((type: c["Type"] ?? "", id: c["Id"] ?? ""))
        }
        return out
    }

    private final class CnmtDelegate: NSObject, XMLParserDelegate {
        var values: [String: String] = [:]
        var contents: [[String: String]] = []
        private var current = ""
        private var currentContent: [String: String]?

        func parser(_ parser: XMLParser, didStartElement name: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes: [String: String] = [:]) {
            current = name
            if name == "Content" { currentContent = [:] }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            let t = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }
            if currentContent != nil {
                currentContent?[current, default: ""] += t
            } else {
                values[current, default: ""] += t
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            if name == "Content", let c = currentContent { contents.append(c); currentContent = nil }
            current = ""
        }
    }

    // MARK: - Presentation helpers

    /// HOS packed firmware `major<<26 | minor<<20 | micro<<16` -> "16.0.3".
    ///
    /// Empty when the value is not a plausible version, so the caller can show
    /// the raw number instead of inventing one.
    static func decodeFirmware(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let n = UInt64(t), n > 0, n < 0xFFFF_FFFF else { return "" }
        let maj = (n >> 26) & 0x3F, minor = (n >> 20) & 0x3F, micro = (n >> 16) & 0xF
        guard (1...40).contains(maj) else { return "" }
        return "\(maj).\(minor).\(micro)"
    }

    /// Title / title ID / version from the usual `[0100…][v0]` filename tags.
    static func titleFromFilename(_ url: URL) -> (title: String, tid: String, ver: String) {
        let stem = url.deletingPathExtension().lastPathComponent
        var tid = "", ver = ""
        if let m = stem.range(of: #"\[([0-9A-Fa-f]{16})\]"#, options: .regularExpression) {
            let inner = stem[m]
            tid = String(inner.dropFirst().dropLast()).uppercased()
        }
        if let m = stem.range(of: #"\[v(\d+)\]"#, options: [.regularExpression, .caseInsensitive]) {
            let inner = stem[m]
            ver = String(inner.dropFirst(2).dropLast())
        }
        // Drop every [tag], then tidy the separators it leaves behind.
        var title = stem.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: " -_."))
        title = title.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return (title.isEmpty ? stem : title, tid, ver)
    }

    // MARK: - NCA headers

    /// Decrypt an NCA header (AES-XTS, big-endian sector tweak) -> 0xC00 bytes.
    ///
    /// The tweak is the sector index written big-endian into the 16-byte value,
    /// the convention hactool uses; the original verifies against real dumps.
    /// A header whose magic is not `NCA2`/`NCA3` means the key or offset is
    /// wrong, so it is reported as nil rather than parsed as garbage.
    static func ncaHeader(_ r: FileHandleReader, at off: UInt64, keys: Keys) -> [UInt8]? {
        guard let raw = r.read(at: off, count: 0xC00), raw.count == 0xC00 else { return nil }
        let b = [UInt8](raw)
        var out: [UInt8] = []
        out.reserveCapacity(0xC00)
        for s in 0..<6 {
            var tweak = [UInt8](repeating: 0, count: 16)
            tweak[15] = UInt8(s & 0xFF)
            tweak[14] = UInt8((s >> 8) & 0xFF)
            let sector = Array(b[(s * 0x200)..<((s + 1) * 0x200)])
            guard let dec = Crypto.aesXTSDecrypt(key: keys.headerKey, tweak: tweak, data: sector) else {
                return nil
            }
            out += dec
        }
        let magic = Array(out[0x200..<0x204])
        guard magic == Array("NCA3".utf8) || magic == Array("NCA2".utf8) else { return nil }
        return out
    }

    struct NcaDetail {
        var ctype: UInt8
        var crypto: Int
        var rights: Bool
        var typeName: String { Switch.ncaTypes[ctype] ?? "NCA" }
    }

    /// Content type, key generation and whether the NCA is titlekey-crypto.
    static func ncaDetail(_ r: FileHandleReader, at off: UInt64, keys: Keys) -> NcaDetail? {
        guard let full = ncaHeader(r, at: off, keys: keys), full.count > 0x240 else { return nil }
        let ctype = full[0x205]
        var crypto = Int(max(full[0x206], full[0x220]))
        if crypto > 0 { crypto -= 1 }
        let rights = full[0x230..<0x240].contains { $0 != 0 }
        return NcaDetail(ctype: ctype, crypto: crypto, rights: rights)
    }

    // MARK: - NCA sections (binary CNMT)

    /// The AES key for an NCA's data sections.
    ///
    /// Titlekey-crypto NCAs carry the key in the ticket, decrypted with the
    /// matching titlekek; standard ones keep it in the header's key area.
    static func ncaSectionKey(_ full: [UInt8], ticket: Data?, keys: Keys) -> [UInt8]? {
        guard full.count > 0x340 else { return nil }
        var crypto = Int(max(full[0x206], full[0x220]))
        if crypto > 0 { crypto -= 1 }
        let rights = full[0x230..<0x240]
        if rights.contains(where: { $0 != 0 }) {
            guard let tik = ticket, tik.count >= 0x1CF,
                  let tk = keys.titlekek[crypto] else { return nil }
            return Crypto.aesDecryptBlock(key: tk, block: Array(tik[0x1BF..<0x1CF]))
        }
        let kind = [0: "application", 1: "ocean", 2: "system"][full[0x207]] ?? "application"
        guard let kak = keys.kaek(kind, crypto),
              let area = Crypto.aesECBDecrypt(key: kak, data: Array(full[0x300..<0x340])) else { return nil }
        return Array(area[32..<48])
    }

    /// Read bytes at `relOff` inside an NCA section, undoing AES-CTR when the
    /// section is encrypted.
    static func ctrRead(_ r: FileHandleReader, secoff: UInt64, secoffRel: UInt64,
                        sctr: [UInt8], key: [UInt8], relOff: UInt64, size: Int) -> Data? {
        guard size > 0, size <= 16_000_000 else { return nil }
        let lo = relOff & ~0xF
        let nblocks = Int((relOff - lo) + UInt64(size) + 15) / 16
        // Counter = reversed(section CTR) ++ BE64(section offset >> 4), plus
        // the block index — the layout hactool and the original both use.
        var counter = Array(sctr.reversed())
        counter.append(contentsOf: Self.be64(secoffRel >> 4))
        counter = Crypto.ctrAdvanced(counter, by: lo >> 4)
        guard let ct = r.read(at: secoff + lo, count: nblocks * 16),
              let pt = Crypto.aesCTR(key: key, counter: counter, data: [UInt8](ct)) else { return nil }
        let skip = Int(relOff - lo)
        guard pt.count >= skip + size else { return nil }
        return Data(pt[skip..<(skip + size)])
    }

    private static func be64(_ v: UInt64) -> [UInt8] {
        (0..<8).map { UInt8((v >> (8 * (7 - $0))) & 0xFF) }
    }

    struct CnmtBin {
        var tid = ""
        var ver = ""
        var type = ""
        var sysver = ""
    }

    /// Read the binary CNMT from a Meta NCA (`*.cnmt.nca`).
    ///
    /// Dumps rarely ship a plaintext `cnmt.xml`; the same facts live here, in
    /// a PFS0 section that may be AES-CTR encrypted. This is what supplies the
    /// title ID, version, type and required firmware when the filename cannot.
    static func readCnmtBinary(_ r: FileHandleReader, at off: UInt64,
                               ticket: Data?, keys: Keys) -> CnmtBin? {
        guard let full = ncaHeader(r, at: off, keys: keys), full.count >= 0x600 else { return nil }
        guard full[0x205] == 1 else { return nil }          // Meta only
        guard let secKey = ncaSectionKey(full, ticket: ticket, keys: keys) else { return nil }
        let fd = Data(full)
        for i in 0..<4 {
            let start = Self.u32le(fd, 0x240 + i * 16)
            if start == 0 { continue }
            let fsh = Array(full[(0x400 + i * 0x200)..<(0x400 + (i + 1) * 0x200)])
            guard fsh[3] == 2 else { continue }             // PFS0 section
            let enc = fsh[4]
            guard enc == 1 || enc == 3 else { continue }
            let secoffRel = UInt64(start) * 0x200
            let secoff = off + secoffRel
            let fsd = Data(fsh)
            let poff = Self.u64le(fsd, 0x40)
            let psz = Self.u64le(fsd, 0x48)
            guard psz >= 16, poff <= 64_000_000, psz <= 64_000_000 else { continue }

            let get: (UInt64, Int) -> Data?
            if enc == 3 {
                let sctr = Array(fsh[0x140..<0x148])
                get = { soff, size in
                    Self.ctrRead(r, secoff: secoff, secoffRel: secoffRel,
                                 sctr: sctr, key: secKey, relOff: soff, size: size)
                }
            } else {
                get = { soff, size in r.read(at: secoff + soff, count: size) }
            }

            guard let hdr = get(poff, 16), hdr.prefix(4) == pfs0Magic else { continue }
            let num = Int(Self.u32le(hdr, 4))
            let sts = Int(Self.u32le(hdr, 8))
            guard (1...64).contains(num), sts <= 1_000_000 else { continue }
            guard let tab = get(poff + 16, num * 24),
                  let stb = get(poff + UInt64(16 + num * 24), sts) else { continue }
            let base = poff + UInt64(16 + num * 24 + sts)

            for j in 0..<num {
                let rec = j * 24
                let eOff = Self.u64le(tab, rec)
                let sz = Self.u64le(tab, rec + 8)
                let noff = Int(Self.u32le(tab, rec + 16))
                guard noff < stb.count else { continue }
                let slice = stb[noff...]
                guard let end = slice.firstIndex(of: 0) else { continue }
                let nm = String(decoding: stb[noff..<end], as: UTF8.self)
                guard nm.lowercased().hasSuffix(".cnmt"), sz <= 100_000 else { continue }
                guard let data = get(base + eOff, Int(min(sz, 0x2000))),
                      data.count >= 0x20 else { continue }
                let tid = Self.u64le(data, 0)
                guard tid != 0 else { continue }
                var out = CnmtBin()
                out.tid = String(format: "%016llX", tid)
                out.ver = "\(Self.u32le(data, 8))"
                let ctype = data[0xC]
                out.type = cnmtTypes[ctype] ?? String(format: "Type %#x", Int(ctype))
                let sv = Self.u32le(data, 0x18)
                out.sysver = sv == 0 ? "" : "\(sv)"
                return out
            }
        }
        return nil
    }

    // MARK: - NACP (Control NCA)

    /// The official metadata a Control NCA's `control.nacp` carries.
    struct NacpInfo {
        var titles: [String: String] = [:]
        var publishers: [String: String] = [:]
        var displayVersion = ""
        var icon: Data?
        var iconName = ""
    }

    /// Language order fixed by the NACP layout.
    static let nacpLangs = ["AmericanEnglish", "BritishEnglish", "Japanese", "French",
                            "German", "LatinAmericanSpanish", "Spanish", "Italian",
                            "Dutch", "CanadianFrench", "Portuguese", "Russian", "Korean",
                            "TraditionalChinese", "SimplifiedChinese", "BrazilianPortuguese"]

    /// Read a Control NCA's NACP: official title, publisher, display version
    /// and icon.
    ///
    /// The payload sits in a **RomFS** section — not the PFS0 a Meta NCA uses —
    /// so this has to walk RomFS's directory/file tables (singly linked via
    /// sibling pointers) to reach `control.nacp`, decrypting every read with
    /// AES-CTR. Nil whenever any step cannot be completed; missing keys are a
    /// normal outcome, not an error.
    static func ncaControlInfo(_ r: FileHandleReader, at off: UInt64,
                               ticket: Data?, keys: Keys) -> NacpInfo? {
        guard let full = ncaHeader(r, at: off, keys: keys), full.count >= 0x600 else { return nil }
        guard let secKey = ncaSectionKey(full, ticket: ticket, keys: keys) else { return nil }
        let fd = Data(full)
        for i in 0..<4 {
            let start = Self.u32le(fd, 0x240 + i * 16)
            if start == 0 { continue }
            let fsh = Array(full[(0x400 + i * 0x200)..<(0x400 + (i + 1) * 0x200)])
            // Section must be RomFS (3) and AES-CTR encrypted (3).
            guard fsh[3] == 3, fsh[4] == 3 else { continue }
            guard Array(fsh[0x8..<0xC]) == Array("IVFC".utf8) else { continue }
            let secoffRel = UInt64(start) * 0x200
            let secoff = off + secoffRel
            let sctr = Array(fsh[0x140..<0x148])
            let romfsRel = Self.u64le(Data(fsh), 0x90)
            guard romfsRel <= 2_000_000_000 else { continue }

            let read: (UInt64, Int) -> Data? = { rel, size in
                Self.ctrRead(r, secoff: secoff, secoffRel: secoffRel, sctr: sctr,
                             key: secKey, relOff: romfsRel + rel, size: size)
            }
            // RomFS header: ten u64s, the ones we need being the directory
            // table, the file table and where file data starts.
            guard let rh = read(0, 0x50), rh.count == 0x50 else { continue }
            var v = [UInt64](repeating: 0, count: 10)
            for k in 0..<10 { v[k] = Self.u64le(rh, k * 8) }
            guard v[0] == 0x50 else { continue }
            let dmo = v[3], dms = v[4], fmo = v[7], fms = v[8], dataOff = v[9]
            guard dms <= 1_000_000, fms <= 5_000_000 else { continue }
            guard let dirs = read(dmo, Int(dms)), let files = read(fmo, Int(fms)),
                  dirs.count >= 24, !files.isEmpty else { continue }

            // A file table entry is parent, sibling, offset, size, hash,
            // name-length; the name follows. Walk the sibling chain.
            func filesAt(_ tblOff: UInt32) -> [(String, UInt64, UInt64)] {
                var out: [(String, UInt64, UInt64)] = []
                var o = Int(tblOff)
                var seen = Set<Int>()
                while o != 0xFFFFFFFF && !seen.contains(o) && o + 32 <= files.count {
                    seen.insert(o)
                    let fOff = Self.u64le(files, o + 8)
                    let fSize = Self.u64le(files, o + 16)
                    let nlen = Int(Self.u32le(files, o + 28))
                    guard nlen <= 512, o + 32 + nlen <= files.count else { break }
                    let nm = String(decoding: files[(o + 32)..<(o + 32 + nlen)], as: UTF8.self)
                    out.append((nm, fOff, fSize))
                    o = Int(Self.u32le(files, o + 4))
                }
                return out
            }

            var found: [(dir: String, name: String, off: UInt64, size: UInt64)] = []
            for f in filesAt(Self.u32le(dirs, 12)) {
                found.append((dir: "", name: f.0, off: f.1, size: f.2))
            }
            // One level of subdirectories: some titles nest the control data.
            var seenD = Set<Int>()
            var stack: [Int] = []
            let firstChild = Int(Self.u32le(dirs, 8))
            if firstChild != 0xFFFFFFFF { stack.append(firstChild) }
            while let d = stack.popLast() {
                if d == 0xFFFFFFFF || seenD.contains(d) || d + 24 > dirs.count { continue }
                seenD.insert(d)
                let nlen = Int(Self.u32le(dirs, d + 20))
                guard nlen <= 512, d + 24 + nlen <= dirs.count else { continue }
                let dn = String(decoding: dirs[(d + 24)..<(d + 24 + nlen)], as: UTF8.self)
                for f in filesAt(Self.u32le(dirs, d + 12)) {
                    found.append((dir: dn, name: f.0, off: f.1, size: f.2))
                }
                let child = Self.u32le(dirs, d + 8)
                if child != 0xFFFFFFFF { stack.append(Int(child)) }
                let sib = Self.u32le(dirs, d + 4)
                if sib != 0xFFFFFFFF { stack.append(Int(sib)) }
            }

            guard let hit = found.first(where: { $0.name.lowercased() == "control.nacp" }),
                  let nacp = read(dataOff + hit.off, Int(min(hit.size, 0x4000))),
                  nacp.count >= 0x3080 else { continue }

            var info = NacpInfo()
            for li in 0..<16 {
                let nm = Self.cstring(nacp, li * 0x300, 0x200)
                let pb = Self.cstring(nacp, li * 0x300 + 0x200, 0x100)
                if !nm.isEmpty { info.titles[nacpLangs[li]] = nm }
                if !pb.isEmpty { info.publishers[nacpLangs[li]] = pb }
            }
            guard !info.titles.isEmpty else { continue }
            info.displayVersion = Self.cstring(nacp, 0x3060, 0x10)

            // Icons are JPEGs despite the .dat name; pick a preferred language.
            let icons = found.filter {
                let n = $0.name.lowercased()
                return n.hasPrefix("icon_") && n.hasSuffix(".dat")
                    && $0.size >= 1024 && $0.size <= 8_000_000
            }
            var chosen = icons.first
            for pref in ["icon_AmericanEnglish.dat", "icon_BritishEnglish.dat", "icon_Japanese.dat"] {
                if let h = icons.first(where: { $0.name == pref }) { chosen = h; break }
            }
            if let c = chosen,
               let dat = read(dataOff + c.off, Int(c.size)),
               dat.prefix(2) == Data([0xFF, 0xD8]) {
                info.icon = dat
                info.iconName = c.name
            }
            return info
        }
        return nil
    }

    /// A NUL-terminated UTF-8 field inside `d`, trimmed.
    private static func cstring(_ d: Data, _ off: Int, _ max: Int) -> String {
        guard off >= 0, off < d.count else { return "" }
        let end = min(off + max, d.count)
        var i = off
        while i < end, d[i] != 0 { i += 1 }
        return String(decoding: d[off..<i], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pick the NACP title for the interface language, falling back to English.
    ///
    /// `tags` defaults to the system languages, but callers that know the
    /// pinned interface language should pass it — the app language and the
    /// system language can differ, and the title must follow the app.
    static func preferred(_ dict: [String: String],
                          tags: [String] = Locale.preferredLanguages) -> String {
        for tag in tags {
            let t = tag.lowercased()
            let want: String
            switch t.prefix(2) {
            case "zh": want = t.contains("hans") || t.contains("cn") ? "SimplifiedChinese" : "TraditionalChinese"
            case "ja": want = "Japanese"
            case "en": want = "AmericanEnglish"
            case "ko": want = "Korean"
            case "fr": want = "French"
            case "de": want = "German"
            case "es": want = "Spanish"
            case "it": want = "Italian"
            case "ru": want = "Russian"
            case "pt": want = "Portuguese"
            case "nl": want = "Dutch"
            default: continue
            }
            if let v = dict[want], !v.isEmpty { return v }
        }
        for k in ["AmericanEnglish", "BritishEnglish", "Japanese"] {
            if let v = dict[k], !v.isEmpty { return v }
        }
        return dict.values.first ?? ""
    }

    // MARK: - NSP

    /// Parse an NSP: PFS0 file list plus whatever metadata is reachable.
    ///
    /// Falls back to the filename for the title/ID/version when the package
    /// has no readable `cnmt.xml` — a bare dump is still worth listing.
    static func parseNSP(_ url: URL, _ r: FileHandleReader, size: Int64) -> PkgResult {
        guard let parsed = pfs0Entries(r, size: size) else {
            return PkgLoader.failure(url, Message("err.badNsp"))
        }
        var entries = parsed.items

        // Plaintext metadata, when the package ships it.
        var cnmt = Cnmt()
        var cnmtFile = ""
        for e in entries
        where e.name.lowercased().hasSuffix(".cnmt.xml") && e.size > 0 && e.size < 200_000 {
            if let d = r.read(at: e.absOff, count: Int(e.size)) {
                cnmt = parseCnmtXml(d)
                cnmtFile = e.name
                break
            }
        }

        // CNMT knows each content's role; tag the NCAs it names.
        var typeById: [String: String] = [:]
        for c in cnmt.contents where !c.id.isEmpty { typeById[c.id.lowercased()] = c.type }
        for i in entries.indices {
            let ln = entries[i].name.lowercased()
            if ln.hasSuffix(".tik") { entries[i].codec = "ticket" }
            else if ln.hasSuffix(".cert") { entries[i].codec = "cert" }
            else if ln.hasSuffix(".ncz") {
                // NSZ replaces NCA bodies with zstd-compressed NCZ; the header
                // is gone with them, so no type or NACP can be recovered from
                // this entry — but the listing should still say why.
                entries[i].codec = "NCZ · compressed"
            }
            else if ln.hasSuffix(".nca") {
                let stem = Self.stem(entries[i].name)
                if let t = typeById[stem], !t.isEmpty { entries[i].codec = t }
            }
        }

        let keys = loadKeys()
        // Titlekey-crypto NCAs need the ticket to derive their section key.
        var ticket: Data?
        if keys != nil,
           let t = entries.first(where: {
               $0.name.lowercased().hasSuffix(".tik") && $0.size > 0 && $0.size <= 8192
           }) {
            ticket = r.read(at: t.absOff, count: Int(t.size))
        }
        // Binary CNMT fallback: a dump without a plaintext cnmt.xml keeps the
        // same facts inside its Meta NCA, readable only with prod.keys.
        var cnmtBin: CnmtBin?
        if let keys, cnmt.id.isEmpty,
           let meta = entries.first(where: { $0.name.lowercased().hasSuffix(".cnmt.nca") }) {
            cnmtBin = readCnmtBinary(r, at: meta.absOff, ticket: ticket, keys: keys)
        }

        var hdrTypes: [String: String] = [:]
        var controlOff: UInt64?
        if let keys {
            // NCA headers are authoritative and cheap (0xC00 of XTS each), so
            // they fill in the types CNMT did not name and add crypto facts.
            for i in entries.indices where entries[i].name.lowercased().hasSuffix(".nca") {
                let stem = Self.stem(entries[i].name)
                guard let det = ncaDetail(r, at: entries[i].absOff, keys: keys) else { continue }
                entries[i].ncaDetail = "keygen \(det.crypto), \(det.rights ? "titlekey" : "standard") crypto"
                let sfx = det.rights ? "tk" : "k\(det.crypto)"
                hdrTypes[stem] = det.typeName
                let base = entries[i].codec ?? det.typeName
                if !(entries[i].codec ?? "").contains(" · ") {
                    entries[i].codec = "\(base) · \(sfx)"
                }
                // Content type 2 is the Control NCA — the one holding NACP.
                if det.ctype == 2, controlOff == nil { controlOff = entries[i].absOff }
            }
        }

        let fname = titleFromFilename(url)
        // XML first (plaintext, no keys); binary CNMT next; filename last.
        var tid = cnmt.id.uppercased()
        if tid.hasPrefix("0X") { tid = String(tid.dropFirst(2)) }
        if tid.isEmpty { tid = cnmtBin?.tid ?? "" }
        if tid.isEmpty { tid = fname.tid }
        var ver = cnmt.version
        if ver.isEmpty { ver = cnmtBin?.ver ?? "" }
        if ver.isEmpty { ver = fname.ver }
        var ctype = cnmt.type
        if ctype.isEmpty { ctype = cnmtBin?.type ?? "" }
        var sysver = cnmt.requiredSystemVersion
        if sysver.isEmpty { sysver = cnmtBin?.sysver ?? "" }
        if sysver == "0" { sysver = "" }
        let sysRow = decodeFirmware(sysver).isEmpty ? (sysver.isEmpty ? "-" : sysver) : decodeFirmware(sysver)

        let hasTik = entries.contains { $0.name.lowercased().hasSuffix(".tik") }
        let hasCert = entries.contains { $0.name.lowercased().hasSuffix(".cert") }
        let ncaCount = entries.filter { $0.name.lowercased().hasSuffix(".nca") }.count

        var kinds = Set(cnmt.contents.map(\.type).filter { !$0.isEmpty })
        if kinds.isEmpty { kinds = Set(hdrTypes.values) }
        let contentsRow = kinds.isEmpty ? "\(ncaCount) NCA" : kinds.sorted().joined(separator: ", ")
        var tikCert = ""
        if hasTik { tikCert += "tik" }
        if hasCert { tikCert += tikCert.isEmpty ? "cert" : "+cert" }

        // A full NSP ships per-language key art next to the NCAs
        // (`<id>.nx.AmericanEnglish.jpg`). It is plaintext, so the cover does
        // not depend on prod.keys the way the Control NCA's icon does.
        let iconName = Self.coverName(in: entries)

        var rows: [(String, String)] = [
            ("Platform", "Nintendo Switch (NSP/PFS0)"),
            ("Title ID", tid.isEmpty ? "-" : tid),
            ("Version", ver.isEmpty ? "-" : "v\(ver)"),
            ("Type", ctype.isEmpty ? "-" : ctype),
            ("Min. System", sysRow),
            ("Contents", contentsRow),
            ("Ticket/Cert", tikCert.isEmpty ? "-" : tikCert),
            ("Size", Fmt.size(size)),
            ("Entries", "\(entries.count)"),
        ]
        if keys == nil {
            rows.append(("NCA details", "needs prod.keys (~/.switch/prod.keys)"))
        }
        if !cnmtFile.isEmpty { rows.append(("CNMT file", cnmtFile)) }
        else if cnmtBin != nil { rows.append(("CNMT file", "(binary CNMT in Meta NCA)")) }

        var meta: [String: MetaValue] = [
            "TitleId": .string(tid),
            "Version": .string(ver),
            "Kind": .string(ctype),
            "RequiredSystemVersion": .string(sysver),
            "NcaCount": .string("\(ncaCount)"),
        ]
        if !cnmtFile.isEmpty { meta["CnmtFile"] = .string(cnmtFile) }
        for (i, e) in entries.enumerated() where e.ncaDetail != nil {
            meta["NCA \(i)"] = .string(e.ncaDetail ?? "")
        }

        // NACP: the official title, publisher and display version live in the
        // Control NCA and only decrypt with prod.keys. Without them the title
        // stays whatever the filename said.
        var title = fname.title.isEmpty ? url.lastPathComponent : fname.title
        var nacpIcon: (name: String, data: Data)?
        if let keys, let coff = controlOff,
           let nacp = ncaControlInfo(r, at: coff, ticket: ticket, keys: keys) {
            let official = Self.preferred(nacp.titles)
            if !official.isEmpty { title = official }
            let pub = Self.preferred(nacp.publishers)
            if !pub.isEmpty, let at = rows.firstIndex(where: { $0.0 == "Title ID" }) {
                rows.insert(("Publisher", pub), at: at + 1)
            }
            let disp = nacp.displayVersion
            if !disp.isEmpty, let vi = rows.firstIndex(where: { $0.0 == "Version" }) {
                // "1.2.1" is what a player recognises; the raw title version
                // (e.g. 131072) keeps a row of its own rather than vanishing.
                rows[vi] = ("Version", disp.lowercased().hasPrefix("v") ? disp : "v\(disp)")
                if let raw = UInt64(ver), raw > 0 {
                    rows.insert(("Title Version", "\(raw)"), at: vi + 1)
                }
                ver = disp.lowercased().hasPrefix("v") ? String(disp.dropFirst()) : disp
                meta["Version"] = .string(ver)
            }
            for (k, v) in nacp.titles { meta["NACP title \(k)"] = .string(v) }
            if !nacp.displayVersion.isEmpty { meta["DisplayVersion"] = .string(nacp.displayVersion) }
            if let icon = nacp.icon, !icon.isEmpty {
                // The archive calls these `icon_<Lang>.dat`, but they are
                // JPEGs, and cover picking goes by extension — keeping .dat
                // made the icon invisible in the gallery. Renamed to .jpg,
                // which is also what the original reports.
                let nm = nacp.iconName.isEmpty
                    ? "icon.jpg"
                    : (nacp.iconName as NSString).deletingPathExtension + ".jpg"
                nacpIcon = (nm, icon)
            }
        }

        var list = entries.enumerated().map { i, e in
            PkgEntry(id: i, name: e.name, size: Int64(e.size),
                     source: .offset(e.absOff), codec: e.codec, isTrophyPack: false)
        }
        if let ic = nacpIcon {
            list.append(PkgEntry(id: list.count, name: ic.name, size: Int64(ic.data.count),
                                 source: .cached(ic.data), codec: "JPEG", isTrophyPack: false))
            if let ei = rows.firstIndex(where: { $0.0 == "Entries" }) {
                rows[ei] = ("Entries", "\(list.count)")
            }
        }

        return PkgResult(kind: "switch", path: url, fileSize: size,
                         title: title, rows: rows, entries: list, meta: meta,
                         iconName: nacpIcon?.name ?? iconName,
                         patchTid: tid, ownVersion: ver)
    }

    /// The best per-language key art among an NSP's `<id>.nx.<Lang>.jpg` files.
    ///
    /// Preferred in the interface language's order, falling back to English and
    /// then to whatever exists — a Japanese-only dump still shows art.
    static func coverName(in entries: [RawEntry]) -> String {
        let named = entries.filter { e in
            let n = e.name.lowercased()
            return n.hasSuffix(".jpg") && n.contains(".nx.")
        }
        guard !named.isEmpty else { return "" }
        // Interface language first. The filenames use Switch's own language
        // spellings, so the usual BCP-47 prefixes are mapped onto them.
        // Locale rather than L10n: this runs on the parsing queue, and L10n's
        // helpers are main-actor isolated.
        for tag in Locale.preferredLanguages {
            let t = tag.lowercased()
            let want: String
            switch t.prefix(2) {
            case "zh": want = t.contains("hans") || t.contains("cn") ? "simplifiedchinese" : "traditionalchinese"
            case "ja": want = "japanese"
            case "en": want = "americanenglish"
            case "ko": want = "korean"
            case "fr": want = "french"
            case "de": want = "german"
            case "es": want = "spanish"
            case "it": want = "italian"
            case "ru": want = "russian"
            case "pt": want = "portuguese"
            case "nl": want = "dutch"
            default: continue
            }
            for e in named where e.name.lowercased().contains(want) { return e.name }
        }
        for lang in ["americanenglish", "britishenglish", "japanese"] {
            for e in named where e.name.lowercased().contains(lang) { return e.name }
        }
        return named[0].name
    }

    // MARK: - XCI

    /// Parse an XCI: root HFS0 -> partitions, each another HFS0 file list.
    ///
    /// NCA bodies stay encrypted; only the listing and the header facts are
    /// readable, which is what the original shows too.
    static func parseXCI(_ url: URL, _ r: FileHandleReader, size: Int64) -> PkgResult {
        guard let head = r.read(at: 0, count: 0x200),
              head.count == 0x200,
              Data(head[0x100..<0x104]) == xciMagic else {
            return PkgLoader.failure(url, Message("err.badXci"))
        }
        var hfs0Off = Self.u64le(head, 0x130)
        if hfs0Off == 0 || hfs0Off + 16 > UInt64(size) {
            // Some dumps place the root partition table at a fixed 0x10000.
            hfs0Off = size > 0x10010 ? 0x10000 : 0
        }
        let root = hfs0Entries(r, at: hfs0Off, size: size)
        let partitions = root.map(\.name)

        var entries: [RawEntry] = []
        for pname in ["update", "normal", "secure", "logo"] {
            guard let base = root.first(where: { $0.name == pname })?.absOff else { continue }
            let sub = hfs0Entries(r, at: base, size: size, prefix: pname)
            entries += sub
        }
        for i in entries.indices {
            let ln = entries[i].name.lowercased()
            if ln.hasSuffix(".ncz") { entries[i].codec = "NCZ · compressed" }
            else if ln.hasSuffix(".nca"), entries[i].codec == nil { entries[i].codec = "NCA" }
        }

        let fname = titleFromFilename(url)
        let cart = cartSizes[head[0x10D]] ?? ""

        let keys = loadKeys()
        var title = fname.title.isEmpty ? url.lastPathComponent : fname.title
        var tid = fname.tid
        var ver = fname.ver
        var ctype = ""
        var controlOff: UInt64?
        if let keys {
            // The secure partition's Meta NCA carries the base title's binary
            // CNMT. An XCI has no ticket, so titlekey sections stay encrypted
            // and only standard-crypto packs yield anything.
            if let meta = entries.first(where: {
                $0.name.lowercased().hasPrefix("secure/")
                    && $0.name.lowercased().hasSuffix(".cnmt.nca")
            }), let bin = readCnmtBinary(r, at: meta.absOff, ticket: nil, keys: keys) {
                if !bin.tid.isEmpty { tid = bin.tid }
                if !bin.ver.isEmpty { ver = bin.ver }
                ctype = bin.type
            }
            for i in entries.indices
            where entries[i].name.lowercased().hasPrefix("secure/")
                && entries[i].name.lowercased().hasSuffix(".nca") {
                guard let det = ncaDetail(r, at: entries[i].absOff, keys: keys) else { continue }
                entries[i].ncaDetail = "keygen \(det.crypto), \(det.rights ? "titlekey" : "standard") crypto"
                let sfx = det.rights ? "tk" : "k\(det.crypto)"
                let cur = entries[i].codec ?? ""
                let tname = (cur.isEmpty || cur == "NCA") ? det.typeName : cur
                if !(entries[i].codec ?? "").contains(" · ") {
                    entries[i].codec = "\(tname) · \(sfx)"
                }
                // Content type 2 is the Control NCA — the one holding NACP.
                if det.ctype == 2, controlOff == nil { controlOff = entries[i].absOff }
            }
        }

        var rows: [(String, String)] = [
            ("Platform", "Nintendo Switch (XCI/Gamecard)"),
            ("Title ID", tid.isEmpty ? "-" : tid),
            ("Version", ver.isEmpty ? "-" : "v\(ver)"),
        ]
        if !ctype.isEmpty { rows.append(("Type", ctype)) }
        if !cart.isEmpty { rows.append(("Cartridge", cart)) }
        rows += [
            ("Partitions", partitions.isEmpty ? "-" : partitions.joined(separator: ", ")),
            ("Size", Fmt.size(size)),
            ("Entries", "\(entries.count)"),
        ]
        if keys == nil {
            rows.append(("NCA details", "needs prod.keys (~/.switch/prod.keys)"))
        }

        var meta: [String: MetaValue] = [
            "TitleId": .string(tid),
            "Version": .string(ver),
            "Partitions": .string(partitions.joined(separator: ", ")),
        ]

        // NACP from the Control NCA, the same way an NSP gets it. An XCI has
        // no ticket, so a titlekey-crypto Control NCA simply yields nothing
        // and the filename title stands.
        var nacpIcon: (name: String, data: Data)?
        if let keys, let coff = controlOff,
           let nacp = ncaControlInfo(r, at: coff, ticket: nil, keys: keys) {
            let official = Self.preferred(nacp.titles)
            if !official.isEmpty { title = official }
            let pub = Self.preferred(nacp.publishers)
            if !pub.isEmpty, let at = rows.firstIndex(where: { $0.0 == "Title ID" }) {
                rows.insert(("Publisher", pub), at: at + 1)
            }
            let disp = nacp.displayVersion
            if !disp.isEmpty, let vi = rows.firstIndex(where: { $0.0 == "Version" }) {
                rows[vi] = ("Version", disp.lowercased().hasPrefix("v") ? disp : "v\(disp)")
                if let raw = UInt64(ver), raw > 0 {
                    rows.insert(("Title Version", "\(raw)"), at: vi + 1)
                }
                ver = disp.lowercased().hasPrefix("v") ? String(disp.dropFirst()) : disp
                meta["Version"] = .string(ver)
            }
            for (k, v) in nacp.titles { meta["NACP title \(k)"] = .string(v) }
            if !nacp.displayVersion.isEmpty { meta["DisplayVersion"] = .string(nacp.displayVersion) }
            if let icon = nacp.icon, !icon.isEmpty {
                let nm = nacp.iconName.isEmpty
                    ? "icon.jpg"
                    : (nacp.iconName as NSString).deletingPathExtension + ".jpg"
                nacpIcon = (nm, icon)
            }
        }

        var list = entries.enumerated().map { i, e in
            PkgEntry(id: i, name: e.name, size: Int64(e.size),
                     source: .offset(e.absOff), codec: e.codec, isTrophyPack: false)
        }
        if let ic = nacpIcon {
            list.append(PkgEntry(id: list.count, name: ic.name, size: Int64(ic.data.count),
                                 source: .cached(ic.data), codec: "JPEG", isTrophyPack: false))
            if let ei = rows.firstIndex(where: { $0.0 == "Entries" }) {
                rows[ei] = ("Entries", "\(list.count)")
            }
        }
        return PkgResult(kind: "switch", path: url, fileSize: size,
                         title: title, rows: rows, entries: list, meta: meta,
                         iconName: nacpIcon?.name ?? "", patchTid: tid, ownVersion: ver)
    }

    /// Filename without directories or extension, lowercased — CNMT content
    /// ids are compared case-insensitively.
    private static func stem(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent
        return ((base as NSString).deletingPathExtension).lowercased()
    }

    // MARK: - Little-endian readers

    private static func u32le(_ d: Data, _ o: Int) -> UInt32 {
        guard o + 4 <= d.count else { return 0 }
        return UInt32(d[o]) | UInt32(d[o + 1]) << 8 | UInt32(d[o + 2]) << 16 | UInt32(d[o + 3]) << 24
    }

    private static func u64le(_ d: Data, _ o: Int) -> UInt64 {
        guard o + 8 <= d.count else { return 0 }
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(d[o + i]) << (8 * i) }
        return v
    }
}
