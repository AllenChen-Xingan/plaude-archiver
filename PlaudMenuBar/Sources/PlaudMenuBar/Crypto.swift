import Foundation
import CryptoKit
import CommonCrypto
import Security

enum CryptoError: Error, CustomStringConvertible {
    case message(String)
    var description: String { if case .message(let m) = self { return m }; return "crypto error" }
}

enum Crypto {

    // MARK: base64url

    static func base64urlDecode(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    // MARK: Fernet (x-encrypt-response: 1)
    // Key baked into the Plaud app (class wng). 32 bytes: HMAC key [0:16], AES key [16:32].

    static let fernetKey = base64urlDecode("8rRmMCskL3NaUiGr-UsmEEeI8NKH-ZfeGbpRGqSLpuI=")!

    static func fernetDecrypt(_ token: String) throws -> Data {
        guard let raw = base64urlDecode(token.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw CryptoError.message("Fernet: bad base64")
        }
        guard raw.count >= 73, raw[raw.startIndex] == 0x80 else {
            throw CryptoError.message("Fernet: bad version/length")
        }
        let body = raw.prefix(raw.count - 32)
        let mac = raw.suffix(32)
        let hmacKey = SymmetricKey(data: fernetKey.prefix(16))
        let good = HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: body, using: hmacKey)
        guard good else { throw CryptoError.message("Fernet: HMAC check failed") }
        let iv = raw.subdata(in: raw.startIndex.advanced(by: 9) ..< raw.startIndex.advanced(by: 25))
        let ct = raw.subdata(in: raw.startIndex.advanced(by: 25) ..< (raw.startIndex.advanced(by: raw.count - 32)))
        return try aesCBCDecrypt(ct, key: fernetKey.suffix(16), iv: iv)
    }

    static func aesCBCDecrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        var out = Data(count: data.count + kCCBlockSizeAES128)
        let outCapacity = out.count
        var moved = 0
        let status = out.withUnsafeMutableBytes { outBuf in
            data.withUnsafeBytes { dataBuf in
                key.withUnsafeBytes { keyBuf in
                    iv.withUnsafeBytes { ivBuf in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding),
                                keyBuf.baseAddress, key.count,
                                ivBuf.baseAddress,
                                dataBuf.baseAddress, data.count,
                                outBuf.baseAddress, outCapacity, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw CryptoError.message("AES-CBC failed (\(status))") }
        out.removeSubrange(moved..<out.count)
        return out
    }

    // MARK: RSA private key from gen_key PEM; PKCS#1 v1.5 decrypt.

    static func importRSAPrivateKey(pem: Data) throws -> SecKey {
        let text = String(data: pem, encoding: .utf8) ?? ""
        let b64 = text
            .replacingOccurrences(of: "-----BEGIN PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----BEGIN RSA PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END RSA PRIVATE KEY-----", with: "")
            .components(separatedBy: .whitespacesAndNewlines).joined()
        guard let der = Data(base64Encoded: b64) else { throw CryptoError.message("RSA: bad PEM base64") }
        // gen_key returns PKCS#8; SecKeyCreateWithData wants PKCS#1. Unwrap if needed.
        let pkcs1 = text.contains("RSA PRIVATE KEY") ? der : try pkcs8ToPKCS1(der)
        let attrs: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: 2048,
        ]
        var err: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attrs as CFDictionary, &err) else {
            throw CryptoError.message("RSA import failed: \(err?.takeRetainedValue().localizedDescription ?? "?")")
        }
        return key
    }

    // Extract the PKCS#1 RSAPrivateKey from a PKCS#8 PrivateKeyInfo DER.
    private static func pkcs8ToPKCS1(_ der: Data) throws -> Data {
        let b = [UInt8](der)
        var i = 0
        func readTLV() throws -> (tag: UInt8, start: Int, len: Int) {
            guard i + 2 <= b.count else { throw CryptoError.message("DER truncated") }
            let tag = b[i]; i += 1
            var len = Int(b[i]); i += 1
            if len & 0x80 != 0 {
                let n = len & 0x7f
                len = 0
                for _ in 0..<n { len = (len << 8) | Int(b[i]); i += 1 }
            }
            let start = i; i += len
            return (tag, start, len)
        }
        let seq = try readTLV()                 // SEQUENCE PrivateKeyInfo
        guard seq.tag == 0x30 else { throw CryptoError.message("DER: expected SEQUENCE") }
        i = seq.start
        _ = try readTLV()                       // INTEGER version
        let alg = try readTLV(); i = alg.start + alg.len   // SEQUENCE AlgorithmIdentifier (skip)
        let oct = try readTLV()                 // OCTET STRING = PKCS#1
        guard oct.tag == 0x04 else { throw CryptoError.message("DER: expected OCTET STRING") }
        return Data(b[oct.start ..< oct.start + oct.len])
    }

    static func rsaDecryptPKCS1(_ cipher: Data, key: SecKey) throws -> Data {
        var err: Unmanaged<CFError>?
        guard let plain = SecKeyCreateDecryptedData(key, .rsaEncryptionPKCS1, cipher as CFData, &err) else {
            throw CryptoError.message("RSA decrypt failed: \(err?.takeRetainedValue().localizedDescription ?? "?")")
        }
        return plain as Data
    }

    // MARK: Plain ChaCha20 (RFC 8439) for recording file content (fem.a.a).
    // 32-byte key, 12-byte nonce, 32-bit block counter.

    private static func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }

    private static func quarterRound(_ s: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        s[a] = s[a] &+ s[b]; s[d] = rotl(s[d] ^ s[a], 16)
        s[c] = s[c] &+ s[d]; s[b] = rotl(s[b] ^ s[c], 12)
        s[a] = s[a] &+ s[b]; s[d] = rotl(s[d] ^ s[a], 8)
        s[c] = s[c] &+ s[d]; s[b] = rotl(s[b] ^ s[c], 7)
    }

    private static func chachaBlock(key: [UInt32], counter: UInt32, nonce: [UInt32]) -> [UInt8] {
        var state = [UInt32](repeating: 0, count: 16)
        state[0] = 0x61707865; state[1] = 0x3320646e; state[2] = 0x79622d32; state[3] = 0x6b206574
        for i in 0..<8 { state[4 + i] = key[i] }
        state[12] = counter
        for i in 0..<3 { state[13 + i] = nonce[i] }
        var working = state
        for _ in 0..<10 {
            quarterRound(&working, 0, 4, 8, 12)
            quarterRound(&working, 1, 5, 9, 13)
            quarterRound(&working, 2, 6, 10, 14)
            quarterRound(&working, 3, 7, 11, 15)
            quarterRound(&working, 0, 5, 10, 15)
            quarterRound(&working, 1, 6, 11, 12)
            quarterRound(&working, 2, 7, 8, 13)
            quarterRound(&working, 3, 4, 9, 14)
        }
        var out = [UInt8]()
        out.reserveCapacity(64)
        for i in 0..<16 {
            let v = working[i] &+ state[i]
            out.append(UInt8(v & 0xff)); out.append(UInt8((v >> 8) & 0xff))
            out.append(UInt8((v >> 16) & 0xff)); out.append(UInt8((v >> 24) & 0xff))
        }
        return out
    }

    static func chacha20(_ data: Data, key: Data, nonce: Data, counter: UInt32) -> Data {
        func words(_ d: Data) -> [UInt32] {
            var w = [UInt32]()
            var i = d.startIndex
            while i < d.endIndex {
                let b0 = UInt32(d[i]); let b1 = UInt32(d[i+1]); let b2 = UInt32(d[i+2]); let b3 = UInt32(d[i+3])
                w.append(b0 | (b1 << 8) | (b2 << 16) | (b3 << 24))
                i = i.advanced(by: 4)
            }
            return w
        }
        let k = words(key), n = words(nonce)
        let bytes = [UInt8](data)
        var out = [UInt8](repeating: 0, count: bytes.count)
        var blockCounter = counter
        var off = 0
        while off < bytes.count {
            let ks = chachaBlock(key: k, counter: blockCounter, nonce: n)
            let end = min(64, bytes.count - off)
            for i in 0..<end { out[off + i] = bytes[off + i] ^ ks[i] }
            off += end
            blockCounter &+= 1
        }
        return Data(out)
    }

    // MARK: A full recording file ("PLAUD.AI", version 1) -> Ogg Opus.

    static func decryptRecordingFile(_ data: Data, privateKey: SecKey) throws -> Data {
        guard data.count >= 512, data.prefix(8) == Data("PLAUD.AI".utf8) else {
            throw CryptoError.message("not a PLAUD.AI file")
        }
        func u16(_ off: Int) -> Int { Int(data[off]) | (Int(data[off+1]) << 8) }
        func u32(_ off: Int) -> UInt32 {
            UInt32(data[off]) | (UInt32(data[off+1]) << 8) | (UInt32(data[off+2]) << 16) | (UInt32(data[off+3]) << 24)
        }
        let version = u16(8)
        guard version == 1 else {
            throw CryptoError.message("header version \(version) not supported (version 2 = ECDH, protocol 30)")
        }
        let headerSize = u16(10)
        let counter = u32(128)
        let nonce = data.subdata(in: 132..<144)
        let keyCipher = data.subdata(in: 256..<512)
        var contentKey = try rsaDecryptPKCS1(keyCipher, key: privateKey)
        if contentKey.count > 32 { contentKey = contentKey.suffix(32) }  // firmware anomaly fallback
        let body = data.subdata(in: headerSize..<data.count)
        return chacha20(body, key: contentKey, nonce: nonce, counter: counter)
    }
}
