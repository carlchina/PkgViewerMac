import Foundation
import CZlib

/// Random-access byte reader shared by every container backend: the on-disk
/// file (`FileHandleReader`), a PFSC-compressed inner image (`PFSCView`), or an
/// in-memory buffer. `ExfatImage` and `PFS` are written against this so a
/// `.ffpfsc` (which nests three of these layers) only ever reads the blocks it
/// actually needs, never materialising the multi-gigabyte inner image.
protocol RandomByteReader: AnyObject {
    var fileSize: Int64 { get }
    func readBytes(at offset: Int64, count: Int) -> Data?
}

extension FileHandleReader: RandomByteReader {
    func readBytes(at offset: Int64, count: Int) -> Data? {
        read(at: UInt64(offset), count: count)
    }
}

// MARK: - Little-endian Data helpers

private extension Data {
    func le16(_ o: Int) -> UInt16 {
        guard o + 2 <= count else { return 0 }
        return subdata(in: o..<(o + 2)).withUnsafeBytes { $0.load(as: UInt16.self) }.littleEndian
    }
    func le32(_ o: Int) -> UInt32 {
        guard o + 4 <= count else { return 0 }
        return subdata(in: o..<(o + 4)).withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
    }
    func le32s(_ o: Int) -> Int32 { Int32(bitPattern: le32(o)) }
    func le64(_ o: Int) -> UInt64 {
        guard o + 8 <= count else { return 0 }
        return subdata(in: o..<(o + 8)).withUnsafeBytes { $0.load(as: UInt64.self) }.littleEndian
    }
    func le64s(_ o: Int) -> Int64 { Int64(bitPattern: le64(o)) }
}

/// Inflate a single zlib-wrapped stream (the format `mkpfs` uses for PFSC
/// blocks) into a `logicalBlockSize`-byte buffer. The Apple `Compression`
/// framework's `COMPRESSION_ZLIB` is broken under the 26.x SDK and only emits a
/// ~1:1 partial inflate, so this goes through system libz via `CZlib`.
private func inflateZlib(_ src: Data, into capacity: Int) -> Data? {
    guard src.count > 0 else { return Data() }
    guard capacity > 0 else { return nil }
    var out = [UInt8](repeating: 0, count: capacity)
    var outLen: size_t = 0
    let rc = src.withUnsafeBytes { (sb: UnsafeRawBufferPointer) -> Int32 in
        guard let sp = sb.bindMemory(to: UInt8.self).baseAddress else { return -1 }
        return czlib_inflate(sp, src.count, &out, capacity, &outLen)
    }
    guard rc == 0, outLen == capacity else { return nil }
    return Data(out)
}

// MARK: - PFSC on-demand view

/// A `RandomByteReader` over the decompressed logical bytes of a PFSC-compressed
/// inode payload, decoded block by block without holding the whole image in
/// memory.
///
/// PFSC layout (all little-endian): a 0x30 header — `magic` "PFSC"
/// (0x43534650), `unk4`=0, `unk8`=6, `lbs`=0x10000, `lbs2`=0x10000,
/// `block_offsets_offset` (q), `data_offset` (Q), `logical_size` (q) — followed
/// by a `(block_count + 1)` entry block-offset table and the stored blocks. A
/// stored block equal to `lbs` is raw; a shorter one is a zlib stream.
final class PFSCView: RandomByteReader {
    let source: RandomByteReader
    let base: Int64
    let logicalBlockSize: Int
    let blockCount: Int
    let offsets: [Int]          // relative to `base`
    let fileSize: Int64

    private var cache: [Int: Data] = [:]
    private let lock = NSLock()

    init?(source: RandomByteReader, base: Int64) {
        guard let head = source.readBytes(at: base, count: 0x30), head.count >= 0x30 else { return nil }
        let magic = head.le32(0)
        let unk4 = head.le32s(4)
        let unk8 = head.le32s(8)
        let lbs = Int(head.le32(12))
        let lbs2 = Int(head.le64s(16))
        let boff = Int(head.le64(24))
        let dataOff = Int64(head.le64(32))
        let logical = Int64(head.le64(40))
        guard magic == 0x4353_4650,
              unk4 == 0, unk8 == 6,
              lbs == 0x10000, lbs2 == lbs,
              logical > 0, logical % Int64(lbs) == 0,
              boff >= 0x30, dataOff >= 0x10000 else { return nil }
        let bc = Int(logical / Int64(lbs))
        guard let table = source.readBytes(at: base + Int64(boff), count: (bc + 1) * 8),
              table.count == (bc + 1) * 8 else { return nil }
        var offs: [Int] = []
        offs.reserveCapacity(bc + 1)
        for i in 0...bc { offs.append(Int(table.le64(i * 8))) }
        guard offs[0] == Int(dataOff) else { return nil }

        self.source = source
        self.base = base
        self.logicalBlockSize = lbs
        self.blockCount = bc
        self.offsets = offs
        self.fileSize = logical
    }

    func readBytes(at offset: Int64, count: Int) -> Data? {
        guard offset >= 0, count >= 0 else { return nil }
        let start = offset
        let end = min(offset + Int64(count), fileSize)
        guard start <= end else { return nil }
        var out = Data(capacity: Int(end - start))
        var pos = start
        while pos < end {
            let block = Int(pos) / logicalBlockSize
            let within = Int(pos) % logicalBlockSize
            let take = min(logicalBlockSize - within, Int(end - pos))
            guard let blk = decodeBlock(block) else { return nil }
            out.append(blk.subdata(in: within..<(within + take)))
            pos += Int64(take)
        }
        return out
    }

    private func decodeBlock(_ idx: Int) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        if let c = cache[idx] { return c }
        guard idx >= 0, idx < blockCount else { return nil }
        let so = offsets[idx]
        let eo = offsets[idx + 1]
        let len = eo - so
        guard len > 0, let stored = source.readBytes(at: base + Int64(so), count: len) else { return nil }
        let blk: Data
        if stored.count == logicalBlockSize {
            blk = stored
        } else if stored.count < logicalBlockSize, let d = inflateZlib(stored, into: logicalBlockSize), d.count == logicalBlockSize {
            blk = d
        } else {
            return nil
        }
        if cache.count > 64 { cache.removeAll() }
        cache[idx] = blk
        return blk
    }
}

/// A window into a range of another `RandomByteReader`, used for the payload of
/// a plain (uncompressed) PFS inode so it can be handed to a nested parser —
/// e.g. the inner PFS inside a `.ffpfsc` — without copying the bytes.
final class SubReader: RandomByteReader {
    let source: RandomByteReader
    let base: Int64
    let fileSize: Int64
    init(source: RandomByteReader, base: Int64, size: Int64) {
        self.source = source
        self.base = base
        self.fileSize = size
    }
    func readBytes(at offset: Int64, count: Int) -> Data? {
        let start = max(0, offset)
        let end = min(offset + Int64(count), fileSize)
        guard start <= end else { return nil }
        return source.readBytes(at: base + start, count: Int(end - start))
    }
}

// MARK: - PFS (PlayStation File System) reader

/// A self-contained reader for the PFS image format used by mkpfs-generated
/// `.ffpfsc` files (and by the inner image those wrap).
///
/// A PFS image is a filesystem, not an archive: the metadata lives in an inode
/// table and the content in directory entries. Only the subset needed by a
/// viewer is implemented — header, inode table (unsigned 32-bit layout), the
/// `uroot` directory tree, and per-file payload reads. Encrypted/signed images
/// are rejected up front (no EKPFS key is bundled).
struct PFS {
    let reader: RandomByteReader
    let blockSize: Int
    let inodes: [Inode]

    private var fileInodes: [String: Int] = [:]   // "sce_sys/param.json" -> inode number
    private var dirInodes: [String: Int] = [:]    // "" -> uroot, "sce_sys" -> inode number
    private var direntsByInode: [Int: [(name: String, inode: Int, isDir: Bool)]] = [:]

    struct Inode {
        let number: Int
        let mode: UInt16
        let flags: UInt32
        let size: Int64
        let sizeCompressed: Int64
        let blocks: Int
        let db: [Int32]
        let isDir: Bool
        let isFile: Bool
        let isCompressed: Bool
        var storedSize: Int { isCompressed ? Int(size) : Int(sizeCompressed) }
        var logicalSize: Int { isCompressed ? Int(sizeCompressed) : Int(size) }
        var baseBlock: Int { Int(db[0]) }
    }

    /// PFS magic at header offset 8.
    private static let magic: UInt64 = 20130315

    init?(reader: RandomByteReader) {
        self.reader = reader
        guard let h = reader.readBytes(at: 0, count: 0x400), h.count >= 0x400 else { return nil }
        guard h.le64(8) == Self.magic else { return nil }
        let mode = h.le16(0x1C)
        // FPKG/ffpfsc images in the wild are neither signed nor encrypted; we
        // have no EKPFS key, so refuse anything that would need one.
        guard (Int(mode) & 0x4) == 0 else { return nil }
        let bs = Int(h.le32(0x20))
        guard bs > 0, (bs & (bs - 1)) == 0 else { return nil }
        let dinodeCount = Int(h.le64(0x30))
        let dinodeBlockCount = Int(h.le64(0x40))
        guard dinodeCount > 0, dinodeBlockCount > 0 else { return nil }
        self.blockSize = bs

        // Inode table: starts at block 1, `dinodeBlockCount` blocks, 0xA8 bytes
        // (unsigned, 32-bit) per inode.
        let inodeSize = 0xA8
        let perBlock = bs / inodeSize
        var inos: [Inode] = []
        inos.reserveCapacity(dinodeCount)
        for b in 0..<dinodeBlockCount {
            guard let block = reader.readBytes(at: Int64(bs + b * bs), count: bs) else { return nil }
            for i in 0..<perBlock {
                guard inos.count < dinodeCount else { break }
                let off = i * inodeSize
                guard let ino = Self.parseInode(block, off: off, number: inos.count) else { continue }
                inos.append(ino)
            }
        }
        self.inodes = inos

        // Super-root sits right after the inode table; it names the `uroot`,
        // `flat_path_table` and `collision_resolver` inodes. We only need uroot.
        let superOff = Int64((1 + dinodeBlockCount) * bs)
        guard let sblob = reader.readBytes(at: superOff, count: bs) else { return nil }
        var uroot: Int?
        for e in Self.parseDirents(sblob) where e.name == "uroot" {
            uroot = e.inode
        }
        guard let uroot, uroot < inos.count, inos[uroot].isDir else { return nil }

        var files: [String: Int] = [:]
        var dirs: [String: Int] = ["": uroot]
        var dbe: [Int: [(String, Int, Bool)]] = [:]
        var visited: Set<Int> = []
        walk(dirInode: uroot, rel: "", files: &files, dirs: &dirs, dbe: &dbe, visited: &visited)

        self.fileInodes = files
        self.dirInodes = dirs
        self.direntsByInode = dbe
    }

    // MARK: - Public lookups

    /// Payload bytes of a file by its full path (e.g. `"sce_sys/param.json"`).
    func fileData(_ path: String) -> Data? {
        guard let n = fileInodes[path] else { return nil }
        return readInodePayload(inodes[n])
    }

    /// A `RandomByteReader` over a file's payload without materialising it.
    /// For a compressed inode this is the on-demand `PFSCView`; for a plain one
    /// a thin window into the backing reader. Lets the inner image of a
    /// `.ffpfsc` be opened directly, so its multi-gigabyte body is never read
    /// whole — only the blocks behind `param.json` and the cover PNGs are.
    func fileReader(_ path: String) -> RandomByteReader? {
        guard let n = fileInodes[path] else { return nil }
        return inodeReader(inodes[n])
    }

    /// Entries of a directory by path.
    func listDir(_ path: String) -> [(name: String, inode: Int, isDir: Bool)] {
        guard let n = dirInodes[path] else { return [] }
        return direntsByInode[n] ?? []
    }

    // MARK: - Inode / directory parsing

    private static func parseInode(_ b: Data, off: Int, number: Int) -> Inode? {
        let m = b.le16(off + 0)
        let flags = b.le32(off + 4)
        let size = Int64(bitPattern: b.le64(off + 8))
        let sizeC = Int64(bitPattern: b.le64(off + 0x10))
        let blocks = Int(b.le32(off + 0x60))
        var db: [Int32] = []
        db.reserveCapacity(12)
        for i in 0..<12 { db.append(b.le32s(off + 0x64 + i * 4)) }
        let isDir = (Int(m) & 0x4000) != 0
        let isFile = (Int(m) & 0x8000) != 0
        let comp = (Int(flags) & 0x1) != 0
        return Inode(number: number, mode: m, flags: flags, size: size,
                     sizeCompressed: sizeC, blocks: blocks, db: db,
                     isDir: isDir, isFile: isFile, isCompressed: comp)
    }

    private static func parseDirents(_ payload: Data) -> [(name: String, inode: Int, isDir: Bool)] {
        var out: [(String, Int, Bool)] = []
        var off = 0
        while off + 16 <= payload.count {
            let inodeNum = Int(payload.le32(off))
            let typeCode = Int(payload.le32s(off + 4))
            let nameLen = Int(payload.le32s(off + 8))
            let entSize = Int(payload.le32s(off + 12))
            if inodeNum == 0, typeCode == 0, nameLen == 0, entSize == 0 { break }
            guard entSize >= 17, entSize % 8 == 0,
                  nameLen >= 0, nameLen <= entSize - 16,
                  off + entSize <= payload.count else { break }
            let nameBytes = payload.subdata(in: (off + 16)..<(off + 16 + nameLen))
            let name = String(decoding: nameBytes, as: UTF8.self)
            out.append((name, inodeNum, typeCode == 3))
            off += entSize
        }
        return out
    }

    private func readInodePayload(_ ino: Inode) -> Data? {
        guard let r = inodeReader(ino) else { return nil }
        return r.readBytes(at: 0, count: ino.logicalSize)
    }

    /// Build the reader that backs an inode's payload. Empty files return a
    /// zero-length window; compressed inodes return a `PFSCView`; the rest a
    /// `SubReader` over their data blocks.
    private func inodeReader(_ ino: Inode) -> RandomByteReader? {
        let base = Int64(ino.baseBlock) * Int64(blockSize)
        if ino.blocks == 0 {
            return SubReader(source: reader, base: base, size: 0)
        }
        if ino.isCompressed {
            return PFSCView(source: reader, base: base)
        }
        return SubReader(source: reader, base: base, size: Int64(ino.storedSize))
    }

    private func walk(dirInode: Int, rel: String,
                      files: inout [String: Int], dirs: inout [String: Int],
                      dbe: inout [Int: [(String, Int, Bool)]],
                      visited: inout Set<Int>) {
        guard dirInode < inodes.count, inodes[dirInode].isDir else { return }
        guard !visited.contains(dirInode) else { return }
        visited.insert(dirInode)
        let ino = inodes[dirInode]
        guard let payload = readInodePayload(ino) else { return }
        let entries = Self.parseDirents(payload)
        dbe[dirInode] = entries.map { ($0.name, $0.inode, $0.isDir) }
        for e in entries {
            if e.name == "." || e.name == ".." { continue }
            let child = rel.isEmpty ? e.name : rel + "/" + e.name
            guard e.inode < inodes.count else { continue }
            let childIno = inodes[e.inode]
            if e.isDir {
                dirs[child] = e.inode
                walk(dirInode: e.inode, rel: child, files: &files, dirs: &dirs, dbe: &dbe, visited: &visited)
            } else if childIno.isFile {
                files[child] = e.inode
            }
        }
    }
}
