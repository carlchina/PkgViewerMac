import Foundation

/// Minimal read-only exFAT: boot sector, FAT walk, directory scan.
/// Port of the Python `_Exfat` class, including its "builder leaves the FAT
/// zeroed" fallback that lets contiguous dumps be read without a valid FAT.
final class ExfatImage {
    let reader: FileHandleReader
    let imageSize: Int64
    private let bps: Int
    private let spc: Int
    private let clusterBytes: Int
    private let fatSec: Int
    private let dataSec: Int
    let rootCluster: UInt32

    struct Node {
        let name: String
        let attrs: UInt16
        let first: UInt32
        let size: UInt64
        let noFat: Bool
        var isDir: Bool { (attrs & 0x10) != 0 }
    }

    init?(reader: FileHandleReader) throws {
        self.reader = reader
        self.imageSize = reader.fileSize
        guard let bs = reader.read(at: 0, count: 512), bs.count == 512 else {
            throw ExfatError.notAnImage
        }
        let r = ByteReader(bs)
        let oem = r.fixedString(at: 3, length: 8) ?? ""
        guard oem == "EXFAT   ", r.u8(at: 510) == 0x55, r.u8(at: 511) == 0xAA else {
            throw ExfatError.notAnImage
        }
        guard let bpsShift = r.u8(at: 108), let spcShift = r.u8(at: 109),
              let fatOff = r.u32le(at: 80), let dataOff = r.u32le(at: 88),
              let root = r.u32le(at: 96) else {
            throw ExfatError.notAnImage
        }
        // Sector-size shifts are 0 (512) or higher; clamp to avoid absurd sizes.
        guard bpsShift <= 12, spcShift <= 25 - bpsShift else { throw ExfatError.notAnImage }
        self.bps = 1 << bpsShift
        self.spc = 1 << spcShift
        self.clusterBytes = self.bps * self.spc
        self.fatSec = Int(fatOff)
        self.dataSec = Int(dataOff)
        self.rootCluster = root
    }

    enum ExfatError: Error, LocalizedError {
        case notAnImage
        var errorDescription: String? { "not an exFAT image" }
    }

    func clusterOffset(_ clus: UInt32) -> UInt64 {
        UInt64(dataSec + (Int(clus) - 2) * spc) * UInt64(bps)
    }

    private func fatNext(_ clus: UInt32) -> UInt32? {
        guard let v = reader.read(at: UInt64(fatSec * bps) &+ UInt64(clus) * 4, count: 4),
              let next = ByteReader(v).u32le(at: 0) else { return nil }
        return next >= 0xFFFF_FFF8 ? nil : next
    }

    /// Read a cluster chain, stopping at `size` bytes.
    /// Builders often write files contiguously but leave the FAT zeroed, so a
    /// zero/absent next pointer falls through to the next cluster.
    func readChain(first: UInt32, size: Int, limit: Int = 32_000_000) -> Data {
        guard size > 0 else { return Data() }
        let want = min(size, limit)
        var out = Data()
        out.reserveCapacity(want)
        var clus = first
        var guardCount = 0
        while clus != 0, out.count < want, guardCount < 4_000_000 {
            guardCount += 1
            let off = clusterOffset(clus)
            if Int64(off) >= imageSize { break }
            let take = min(clusterBytes, want - out.count)
            guard let chunk = reader.read(at: off, count: take) else { break }
            out.append(chunk)
            let nxt = fatNext(clus)
            clus = (nxt == nil || nxt == 0) ? clus &+ 1 : nxt!
        }
        return out
    }

    private func rawDir(_ first: UInt32, size: Int, noFat: Bool) -> Data {
        if noFat {
            let off = clusterOffset(first)
            return reader.read(at: off, count: min(size, 1 << 20)) ?? Data()
        }
        return readChain(first: first, size: size, limit: 1 << 24)
    }

    /// List directory entries; pass `want` to stop as soon as a name matches.
    func listDir(first: UInt32, size: Int, noFat: Bool, want: String? = nil) -> [Node] {
        let raw = rawDir(first, size: size, noFat: noFat)
        return parseDir(raw, want: want)
    }

    private func parseDir(_ raw: Data, want: String? = nil) -> [Node] {
        var items: [Node] = []
        var pendingAttrs: UInt16 = 0
        var pendingNames: [String] = []
        var pendingFirst: UInt32 = 0
        var pendingSize: UInt64 = 0
        var pendingNoFat = false
        var havePending = false
        var nameCount: Int = 1

        var i = 0
        while i + 32 <= raw.count {
            let etype = raw[i]
            if etype == 0x00 { break }
            let r = ByteReader(raw)
            if etype == 0x85 {
                pendingAttrs = r.u16le(at: i + 4) ?? 0
                pendingNames = []
                havePending = true
                nameCount = Int(raw[i + 1])
            } else if etype == 0xC0 && havePending {
                let flags = r.u16le(at: i + 2) ?? 0
                pendingNoFat = (flags & 0x02) != 0
                pendingFirst = r.u32le(at: i + 20) ?? 0
                pendingSize = r.u64le(at: i + 24) ?? 0
            } else if etype == 0xC1 && havePending {
                var chars: [UInt16] = []
                for c in 0..<15 {
                    guard let v = r.u16le(at: i + 2 + c * 2), v != 0 else { break }
                    chars.append(v)
                }
                if !chars.isEmpty {
                    pendingNames.append(String(utf16CodeUnits: chars, count: chars.count))
                }
                if pendingNames.count >= max(1, nameCount - 1) {
                    let name = pendingNames.joined()
                    items.append(Node(name: name, attrs: pendingAttrs, first: pendingFirst,
                                      size: pendingSize, noFat: pendingNoFat))
                    havePending = false
                    if let want = want, name.lowercased() == want { break }
                }
            }
            i += 32
        }
        return items
    }

    /// Resolve a path (array of components) to a node.
    func find(_ parts: [String]) -> Node? {
        var clus = rootCluster
        var size: Int64 = 1 << 30
        var noFat = false
        for (depth, part) in parts.enumerated() {
            if depth == 0, part.isEmpty || part.lowercased().hasSuffix(".exfat") { continue }
            let isLast = depth == parts.count - 1
            let want = isLast ? nil : part.lowercased()
            var found: Node?
            for n in listDir(first: clus, size: Int(min(size, Int64(Int32.max))), noFat: noFat, want: want) {
                if n.name.lowercased() == part.lowercased() { found = n; break }
            }
            guard let f = found else { return nil }
            if isLast { return f }
            guard f.isDir else { return nil }
            clus = f.first
            size = Int64(f.size)
            noFat = f.noFat
        }
        return nil
    }

    /// List the entries of a directory given by path components.
    func listPath(_ parts: [String]) -> [Node] {
        guard let c = descend(parts) else { return [] }
        return listDir(first: c.0, size: Int(min(c.1, Int64(Int32.max))), noFat: c.2)
    }

    /// Walk to the directory identified by `parts`, returning
    /// (firstCluster, size, noFat).
    private func descend(_ parts: [String]) -> (UInt32, Int64, Bool)? {
        var clus = rootCluster
        var size: Int64 = 1 << 30
        var noFat = false
        for (depth, part) in parts.enumerated() {
            if depth == 0, part.isEmpty || part.lowercased().hasSuffix(".exfat") { continue }
            let isLast = depth == parts.count - 1
            let want = isLast ? nil : part.lowercased()
            var found: Node?
            for n in listDir(first: clus, size: Int(min(size, Int64(Int32.max))), noFat: noFat, want: want) {
                if n.name.lowercased() == part.lowercased() { found = n; break }
            }
            guard let f = found else { return nil }
            if isLast { return (f.first, Int64(f.size), f.noFat) }
            guard f.isDir else { return nil }
            clus = f.first
            size = Int64(f.size)
            noFat = f.noFat
        }
        return (clus, size, noFat)
    }

    /// Find trophy packs (.trp/.ucp) anywhere in the image.
    /// Tries the known trophy dirs first, then falls back to a bounded walk.
    func scanTrophyPacks(maxDirs: Int = 500) -> [(String, UInt32, UInt64, Bool)] {
        var out: [(String, UInt32, UInt64, Bool)] = []
        for cand in [["sce_sys", "trophy"], ["sce_sys", "trophy2"], ["trophy"], ["trophy2"]] {
            for it in listPath(cand) where !it.isDir {
                let ln = it.name.lowercased()
                if (ln.hasSuffix(".trp") || ln.hasSuffix(".ucp")), it.size > 0, it.size < 300_000_000 {
                    out.append(((cand + [it.name]).joined(separator: "/"), it.first, it.size, it.noFat))
                }
            }
            if !out.isEmpty { return out }
        }
        var stack: [(parts: [String], first: UInt32, size: Int64, noFat: Bool)] =
            [([], rootCluster, 1 << 30, false)]
        var seen = 0
        while !stack.isEmpty && seen < maxDirs {
            let cur = stack.removeLast()
            seen += 1
            for n in listDir(first: cur.first, size: Int(min(cur.size, Int64(Int32.max))), noFat: cur.noFat) {
                if n.name.isEmpty || n.name == "." || n.name == ".." { continue }
                if n.isDir {
                    if cur.parts.count < 5 { stack.append((cur.parts + [n.name], n.first, Int64(n.size), n.noFat)) }
                } else {
                    let ln = n.name.lowercased()
                    if (ln.hasSuffix(".trp") || ln.hasSuffix(".ucp")), n.size > 0, n.size < 300_000_000 {
                        out.append(((cur.parts + [n.name]).joined(separator: "/"), n.first, n.size, n.noFat))
                    }
                }
            }
        }
        return out
    }
}
