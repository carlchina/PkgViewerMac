import Foundation

/// A value guarded by a lock. Parsing and entry reads run off the main actor,
/// so any shared mutable cache needs its own synchronisation rather than
/// relying on actor isolation.
final class NSLockBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    /// Run `body` with exclusive access, returning its result.
    @discardableResult
    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

// MARK: - Byte reading helpers

/// Safe cursor over a byte buffer. All reads are bounds-checked and return
/// nil rather than trapping, mirroring the Python code's try/except style.
struct ByteReader {
    let data: Data
    var offset: Int

    init(_ data: Data, offset: Int = 0) {
        self.data = data
        self.offset = offset
    }

    var remaining: Int { max(0, data.count - offset) }

    mutating func seek(to newOffset: Int) { offset = newOffset }

    mutating func read(_ count: Int) -> Data? {
        guard count >= 0, offset >= 0, offset + count <= data.count else { return nil }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }

    func u8(at o: Int) -> UInt8? {
        guard o >= 0, o < data.count else { return nil }
        return data[o]
    }

    func u16be(at o: Int) -> UInt16? {
        guard o >= 0, o + 2 <= data.count else { return nil }
        return UInt16(data[o]) << 8 | UInt16(data[o + 1])
    }

    func u16le(at o: Int) -> UInt16? {
        guard o >= 0, o + 2 <= data.count else { return nil }
        return UInt16(data[o + 1]) << 8 | UInt16(data[o])
    }

    func u32be(at o: Int) -> UInt32? {
        guard o >= 0, o + 4 <= data.count else { return nil }
        var v: UInt32 = 0
        for i in 0..<4 { v = (v << 8) | UInt32(data[o + i]) }
        return v
    }

    func u32le(at o: Int) -> UInt32? {
        guard o >= 0, o + 4 <= data.count else { return nil }
        var v: UInt32 = 0
        // Least-significant byte first: data[o] is the low byte.
        for i in (0..<4).reversed() { v = (v << 8) | UInt32(data[o + i]) }
        return v
    }

    func u64be(at o: Int) -> UInt64? {
        guard o >= 0, o + 8 <= data.count else { return nil }
        var v: UInt64 = 0
        for i in 0..<8 { v = (v << 8) | UInt64(data[o + i]) }
        return v
    }

    func u64le(at o: Int) -> UInt64? {
        guard o >= 0, o + 8 <= data.count else { return nil }
        var v: UInt64 = 0
        for i in (0..<8).reversed() { v = (v << 8) | UInt64(data[o + i]) }
        return v
    }

    /// Fixed-width string that ends at the first NUL, scanning from `o`.
    /// Returns nil when the range falls outside the buffer.
    func fixedString(at o: Int, length: Int) -> String? {
        guard o >= 0, length >= 0, o + length <= data.count else { return nil }
        let bytes = [UInt8](data[o..<(o + length)])
        // Stop at the first NUL rather than skipping leading ones, so a key
        // that legitimately starts with a zero byte is not silently emptied.
        let end = bytes.firstIndex(of: 0) ?? bytes.count
        return String(decoding: bytes[..<end], as: UTF8.self)
    }

    /// Fixed-width field trimmed of leading and trailing NUL padding.
    func paddedString(at o: Int, length: Int) -> String? {
        guard o >= 0, length >= 0, o + length <= data.count else { return nil }
        let bytes = [UInt8](data[o..<(o + length)])
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
}

// MARK: - Formatting

enum Fmt {
    /// Human byte size, binary units — matches fmt_size() in the Python tool.
    static func size(_ n: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(n)
        var i = 0
        while v >= 1024 && i < units.count - 1 {
            v /= 1024
            i += 1
        }
        return i == 0 ? "\(n) B" : String(format: "%.2f %@", v, units[i])
    }

    /// Decode PS5 firmware hex (0x0250... -> "2.50"). Passes other values through.
    /// Accepts both a hex string and a JSON number, since param.json uses
    /// whichever form the title author happened to emit.
    static func firmware(_ v: Any?) -> String {
        guard let v = v, !(v is NSNull) else { return "-" }
        let n: UInt64
        switch v {
        case let i as Int:
            if i < 0 { return String(i) }
            n = UInt64(i)
        case let d as Double:
            n = UInt64(max(0, d))
        case let s as String:
            let t = s.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return "-" }
            if t.hasPrefix("0x") || t.hasPrefix("0X") {
                n = UInt64(t.dropFirst(2), radix: 16) ?? 0
            } else {
                n = UInt64(t) ?? 0
            }
        default:
            return String(describing: v)
        }
        let top = (n >> 48) & 0xFFFF
        if top == 0 { return String(n) }
        return String(format: "%X.%02X", (top >> 8) & 0xFF, top & 0xFF)
    }

    /// Version cleanup for filenames: "04.040.100" -> "4.40.100".
    /// First segment always unpadded; later ones only when longer than 2 chars.
    static func normalizeVersion(_ ver: String) -> String {
        var out: [String] = []
        for (i, raw) in ver.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false).enumerated() {
            var s = raw.trimmingCharacters(in: .whitespaces)
            if !s.isEmpty, s.allSatisfy(\.isNumber), (i == 0 || s.count > 2) {
                s = String(Int(s) ?? 0)
            }
            if !s.isEmpty { out.append(s) }
        }
        return out.joined(separator: ".")
    }

    /// Strip characters that are illegal in macOS filenames.
    static func sanitizeFilenamePart(_ s: String, limit: Int = 120) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:\0")
        let cleaned = s.unicodeScalars
            .map { illegal.contains($0) ? "-" : Character(String($0)) }
            .reduce(into: "") { $0.append($1) }
        var t = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasPrefix(".") { t.removeFirst() }
        if t.count > limit { t = String(t.prefix(limit)) }
        return t
    }
}

// MARK: - Region / type lookups

enum Meta {
    static let regionNames = ["EP": "Europe", "UP": "Americas", "JP": "Japan", "HP": "Asia"]

    static let regionShort: [String: String] = [
        "Europe": "EU", "Americas": "US", "Japan": "JP", "Asia": "AS",
    ]

    static let ps4CatTypes = ["gd": "Base Game", "ac": "DLC", "gp": "Update"]

    static let ps3TidRegion: [String: String] = [
        "BLUS": "US", "BLES": "EU", "BLJP": "JP", "BLAS": "AS",
        "NPUA": "US", "NPEB": "EU", "NPJB": "JP"
    ]

    /// Region from content-ID prefix (EP0002-... -> Europe).
    static func contentRegion(_ cid: String?) -> String {
        guard let cid = cid, !cid.isEmpty else { return "-" }
        let pre = String(cid.split(separator: "-").first ?? "").prefix(2).uppercased()
        if pre.isEmpty { return "-" }
        return regionNames[String(pre)] ?? String(pre)
    }

    static func ps4PkgType(_ cat: String?) -> String {
        guard let cat = cat, !cat.isEmpty else { return "-" }
        return ps4CatTypes[cat.lowercased()] ?? cat
    }

    /// OFC vs FPKG for PS4 CNT: bit 31 of pkg_type @0x04 (big-endian).
    /// Per psdevwiki/UnPKG: FILE_TYPE_FLAGS_RETAIL = 1 << 31.
    static func cntPackageType(_ hdr: Data) -> String {
        guard hdr.count >= 8, let ptype = ByteReader(hdr).u32be(at: 0x04) else { return "-" }
        return (ptype & 0x8000_0000) != 0 ? "OFC (Official)" : "FPKG (Fake)"
    }

    /// The SFO `SYSTEM_VER` value, as a human-readable firmware version.
    ///
    /// Sony writes these keys in two different shapes depending on the pack:
    ///
    ///   - **Text** — "12.00", "04.7000", "05.050.000". Retail packages use
    ///     this, and it is shown as-is.
    ///   - **BCD integer** — 0x05010000, 0x04080000. Self-built and early
    ///     packages store the version as a packed nibble-BCD value, one byte
    ///     per component. Rendered raw it looks like `0x05010000`, which reads
    ///     like a memory address rather than a version.
    ///
    /// Decoding is strict: every component must be a valid BCD nibble pair
    /// (0–9 in both halves). Anything else is passed through untouched, since
    /// a firmware version is major.minor and the remaining bits are not part
    /// of it — better to show the raw value than to invent a version.
    ///
    /// The value is read via `displayString` rather than `str()` because an
    /// int32 SFO entry parses to `.int`, which `str()` rejects outright — that
    /// made the whole row blank rather than merely undecoded.
    static func systemVersion(_ sfo: [String: MetaValue], key: String = "SYSTEM_VER") -> String {
        let raw = sfo[key]?.displayString.trimmingCharacters(in: .whitespaces) ?? ""
        guard !raw.isEmpty else { return "-" }

        // Already dotted, or any non-numeric form: nothing to decode.
        //
        // The radix is resolved by hand rather than passed as 0. Swift's
        // integer initialisers are traps, not failable ones: `UInt64("12.00",
        // radix: 0)` aborts the process on the dot instead of returning nil,
        // so an SFO holding a plain version string would crash the app.
        // Stripping the 0x and choosing the radix explicitly keeps every
        // non-numeric input on the "return it untouched" path.
        var digits = Substring(raw)
        var radix = 10
        if digits.hasPrefix("0x") || digits.hasPrefix("0X") {
            digits = digits.dropFirst(2)
            radix = 16
        }
        guard !digits.isEmpty, digits.allSatisfy({ $0.isHexDigit }),
              let n = UInt64(digits, radix: radix), n <= 0xFFFF_FFFF else {
            return raw
        }
        guard n >= 0x0100_0000 else { return raw }

        // Both version bytes must be packed BCD, *and* the low 16 bits must be
        // zero. Without that second check any hex whose top two bytes happen to
        // fall in 0x00–0x99 decodes to a plausible-looking version:
        // 0x12345678 would read "12.34", which is worse than showing the raw
        // value because it looks authoritative. (The Python original has this
        // hole; real SYSTEM_VER values leave the low word clear.)
        guard n & 0x0000_FFFF == 0 else { return raw }

        let hi = UInt32((n >> 24) & 0xFF), lo = UInt32((n >> 16) & 0xFF)
        guard isBCD(hi), isBCD(lo) else { return raw }

        let text = String(format: "%02X.%02X", hi, lo)
        // A single-digit major loses its leading zero so "05.01" reads "5.01";
        // two-digit majors such as "12.00" keep theirs.
        return text.hasPrefix("0") ? String(text.dropFirst()) : text
    }

    /// True when both nibbles of a byte are decimal digits.
    private static func isBCD(_ b: UInt32) -> Bool { (b >> 4) <= 9 && (b & 0xF) <= 9 }
}
