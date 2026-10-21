import XCTest
import CryptoKit
@testable import TDSCarKitCore

final class PairingTests: XCTestCase {
    func testTLVFragmentationAndAmbiguity() throws {
        let value = Data((0..<700).map { UInt8(truncatingIfNeeded: $0) })
        XCTAssertEqual(try TLV8.decode(TLV8.encode([(3, value)]))[3], value)
        XCTAssertThrowsError(try TLV8.decode(Data([6, 1, 1, 6, 1, 3])))
        XCTAssertThrowsError(try TLV8.decode(Data([3, 255, 1])))
    }
    func testControlCipherFragmentationAndTamper() throws {
        let a = SymmetricKey(size: .bits256), b = SymmetricKey(size: .bits256)
        let sender = ControlCipher(readKey: b, writeKey: a)
        let receiver = ControlCipher(readKey: a, writeKey: b)
        let payload = Data((0..<40000).map { UInt8(truncatingIfNeeded: $0) })
        let encrypted = try sender.encrypt(payload)
        var plaintext = Data()
        for offset in stride(from: 0, to: encrypted.count, by: 71) {
            plaintext.append(try receiver.receive(Data(encrypted.dropFirst(offset).prefix(71))))
        }
        XCTAssertEqual(plaintext, payload)
        XCTAssertEqual(try sender.receive(receiver.encrypt(Data("reply".utf8))), Data("reply".utf8))
        var corrupted = try sender.encrypt(Data("next".utf8)); corrupted[2] ^= 1
        XCTAssertThrowsError(try receiver.receive(corrupted))
        XCTAssertThrowsError(try receiver.receive(Data()))
    }
    func testPairVerifyTrustedControllerAndKeyDirections() throws { try verify(known: true) }
    func testPairVerifyRejectsUnknownController() throws { try verify(known: false) }
    func testPairVerifyRejectsOutOfSequence() {
        let server = PairVerify(identifier: "receiver", signingKey: .init(), lookup: { _ in nil })
        XCTAssertThrowsError(try server.handle(TLV8.encode([(6, Data([3])), (5, Data(count: 16))])))
        XCTAssertNil(server.keys)
    }
    private func verify(known: Bool) throws {
        let accessory = Curve25519.Signing.PrivateKey()
        let controller = Curve25519.Signing.PrivateKey()
        let clientEphemeral = Curve25519.KeyAgreement.PrivateKey()
        let server = PairVerify(identifier: "receiver", signingKey: accessory,
            lookup: { id in known && id == "phone" ? controller.publicKey : nil })
        let m2 = try TLV8.decode(server.handle(TLV8.encode([(6, Data([1])), (3, clientEphemeral.publicKey.rawRepresentation)])))
        let serverEphemeral = try XCTUnwrap(m2[3])
        let shared = try clientEphemeral.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: serverEphemeral))
        let secret = shared.withUnsafeBytes { SymmetricKey(data: $0) }
        let encryptionKey = PairVerify.derive(secret, salt: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info")
        let encrypted = try XCTUnwrap(m2[5])
        let box = try ChaChaPoly.SealedBox(nonce: PairVerify.nonce("PV-Msg02"), ciphertext: encrypted.dropLast(16), tag: encrypted.suffix(16))
        let sub = try TLV8.decode(ChaChaPoly.open(box, using: encryptionKey))
        XCTAssertTrue(accessory.publicKey.isValidSignature(try XCTUnwrap(sub[10]),
            for: serverEphemeral + Data("receiver".utf8) + clientEphemeral.publicKey.rawRepresentation))
        let signature = try controller.signature(for: clientEphemeral.publicKey.rawRepresentation + Data("phone".utf8) + serverEphemeral)
        let m3Box = try ChaChaPoly.seal(TLV8.encode([(1, Data("phone".utf8)), (10, signature)]),
            using: encryptionKey, nonce: PairVerify.nonce("PV-Msg03"))
        let m3 = TLV8.encode([(6, Data([3])), (5, m3Box.ciphertext + m3Box.tag)])
        if !known {
            XCTAssertThrowsError(try server.handle(m3)); XCTAssertNil(server.keys); return
        }
        XCTAssertEqual(try TLV8.decode(server.handle(m3))[6], Data([4]))
        let keys = try XCTUnwrap(server.keys)
        let clientCipher = ControlCipher(readKey: PairVerify.derive(secret, salt: "Control-Salt", info: "Control-Read-Encryption-Key"),
            writeKey: PairVerify.derive(secret, salt: "Control-Salt", info: "Control-Write-Encryption-Key"))
        let serverCipher = ControlCipher(readKey: keys.read, writeKey: keys.write)
        XCTAssertEqual(try serverCipher.receive(clientCipher.encrypt(Data("OPTIONS".utf8))), Data("OPTIONS".utf8))
        XCTAssertEqual(try clientCipher.receive(serverCipher.encrypt(Data("200 OK".utf8))), Data("200 OK".utf8))
    }
}
