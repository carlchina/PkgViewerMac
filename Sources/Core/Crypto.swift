import Foundation

/// Self-contained crypto primitives.
///
/// The Command Line Tools SDK ships only a partial CommonCrypto interface
/// (the CBC/ECB mode constants and SHA-1 are missing from some SDK slices), and
/// CryptoKit is unavailable for AES in raw mode. These compact
/// implementations keep the build working with just a Swift toolchain and
/// avoid linking against a system module that is not consistently exported.
enum Crypto {

    // MARK: - SHA-1

    /// SHA-1 digest. Used for the PS3 debug-package keystream.
    static func sha1(_ message: Data) -> Data {
        var h0: UInt32 = 0x6745_2301
        var h1: UInt32 = 0xEFCD_AB89
        var h2: UInt32 = 0x98BA_DCFE
        var h3: UInt32 = 0x1032_5476
        var h4: UInt32 = 0xC3D2_E1F0

        let ml = UInt64(message.count) &* 8
        var msg = [UInt8](message)
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in stride(from: 56, through: 0, by: -8) {
            msg.append(UInt8truncating(ml >> UInt64(i)))
        }

        var w = [UInt32](repeating: 0, count: 80)
        for chunkStart in stride(from: 0, to: msg.count, by: 64) {
            for i in 0..<16 {
                let o = chunkStart + i * 4
                w[i] = (UInt32(msg[o]) << 24) | (UInt32(msg[o + 1]) << 16)
                     | (UInt32(msg[o + 2]) << 8) | UInt32(msg[o + 3])
            }
            for i in 16..<80 {
                w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1)
            }
            var (a, b, c, d, e) = (h0, h1, h2, h3, h4)
            for i in 0..<80 {
                let f: UInt32
                let k: UInt32
                switch i {
                case 0..<20:  f = (b & c) | (~b & d);            k = 0x5A82_7999
                case 20..<40: f = b ^ c ^ d;                     k = 0x6ED9_EBA1
                case 40..<60: f = (b & c) | (b & d) | (c & d);  k = 0x8F1B_BCDC
                default:      f = b ^ c ^ d;                     k = 0xCA62_C1D6
                }
                let temp = rotl(a, 5) &+ f &+ e &+ k &+ w[i]
                e = d; d = c; c = rotl(b, 30); b = a; a = temp
            }
            h0 = h0 &+ a; h1 = h1 &+ b; h2 = h2 &+ c; h3 = h3 &+ d; h4 = h4 &+ e
        }

        var out = [UInt8]()
        out.reserveCapacity(20)
        for h in [h0, h1, h2, h3, h4] {
            out.append(UInt8((h >> 24) & 0xFF))
            out.append(UInt8((h >> 16) & 0xFF))
            out.append(UInt8((h >> 8) & 0xFF))
            out.append(UInt8(h & 0xFF))
        }
        return Data(out)
    }

    private static func rotl(_ v: UInt32, _ n: UInt32) -> UInt32 {
        (v << n) | (v >> (32 - n))
    }

    private static func UInt8truncating(_ v: UInt64) -> UInt8 { UInt8(v & 0xFF) }

    // MARK: - AES-128

    private static let sbox: [UInt8] = [
        0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
        0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
        0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
        0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
        0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
        0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
        0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
        0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
        0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
        0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
        0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
        0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
        0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
        0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
        0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
        0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16,
    ]

    private static let rcon: [UInt8] = [0x01,0x02,0x04,0x08,0x10,0x20,0x40,0x80,0x1b,0x36]

    /// Expanded AES-128 round keys (11 x 16 bytes).
    private static func expandKey(_ key: [UInt8]) -> [[UInt8]] {
        precondition(key.count == 16)
        // Build the 44-word key schedule as a flat byte array, then slice it
        // into 11 round keys of 16 bytes each.
        var w = key
        for i in 4..<44 {
            var temp = Array(w[(i - 1) * 4..<(i - 1) * 4 + 4])
            if i % 4 == 0 {
                // RotWord + SubWord + Rcon (RotWord on [a,b,c,d] gives [b,c,d,a]).
                temp = [sbox[Int(temp[1])] ^ rcon[i / 4 - 1], sbox[Int(temp[2])],
                        sbox[Int(temp[3])], sbox[Int(temp[0])]]
            }
            let prev = Array(w[(i - 4) * 4..<(i - 4) * 4 + 4])
            w.append(contentsOf: zip(prev, temp).map { $0 ^ $1 })
        }
        return (0..<11).map { Array(w[$0 * 16..<($0 + 1) * 16]) }
    }

    private static func xtime(_ a: UInt8) -> UInt8 {
        let hi = a & 0x80
        let s = a << 1
        return hi != 0 ? (s ^ 0x1B) : s
    }

    private static func mul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        var result: UInt8 = 0
        var x = a, y = b
        while y != 0 {
            if y & 1 != 0 { result ^= x }
            x = xtime(x)
            y >>= 1
        }
        return result
    }

    /// Encrypt one 16-byte block with AES-128.
    static func aesEncryptBlock(key: [UInt8], block: [UInt8]) -> [UInt8]? {
        guard key.count == 16 else { return nil }
        var b = block.count == 16 ? block : block + [UInt8](repeating: 0, count: max(0, 16 - block.count))
        let rk = expandKey(key)

        func addRoundKey(_ r: Int) {
            for i in 0..<16 { b[i] ^= rk[r][i] }
        }
        addRoundKey(0)

        for round in 1...10 {
            // SubBytes
            for i in 0..<16 { b[i] = sbox[Int(b[i])] }
            // ShiftRows (column-major state layout)
            let t = b
            for row in 1..<4 {
                for col in 0..<4 {
                    b[col * 4 + row] = t[((col + row) % 4) * 4 + row]
                }
            }
            // MixColumns (skipped in the final round)
            if round != 10 {
                for col in 0..<4 {
                    let a0 = b[col * 4], a1 = b[col * 4 + 1], a2 = b[col * 4 + 2], a3 = b[col * 4 + 3]
                    b[col * 4]     = mul(a0, 2) ^ mul(a1, 3) ^ a2 ^ a3
                    b[col * 4 + 1] = a0 ^ mul(a1, 2) ^ mul(a2, 3) ^ a3
                    b[col * 4 + 2] = a0 ^ a1 ^ mul(a2, 2) ^ mul(a3, 3)
                    b[col * 4 + 3] = mul(a0, 3) ^ a1 ^ a2 ^ mul(a3, 2)
                }
            }
            addRoundKey(round)
        }
        return b
    }

    /// AES-128 ECB encrypt of a single block (no padding applied).
    static func aesECBEncrypt(key: [UInt8], block: [UInt8]) -> [UInt8]? {
        aesEncryptBlock(key: key, block: block)
    }

    // MARK: - AES inverse (for CBC decrypt)

    private static let invSbox: [UInt8] = {
        var inv = [UInt8](repeating: 0, count: 256)
        for i in 0..<256 { inv[Int(sbox[i])] = UInt8(i) }
        return inv
    }()

    private static func mulInv(_ a: UInt8, _ b: UInt8) -> UInt8 {
        var result: UInt8 = 0
        var x = a, y = b
        while y != 0 {
            if y & 1 != 0 { result ^= x }
            x = xtime(x)
            y >>= 1
        }
        return result
    }

    /// Decrypt one 16-byte block with AES-128.
    static func aesDecryptBlock(key: [UInt8], block: [UInt8]) -> [UInt8]? {
        guard key.count == 16, block.count == 16 else { return nil }
        let rk = expandKey(key)
        var b = block

        func addRoundKey(_ r: Int) {
            for i in 0..<16 { b[i] ^= rk[r][i] }
        }
        addRoundKey(10)

        for round in stride(from: 9, through: 0, by: -1) {
            // InvShiftRows
            let t = b
            for row in 1..<4 {
                for col in 0..<4 {
                    b[((col + row) % 4) * 4 + row] = t[col * 4 + row]
                }
            }
            // InvSubBytes
            for i in 0..<16 { b[i] = invSbox[Int(b[i])] }
            addRoundKey(round)
            // InvMixColumns (skipped after the last round key)
            if round != 0 {
                for col in 0..<4 {
                    let a0 = b[col * 4], a1 = b[col * 4 + 1], a2 = b[col * 4 + 2], a3 = b[col * 4 + 3]
                    b[col * 4]     = mulInv(a0, 14) ^ mulInv(a1, 11) ^ mulInv(a2, 13) ^ mulInv(a3, 9)
                    b[col * 4 + 1] = mulInv(a0, 9) ^ mulInv(a1, 14) ^ mulInv(a2, 11) ^ mulInv(a3, 13)
                    b[col * 4 + 2] = mulInv(a0, 13) ^ mulInv(a1, 9) ^ mulInv(a2, 14) ^ mulInv(a3, 11)
                    b[col * 4 + 3] = mulInv(a0, 11) ^ mulInv(a1, 13) ^ mulInv(a2, 9) ^ mulInv(a3, 14)
                }
            }
        }
        return b
    }

    /// AES-128 CBC decrypt where `iv` is the chaining value for the *first*
    /// block, which need not be the real IV. Used to decrypt a slice of a
    /// CBC stream without touching the blocks before it.
    static func aesCBCDecryptWithChaining(key: [UInt8], iv: [UInt8], data: [UInt8]) -> [UInt8]? {
        guard key.count == 16, iv.count == 16 else { return nil }
        let blocks = data.count / 16
        guard blocks > 0 else { return [] }
        var out = [UInt8]()
        out.reserveCapacity(blocks * 16)
        var prev = iv
        for i in 0..<blocks {
            let block = Array(data[(i * 16)..<((i + 1) * 16)])
            guard let dec = aesDecryptBlock(key: key, block: block) else { return nil }
            for j in 0..<16 { out.append(dec[j] ^ prev[j]) }
            prev = block
        }
        return out
    }

    /// AES-128 CBC decrypt of whole blocks; callers strip padding themselves.
    static func aesCBCDecrypt(key: [UInt8], iv: [UInt8], data: [UInt8]) -> [UInt8]? {
        guard key.count == 16, iv.count == 16 else { return nil }
        let blocks = data.count / 16
        guard blocks > 0 else { return [] }
        var out = [UInt8]()
        out.reserveCapacity(blocks * 16)
        var prev = iv
        for i in 0..<blocks {
            let block = Array(data[(i * 16)..<((i + 1) * 16)])
            guard let dec = aesDecryptBlock(key: key, block: block) else { return nil }
            for j in 0..<16 { out.append(dec[j] ^ prev[j]) }
            prev = block
        }
        return out
    }
}
