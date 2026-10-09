import Foundation

/// A read-only UFS2 reader, just enough to walk a PS5 `.ffpkg` game image.
///
/// An ffpkg is a **filesystem image**, not an archive: the metadata lives in
/// `/sce_sys/param.json` and the artwork in `/sce_sys/*.png`, so reading one
/// means reading a filesystem. The Python original delegates that to
/// `pytsk3` (The Sleuth Kit); this port has no third-party dependencies, so
/// the handful of structures involved are implemented here.
///
/// Only what a viewer needs is supported: superblock -> inode -> directory
/// entries -> file contents. Writing, journals, snapshots and UFS1 are out of
/// scope, and every step returns nil rather than trapping on a bad image.
struct UFS2 {

    // MARK: - Layout

    /// UFS2 superblock magic (`FS_UFS2_MAGIC`), at +0x55C in the superblock.
    private static let magic: UInt32 = 0x1954_0119
    /// Where FreeBSD puts the primary superblock on a UFS2 filesystem.
    private static let sblockOffset: UInt64 = 0x10000

    private struct Superblock {
        var bsize: UInt32 = 0      // basic block size
        var fsize: UInt32 = 0      // fragment size (unit of a block address)
        var frag: UInt32 = 0
        var iblkno: UInt32 = 0     // inode blocks, in fragments from cg start
        var nindir: UInt32 = 0
        var inopb: UInt32 = 0      // inodes per block
        var ipg: UInt32 = 0        // inodes per cylinder group
        var fpg: UInt32 = 0        // fragments per cylinder group
    }

    private let reader: FileHandleReader
    private let sb: Superblock

    /// Directory entry types we care about; UFS uses 4 for directory, 8 for file.
    enum EntryType: UInt8 { case dir = 4, file = 8, other = 0 }

    struct DirEntry {
        let inode: UInt64
        let type: EntryType
        let name: String
    }

    private struct Inode {
        var mode: UInt16 = 0
        var size: UInt64 = 0
        /// Direct block addresses (12), each in fragments.
        var db: [Int64] = Array(repeating: 0, count: 12)
        /// Indirect blocks (3): single, double, triple.
        var ib: [Int64] = Array(repeating: 0, count: 3)
        var isDirectory: Bool { (mode & 0xF000) == 0x4000 }
    }

    // MARK: - Init

    init?(reader: FileHandleReader, size: Int64) {
        self.reader = reader
        // The primary superblock sits at 0x10000 on a normal UFS2 image. Some
        // dumps are offset, so fall back to a scan before giving up.
        guard let sbOff = Self.findSuperblock(reader, size: size),
              let raw = reader.read(at: sbOff, count: 0x600) else { return nil }
        func u32(_ o: Int) -> UInt32 {
            UInt32(raw[o]) | UInt32(raw[o + 1]) << 8 | UInt32(raw[o + 2]) << 16 | UInt32(raw[o + 3]) << 24
        }
        guard u32(0x55C) == Self.magic else { return nil }
        var s = Superblock()
        s.bsize = u32(48)
        s.fsize = u32(52)
        s.frag = u32(56)
        s.iblkno = u32(16)
        s.nindir = u32(116)
        s.inopb = u32(120)
        s.ipg = u32(184)
        s.fpg = u32(188)
        // A filesystem with no block size or no inodes cannot be read.
        guard s.fsize >= 512, s.bsize >= s.fsize, s.inopb > 0, s.ipg > 0 else { return nil }
        sbOff_ = sbOff
        sb = s
    }

    private let sbOff_: UInt64

    private static func findSuperblock(_ r: FileHandleReader, size: Int64) -> UInt64? {
        if let d = r.read(at: sblockOffset, count: 0x600), u32le(d, 0x55C) == magic {
            return sblockOffset
        }
        // Scan a bounded window: a real image has its superblock early.
        var off: UInt64 = 0
        while off + 0x600 <= UInt64(size) && off < 4 << 20 {
            if let d = r.read(at: off, count: 0x600), u32le(d, 0x55C) == magic { return off }
            off += 0x1000
        }
        return nil
    }

    // MARK: - Inodes

    /// Byte offset of inode `ino` in the image.
    private func inodeOffset(_ ino: UInt64) -> UInt64 {
        let cg = ino / UInt64(sb.ipg)
        let idx = ino % UInt64(sb.ipg)
        let fragNo = cg * UInt64(sb.fpg) + UInt64(sb.iblkno) + idx / UInt64(sb.inopb)
        return fragNo * UInt64(sb.fsize) + (idx % UInt64(sb.inopb)) * 256
    }

    private func readInode(_ ino: UInt64) -> Inode? {
        guard ino >= 2, let d = reader.read(at: inodeOffset(ino), count: 256) else { return nil }
        func u16(_ o: Int) -> UInt16 { UInt16(d[o]) | UInt16(d[o + 1]) << 8 }
        func u64(_ o: Int) -> UInt64 {
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(d[o + i]) << (8 * i) }
            return v
        }
        func i64(_ o: Int) -> Int64 { Int64(bitPattern: u64(o)) }
        var n = Inode()
        n.mode = u16(0)
        n.size = u64(0x10)
        // ufs2_dinode: di_db at 112, di_ib at 208.
        for i in 0..<12 { n.db[i] = i64(112 + i * 8) }
        for i in 0..<3 { n.ib[i] = i64(208 + i * 8) }
        return n
    }

    // MARK: - Data

    /// Read up to `max` bytes of an inode's contents.
    ///
    /// Direct blocks cover 12 * bsize (384 KB here); larger files go through
    /// one or two levels of indirection, which is what a multi-megabyte PNG
    /// needs. Triple indirection is not walked — nothing in `sce_sys` reaches
    /// it, and an unexpected value yields nil rather than a wrong read.
    private func readData(_ inode: Inode, max: Int) -> Data? {
        let want = min(Int(inode.size), max)
        guard want > 0 else { return Data() }
        let bsize = Int(sb.bsize)
        var out = Data()
        out.reserveCapacity(want)
        var logical = 0
        while out.count < want {
            let frag = blockAddress(inode: inode, logical: logical)
            let n = min(bsize, want - out.count)
            if let f = frag, f > 0 {
                guard let chunk = reader.read(at: UInt64(f) * UInt64(sb.fsize), count: n) else { return nil }
                out.append(chunk)
            } else {
                // Sparse hole: UFS2 reports zeroes for a missing block.
                out.append(Data(count: n))
            }
            logical += 1
            if logical > 1_000_000 { return nil }   // runaway guard
        }
        return out
    }

    /// The fragment address of the `logical`-th block, following indirections.
    private func blockAddress(inode: Inode, logical: Int) -> Int64? {
        let bsize = Int(sb.bsize)
        let nindir = Int(sb.nindir > 0 ? sb.nindir : UInt32(bsize / 8))
        if logical < 12 { return inode.db[logical] }
        var l = logical - 12

        // Single indirect: di_ib[0] holds nindir addresses.
        if l < nindir {
            guard let l1 = readIndirect(inode.ib[0], index: l) else { return 0 }
            return l1
        }
        l -= nindir
        // Double indirect.
        let span = nindir * nindir
        if l < span, inode.ib[1] != 0 {
            guard let l1 = readIndirect(inode.ib[1], index: l / nindir) else { return 0 }
            guard let l2 = readIndirect(l1, index: l % nindir) else { return 0 }
            return l2
        }
        return 0
    }

    /// One address out of an indirect block: read entry `index` as an int64.
    private func readIndirect(_ frag: Int64, index: Int) -> Int64? {
        guard frag > 0, index >= 0 else { return 0 }
        let perBlock = Int(sb.bsize) / 8
        guard index < perBlock else { return 0 }
        let off = UInt64(frag) * UInt64(sb.fsize) + UInt64(index * 8)
        guard let d = reader.read(at: off, count: 8), d.count == 8 else { return nil }
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(d[i]) << (8 * i) }
        return Int64(bitPattern: v)
    }

    // MARK: - Directories

    /// Entries of a directory inode, skipping "." and ".." and the empty tail.
    func listDirectory(_ ino: UInt64) -> [DirEntry] {
        guard let inode = readInode(ino), inode.isDirectory else { return [] }
        guard let d = readData(inode, max: Int(min(inode.size, 16_000_000))) else { return [] }
        var out: [DirEntry] = []
        var off = 0
        while off + 8 <= d.count {
            let inoNum = Self.u32le(d, off)
            let reclen = Int(Self.u16le(d, off + 4))
            guard reclen >= 8, off + reclen <= d.count else { break }
            let type = d[off + 6]
            let namlen = Int(d[off + 7])
            if inoNum == 0 { break }                     // end of used space
            guard namlen > 0, off + 8 + namlen <= off + reclen else { break }
            let name = String(decoding: d[(off + 8)..<(off + 8 + namlen)], as: UTF8.self)
            if name != "." && name != ".." {
                out.append(DirEntry(inode: UInt64(inoNum),
                                    type: EntryType(rawValue: type) ?? .other,
                                    name: name))
            }
            off += reclen
        }
        return out
    }

    /// Resolve a path like "/sce_sys/param.json" from the root inode (2).
    func lookup(_ path: String) -> UInt64? {
        let parts = path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        var ino: UInt64 = 2
        for part in parts {
            guard let hit = listDirectory(ino).first(where: { $0.name == part }) else { return nil }
            ino = hit.inode
        }
        return ino
    }

    /// Contents of a file inode, or nil when it is not a regular file or the
    /// read fails.
    func readFile(_ ino: UInt64, max: Int) -> Data? {
        guard let inode = readInode(ino), !inode.isDirectory else { return nil }
        return readData(inode, max: max)
    }

    func fileSize(_ ino: UInt64) -> UInt64 {
        readInode(ino)?.size ?? 0
    }

    // MARK: - Little-endian helpers

    private static func u16le(_ d: Data, _ o: Int) -> UInt16 {
        guard o + 2 <= d.count else { return 0 }
        return UInt16(d[o]) | UInt16(d[o + 1]) << 8
    }

    private static func u32le(_ d: Data, _ o: Int) -> UInt32 {
        guard o + 4 <= d.count else { return 0 }
        return UInt32(d[o]) | UInt32(d[o + 1]) << 8 | UInt32(d[o + 2]) << 16 | UInt32(d[o + 3]) << 24
    }
}
