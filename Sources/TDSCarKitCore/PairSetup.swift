// SPDX-License-Identifier: GPL-3.0-or-later
// AirPlay SRP-6a responder, adapted from PlayPort PairSetup.kt and Srp6a.kt.
import Foundation
import CryptoKit
import Security

final class SRPServer {
    static let modulus = BigUInt("FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3BE39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF6955817183995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D04507A33A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864D87602733EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E208E24FA074E5AB3143DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF", radix: 16)!
    static let generator = BigUInt(5)
    static func hash(_ values: Data...) -> Data { Data(SHA512.hash(data: values.reduce(Data(), +))) }
    static func pad(_ value: BigUInt) -> Data {
        let data = value.serialize()
        return Data(repeating: 0, count: max(0, 384 - data.count)) + data
    }
    static func random(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw ProtocolError.malformed("secure random generation")
        }
        return Data(bytes)
    }
    let salt: Data
    let publicKey: Data
    private let verifier: BigUInt
    private let exponent: BigUInt
    private var consumed = false
    // Injectable entropy only for deterministic cross-implementation test vectors.
    init(salt: Data? = nil, privateBytes: Data? = nil) throws {
        let salt = try salt ?? Self.random(16)
        let privateBytes = try privateBytes ?? Self.random(32)
        guard salt.count == 16, privateBytes.count == 32, BigUInt(privateBytes) != 0 else {
            throw ProtocolError.malformed("SRP entropy")
        }
        self.salt = salt; exponent = BigUInt(privateBytes)
        let x = BigUInt(Self.hash(salt, Self.hash(Data("Pair-Setup:3939".utf8))))
        verifier = Self.generator.power(x, modulus: Self.modulus)
        let k = BigUInt(Self.hash(Self.pad(Self.modulus), Self.pad(Self.generator)))
        publicKey = Self.pad((k * verifier + Self.generator.power(exponent, modulus: Self.modulus)) % Self.modulus)
    }
    func verify(publicKey peer: Data, proof: Data) throws -> (key: SymmetricKey, proof: Data) {
        guard !consumed else { throw ProtocolError.malformed("SRP proof reused") }
        consumed = true
        guard peer.count == 384, proof.count == 64 else { throw ProtocolError.malformed("SRP proof/key length") }
        let a = BigUInt(peer), n = Self.modulus
        guard a > 0, a < n else { throw ProtocolError.malformed("SRP public key") }
        let u = BigUInt(Self.hash(peer, publicKey))
        guard u != 0 else { throw ProtocolError.malformed("SRP scrambling parameter") }
        let shared = ((a * verifier.power(u, modulus: n)) % n).power(exponent, modulus: n)
        let key = Self.hash(shared.serialize())
        let xor = Data(zip(Self.hash(n.serialize()), Self.hash(Self.generator.serialize())).map { $0 ^ $1 })
        let expected = Self.hash(xor, Self.hash(Data("Pair-Setup".utf8)), salt, peer, publicKey, key)
        var difference: UInt8 = 0
        for (a, b) in zip(expected, proof) { difference |= a ^ b }
        guard difference == 0 else { throw ProtocolError.malformed("SRP authentication proof") }
        return (SymmetricKey(data: key), Self.hash(peer, proof, key))
    }
}

public final class PairSetup {
    private let identifier: Data
    private let signingKey: Curve25519.Signing.PrivateKey
    private let save: (String, Data) throws -> Void
    private var srp: SRPServer?
    private var key: SymmetricKey?
    private var expectedState: UInt8 = 1
    public private(set) var complete = false
    public init(identifier: String, signingKey: Curve25519.Signing.PrivateKey,
                save: @escaping (String, Data) throws -> Void) {
        self.identifier = Data(identifier.utf8); self.signingKey = signingKey; self.save = save
    }
    public func handle(_ body: Data) throws -> Data {
        do {
            let fields = try TLV8.decode(body)
            guard let state = fields[6], state.count == 1, state.first == expectedState, !complete else {
                throw ProtocolError.malformed("pair-setup sequence")
            }
            switch expectedState {
            case 1:
                guard fields[0] == Data([0]), fields[19] == nil else {
                    throw ProtocolError.malformed("unsupported pair-setup method or flags")
                }
                let session = try SRPServer(); srp = session; expectedState = 3
                return TLV8.encode([(6, Data([2])), (3, session.publicKey), (2, session.salt)])
            case 3:
                guard let srp, let peer = fields[3], let proof = fields[4] else {
                    throw ProtocolError.malformed("missing SRP proof")
                }
                let result = try srp.verify(publicKey: peer, proof: proof)
                key = result.key; self.srp = nil; expectedState = 5
                return TLV8.encode([(6, Data([4])), (4, result.proof)])
            case 5:
                guard let key, let encrypted = fields[5], encrypted.count >= 16 else {
                    throw ProtocolError.malformed("missing encrypted pairing identity")
                }
                let encryption = PairVerify.derive(key, salt: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info")
                let box = try ChaChaPoly.SealedBox(nonce: PairVerify.nonce("PS-Msg05"), ciphertext: encrypted.dropLast(16), tag: encrypted.suffix(16))
                let sub = try TLV8.decode(ChaChaPoly.open(box, using: encryption))
                guard let id = sub[1], (1...256).contains(id.count), let idString = String(data: id, encoding: .utf8),
                      let peer = sub[3], peer.count == 32, let signature = sub[10], signature.count == 64 else {
                    throw ProtocolError.malformed("pairing identity fields")
                }
                let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: peer)
                let controllerKey = PairVerify.derive(key, salt: "Pair-Setup-Controller-Sign-Salt", info: "Pair-Setup-Controller-Sign-Info")
                let signed = controllerKey.withUnsafeBytes { Data($0) } + id + peer
                guard publicKey.isValidSignature(signature, for: signed) else { throw ProtocolError.malformed("pairing identity signature") }
                let accessoryKey = PairVerify.derive(key, salt: "Pair-Setup-Accessory-Sign-Salt", info: "Pair-Setup-Accessory-Sign-Info")
                let local = signingKey.publicKey.rawRepresentation
                let localSignature = try signingKey.signature(for: accessoryKey.withUnsafeBytes { Data($0) } + identifier + local)
                let response = TLV8.encode([(1, identifier), (3, local), (10, localSignature)])
                let sealed = try ChaChaPoly.seal(response, using: encryption, nonce: PairVerify.nonce("PS-Msg06"))
                try save(idString, peer)
                complete = true; self.key = nil; expectedState = 0
                return TLV8.encode([(6, Data([6])), (5, sealed.ciphertext + sealed.tag)])
            default: throw ProtocolError.malformed("pair-setup state")
            }
        } catch { srp = nil; key = nil; expectedState = 0; throw error }
    }
}
