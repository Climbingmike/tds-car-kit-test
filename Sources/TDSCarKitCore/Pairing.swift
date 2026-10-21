// SPDX-License-Identifier: GPL-3.0-or-later
// Native adaptation of PlayPort/DiPlay/xcertplay PairVerify and ControlCipher.
import Foundation
import CryptoKit

public enum TLV8 {
    public static func encode(_ fields: [(UInt8, Data)]) -> Data {
        var result = Data()
        for (type, value) in fields {
            if value.isEmpty { result.append(contentsOf: [type, 0]); continue }
            for offset in stride(from: 0, to: value.count, by: 255) {
                let chunk = value.dropFirst(offset).prefix(255)
                result.append(contentsOf: [type, UInt8(chunk.count)]); result.append(chunk)
            }
        }
        return result
    }
    public static func decode(_ data: Data) throws -> [UInt8: Data] {
        guard data.count <= 65536 else { throw ProtocolError.limitExceeded("pairing TLV") }
        var result: [UInt8: Data] = [:]; var offset = 0
        var previousType: UInt8?; var previousLength = 0
        while offset < data.count {
            guard offset + 2 <= data.count else { throw ProtocolError.malformed("TLV header") }
            let type = data.byte(offset), length = Int(data.byte(offset + 1)); offset += 2
            guard offset + length <= data.count else { throw ProtocolError.malformed("TLV length") }
            if result[type] != nil, !(previousType == type && previousLength == 255) {
                throw ProtocolError.malformed("duplicate pairing field")
            }
            result[type, default: Data()].append(data.dropFirst(offset).prefix(length))
            previousType = type; previousLength = length; offset += length
        }
        return result
    }
}

public final class ControlCipher {
    private let readKey: SymmetricKey
    private let writeKey: SymmetricKey
    private var readCounter: UInt64 = 0
    private var writeCounter: UInt64 = 0
    private var buffer = Data()
    private var failed = false
    public init(readKey: SymmetricKey, writeKey: SymmetricKey) {
        self.readKey = readKey; self.writeKey = writeKey
    }
    private static func nonce(_ counter: UInt64) throws -> ChaChaPoly.Nonce {
        var bytes = Data(repeating: 0, count: 4)
        for shift in stride(from: 0, through: 56, by: 8) { bytes.append(UInt8(truncatingIfNeeded: counter >> shift)) }
        return try ChaChaPoly.Nonce(data: bytes)
    }
    public func encrypt(_ plaintext: Data) throws -> Data {
        guard !failed else { throw ProtocolError.malformed("control cipher is closed") }
        var result = Data()
        for offset in stride(from: 0, to: max(plaintext.count, 1), by: 16384) {
            guard writeCounter < UInt64.max else { failed = true; throw ProtocolError.limitExceeded("control nonce") }
            let chunk = Data(plaintext.dropFirst(offset).prefix(16384))
            let header = Data([UInt8(truncatingIfNeeded: chunk.count), UInt8(truncatingIfNeeded: chunk.count >> 8)])
            let box = try ChaChaPoly.seal(chunk, using: writeKey, nonce: Self.nonce(writeCounter), authenticating: header)
            result.append(header); result.append(box.ciphertext); result.append(box.tag); writeCounter += 1
        }
        return result
    }
    public func receive(_ bytes: Data) throws -> Data {
        guard !failed else { throw ProtocolError.malformed("control cipher is closed") }
        do {
            guard buffer.count + bytes.count <= 4 * 1024 * 1024 else { throw ProtocolError.limitExceeded("encrypted control buffer") }
            buffer.append(bytes); var plaintext = Data()
            while buffer.count >= 2 {
                let count = Int(buffer.byte(0)) | Int(buffer.byte(1)) << 8
                guard count <= 16384 else { throw ProtocolError.limitExceeded("encrypted control frame") }
                guard buffer.count >= count + 18 else { break }
                guard readCounter < UInt64.max else { throw ProtocolError.limitExceeded("control nonce") }
                let box = try ChaChaPoly.SealedBox(nonce: Self.nonce(readCounter),
                    ciphertext: buffer.dropFirst(2).prefix(count), tag: buffer.dropFirst(count + 2).prefix(16))
                plaintext.append(try ChaChaPoly.open(box, using: readKey, authenticating: buffer.prefix(2)))
                readCounter += 1; buffer = Data(buffer.dropFirst(count + 18))
            }
            return plaintext
        } catch { failed = true; buffer = Data(); throw error }
    }
}

/// Verifies a previously paired controller. Unknown controllers are never trusted implicitly.
/// Pair-setup and persisted trust must supply the keys before this can be used on a live session.
public final class PairVerify {
    public struct Keys { public let read: SymmetricKey; public let write: SymmetricKey }
    private let identifier: Data
    private let signingKey: Curve25519.Signing.PrivateKey
    private let lookup: (String) -> Curve25519.Signing.PublicKey?
    private var localEphemeral: Data?
    private var peerEphemeral: Data?
    private var secret: SymmetricKey?
    private var encryptionKey: SymmetricKey?
    public private(set) var keys: Keys?
    public private(set) var controllerID: String?
    public private(set) var mediaSecret: SymmetricKey?
    public init(identifier: String, signingKey: Curve25519.Signing.PrivateKey,
                lookup: @escaping (String) -> Curve25519.Signing.PublicKey?) {
        self.identifier = Data(identifier.utf8); self.signingKey = signingKey; self.lookup = lookup
    }
    static func derive(_ secret: SymmetricKey, salt: String, info: String) -> SymmetricKey {
        HKDF<SHA512>.deriveKey(inputKeyMaterial: secret, salt: Data(salt.utf8), info: Data(info.utf8), outputByteCount: 32)
    }
    static func nonce(_ label: String) throws -> ChaChaPoly.Nonce {
        guard label.utf8.count == 8 else { throw ProtocolError.malformed("pairing nonce") }
        return try ChaChaPoly.Nonce(data: Data(repeating: 0, count: 4) + Data(label.utf8))
    }
    public func handle(_ body: Data) throws -> Data {
        do {
            let fields = try TLV8.decode(body)
            guard let state = fields[6], state.count == 1 else { throw ProtocolError.malformed("pair-verify state") }
            switch state.first! {
            case 1:
                reset()
                guard let peerBytes = fields[3], peerBytes.count == 32 else { throw ProtocolError.malformed("peer key") }
                let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerBytes)
                let ephemeral = Curve25519.KeyAgreement.PrivateKey()
                let shared = try ephemeral.sharedSecretFromKeyAgreement(with: peer)
                let secret = shared.withUnsafeBytes { SymmetricKey(data: $0) }
                let encryption = Self.derive(secret, salt: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info")
                let local = ephemeral.publicKey.rawRepresentation
                let signature = try signingKey.signature(for: local + identifier + peerBytes)
                let sub = TLV8.encode([(1, identifier), (10, signature)])
                let box = try ChaChaPoly.seal(sub, using: encryption, nonce: Self.nonce("PV-Msg02"))
                self.secret = secret; encryptionKey = encryption; localEphemeral = local; peerEphemeral = peerBytes
                return TLV8.encode([(6, Data([2])), (3, local), (5, box.ciphertext + box.tag)])
            case 3:
                guard let encrypted = fields[5], encrypted.count >= 16,
                      let encryptionKey, let secret, let localEphemeral, let peerEphemeral,
                      keys == nil else { throw ProtocolError.malformed("pair-verify sequence") }
                let box = try ChaChaPoly.SealedBox(nonce: Self.nonce("PV-Msg03"), ciphertext: encrypted.dropLast(16), tag: encrypted.suffix(16))
                let sub = try TLV8.decode(ChaChaPoly.open(box, using: encryptionKey))
                guard let idData = sub[1], let id = String(data: idData, encoding: .utf8),
                      let signature = sub[10], let trustedKey = lookup(id),
                      trustedKey.isValidSignature(signature, for: peerEphemeral + idData + localEphemeral) else {
                    throw ProtocolError.malformed("untrusted controller or invalid signature")
                }
                keys = Keys(read: Self.derive(secret, salt: "Control-Salt", info: "Control-Write-Encryption-Key"),
                            write: Self.derive(secret, salt: "Control-Salt", info: "Control-Read-Encryption-Key"))
                controllerID = id; mediaSecret = secret; self.secret = nil; self.encryptionKey = nil
                return TLV8.encode([(6, Data([4]))])
            default: throw ProtocolError.malformed("unsupported pair-verify state")
            }
        } catch { reset(); throw error }
    }
    private func reset() {
        keys = nil; controllerID = nil; mediaSecret = nil; secret = nil; encryptionKey = nil; localEphemeral = nil; peerEphemeral = nil
    }
}
