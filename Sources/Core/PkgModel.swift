import Foundation

// MARK: - Parsed result model

/// One file entry inside a package / image / folder.
struct PkgEntry: Identifiable {
    enum Source {
        /// Plain file offset in a container.
        case offset(UInt64)
        /// Regular file on disk (app folder dumps).
        case file(URL)
        /// exFAT cluster chain: (firstCluster, size, noFatChain).
        case exfat(first: UInt32, size: UInt64, noFat: Bool)
        /// PS3 NPDRM entry: decrypt on read with the package key material.
        ///
        /// The package is named by path rather than by an open handle. The
        /// parser's reader is closed as soon as parsing returns, so an entry
        /// that captured it would silently fail every later read — which is
        /// exactly how cover art went missing. Decrypting on demand from the
        /// path keeps the entries valid for the lifetime of the result.
        case ps3(url: URL, dataOff: UInt64, retail: Bool,
                 keymat: Data, fileOff: UInt64)
        /// Bytes already in memory (ffpfsc / ffpkg caches).
        case cached(Data)
    }

    let id: Int
    let name: String
    let size: Int64
    let source: Source
    /// Non-nil for AMPR/LZ4 asset containers.
    var codec: String?
    var isTrophyPack: Bool
}

/// Identity is the entry id plus name — enough for list selection without
/// requiring the backing store (which may hold a file handle) to be Equatable.
extension PkgEntry: Equatable {
    static func == (l: PkgEntry, r: PkgEntry) -> Bool {
        l.id == r.id && l.name == r.name
    }
}

struct PkgResult {
    var kind: String            // "ps5" / "ps4" / "ps3"
    var path: URL
    var fileSize: Int64
    var title: String
    var rows: [(String, String)]
    var entries: [PkgEntry] = []
    var meta: [String: MetaValue] = [:]
    var iconName: String = "icon0.png"
    var patchTid: String = ""
    var ownVersion: String = ""
    /// Localisable failure reason; nil when the file parsed.
    var failed: Message?
    /// PS4 CNT body offset (used by the extract path).
    var bodyOffset: UInt64 = 0

    var rowDict: [String: String] {
        var d: [String: String] = [:]
        for (k, v) in rows where d[k] == nil { d[k] = v }
        return d
    }
}

/// Metadata values keep their original JSON/SFO type so the Details tab can
/// show ints as ints and strings as strings.
enum MetaValue: Hashable {
    case string(String)
    case int(Int)
    case hex(String)
    case nested([String: MetaValue])

    var displayString: String {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .hex(let s): return s
        case .nested: return "{…}"
        }
    }
}

extension Dictionary where Key == String, Value == MetaValue {
    /// Convenience: string value of a key, if it is a string.
    func str(_ key: String) -> String {
        if case .string(let s)? = self[key] { return s }
        return ""
    }

    /// First non-empty string among several SFO/JSON keys.
    func firstStr(_ keys: [String]) -> String {
        for k in keys {
            if let v = self[k] {
                let s = v.displayString.trimmingCharacters(in: .whitespaces)
                if !s.isEmpty { return s }
            }
        }
        return ""
    }
}

extension MetaValue {
    /// Convert a JSON value into a MetaValue, keeping arrays and objects
    /// nested so the Details tab can show the full structure.
    static func from(_ any: Any) -> MetaValue {
        switch any {
        case let v as String: return .string(v)
        case let v as Bool: return .string(v ? "true" : "false")
        case let v as Int: return .int(v)
        case let v as Double: return v == v.rounded() ? .int(Int(v)) : .string(String(v))
        case let v as [Any]:
            var out: [String: MetaValue] = [:]
            for (i, el) in v.enumerated() { out["[\(i)]"] = MetaValue.from(el) }
            return .nested(out)
        case let v as [String: Any]:
            var out: [String: MetaValue] = [:]
            for (k, val) in v { out[k] = MetaValue.from(val) }
            return .nested(out)
        case is NSNull: return .string("")
        default: return .string(String(describing: any))
        }
    }
}

// MARK: - param.sfo

enum SFO {
    /// Parse a PS param.sfo blob. Returns key -> value, or `_error` on failure
    /// (same contract as the Python parse_sfo).
    static func parse(_ data: Data) -> [String: MetaValue] {
        var out: [String: MetaValue] = [:]
        guard data.count > 20 else { return ["_error": .string("too small")] }
        // Magic is \0PSF — compare raw bytes, since a NUL-trimming helper
        // would drop the leading zero byte and never match.
        guard data.count >= 4, Array(data[0..<4]) == [0x00, 0x50, 0x53, 0x46] else {
            let magic = data.prefix(4).map { String(format: "%02x", $0) }.joined(separator: " ")
            return ["_error": .string("bad magic \(magic)")]
        }
        let r = ByteReader(data)
        // Header layout (all little-endian):
        //   0x00 magic "\0PSF" | 0x04 version | 0x08 key_table_offset
        //   0x0C data_table_offset | 0x10 num_entries
        guard let kOff = r.u32le(at: 0x08), let dOff = r.u32le(at: 0x0C),
              let count = r.u32le(at: 0x10) else {
            return ["_error": .string("truncated header")]
        }
        let keyOff = Int(kOff), dataOff = Int(dOff)
        if count > 100_000 || keyOff < 0 || keyOff > data.count { return ["_error": .string("bad header")] }

        for i in 0..<Int(count) {
            let eo = 20 + i * 16
            guard eo + 16 <= data.count else { break }
            guard let keyRel = r.u16le(at: eo), let fmt = r.u16le(at: eo + 2),
                  let dLen = r.u32le(at: eo + 4), let dMax = r.u32le(at: eo + 8),
                  let valRel = r.u32le(at: eo + 12) else { continue }
            let ks = keyOff + Int(keyRel)
            guard let key = r.fixedString(at: ks, length: min(256, max(0, data.count - ks))), !key.isEmpty else { continue }
            let valOff = dataOff + Int(valRel)
            if valOff < 0 || valOff > data.count { continue }

            switch fmt {
            case 0x0204:  // UTF-8 string
                var end = valOff
                let limit = min(valOff + Int(dMax), data.count)
                while end < limit, data[end] != 0 { end += 1 }
                if end == limit && end == valOff + Int(dLen) { end = min(valOff + Int(dLen), data.count) }
                out[key] = .string(String(decoding: data[valOff..<end], as: UTF8.self))
            case 0x0404:  // int32
                out[key] = r.u32le(at: valOff).map { .int(Int($0)) } ?? .string("")
            default:      // binary → hex dump
                let end = min(valOff + Int(dLen), data.count)
                guard valOff <= end else { continue }
                out[key] = .hex(data[valOff..<end].map { String(format: "%02x", $0) }.joined(separator: " "))
            }
        }
        return out
    }
}

// MARK: - param.json

enum ParamJSON {
    /// Build the (title, rows) pair that the Python _param_json_meta returns.
    static func meta(from dict: [String: Any]) -> (title: String, rows: [(String, String)]) {
        let title = localizedTitle(dict)
        let cid = dict["contentId"] as? String ?? ""
        let cat = dict["applicationCategoryType"]
        let ptype: String
        if let n = cat as? Int {
            ptype = n == 0 ? "Application (APP)" : "Type \(n)"
        } else {
            ptype = "-"
        }
        let drm = dict["applicationDrmType"] as? String ?? ""
        var rows: [(String, String)] = []
        rows.append(("Title ID", dict["titleId"] as? String ?? ""))
        rows.append(("Content ID", cid))
        rows.append(("Region", Meta.contentRegion(cid)))
        rows.append(("Type", ptype))
        rows.append(("Content Ver", dict["contentVersion"] as? String ?? ""))
        rows.append(("Master Ver", dict["masterVersion"] as? String ?? ""))
        rows.append(("Concept ID", dict["conceptId"] as? String ?? ""))
        rows.append(("Min. System", Fmt.firmware(dict["requiredSystemSoftwareVersion"])))
        rows.append(("DRM", drm.isEmpty ? "-" : drm.capitalized))
        rows.append(("SDK", Fmt.firmware(dict["sdkVersion"])))
        return (title, rows)
    }

    static func localizedTitle(_ dict: [String: Any]) -> String {
        guard let lp = dict["localizedParameters"] as? [String: Any] else { return "" }
        let lang = lp["defaultLanguage"] as? String ?? "en-US"
        if let entry = lp[lang] as? [String: Any], let t = entry["titleName"] as? String { return t }
        // Fall back to any locale that carries a title.
        for (_, v) in lp {
            if let entry = v as? [String: Any], let t = entry["titleName"] as? String, !t.isEmpty { return t }
        }
        return ""
    }
}
