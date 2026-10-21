import XCTest
import CryptoKit
@testable import TDSCarKitCore

final class PairSetupTests: XCTestCase {
    private func bytes(_ hex: String) -> Data {
        let chars = Array(hex)
        return Data(stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...$0+1]), radix: 16)! })
    }
    func testSRPMatchesIndependentPythonFixture() throws {
        let server = try SRPServer(salt: bytes(SRPFixture.salt), privateBytes: bytes(SRPFixture.privateBytes))
        XCTAssertEqual(server.publicKey, bytes(SRPFixture.publicKey))
        let result = try server.verify(publicKey: bytes(SRPFixture.peer), proof: bytes(SRPFixture.proof))
        XCTAssertEqual(result.key.withUnsafeBytes { Data($0) }, bytes(SRPFixture.key))
        XCTAssertEqual(result.proof, bytes(SRPFixture.serverProof))
        XCTAssertThrowsError(try server.verify(publicKey: bytes(SRPFixture.peer), proof: bytes(SRPFixture.proof)))
    }
    func testSRPRejectsInvalidProofAndZeroPeer() throws {
        let server = try SRPServer(salt: bytes(SRPFixture.salt), privateBytes: bytes(SRPFixture.privateBytes))
        XCTAssertThrowsError(try server.verify(publicKey: bytes(SRPFixture.peer), proof: Data(count: 64)))
        let zeroServer = try SRPServer()
        XCTAssertThrowsError(try zeroServer.verify(publicKey: Data(count: 384), proof: Data(count: 64)))
    }
    func testPairSetupCompletesAndVerifiesAccessorySignature() throws { try exchange(tamper: false) }
    func testPairSetupNeverSavesInvalidControllerSignature() throws { try exchange(tamper: true) }
    func testPairSetupRejectsOutOfSequence() throws {
        let server = PairSetup(identifier: "receiver", signingKey: .init()) { _, _ in XCTFail("must not save") }
        XCTAssertThrowsError(try server.handle(TLV8.encode([(6, Data([5])), (5, Data(count: 16))])))
        XCTAssertFalse(server.complete)
    }
    func testParserPreservesCiphertextAtPairVerifyBoundary() throws {
        var parser = RTSPParser()
        let tail = Data([1, 0, 0xff, 0x00])
        let result = try parser.append(Data("POST /pair-verify RTSP/1.0\r\nContent-Length: 0\r\n\r\n".utf8) + tail, maximumRequests: 1)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(parser.takeBufferedData(), tail)
        XCTAssertTrue(parser.takeBufferedData().isEmpty)
    }
    private func exchange(tamper: Bool) throws {
        let accessory = Curve25519.Signing.PrivateKey(), controller = Curve25519.Signing.PrivateKey()
        var saved: (String, Data)?
        let server = PairSetup(identifier: "receiver", signingKey: accessory) { saved = ($0, $1) }
        let m2 = try TLV8.decode(server.handle(TLV8.encode([(0, Data([0])), (6, Data([1]))])))
        let salt = try XCTUnwrap(m2[2]), bBytes = try XCTUnwrap(m2[3])
        let n = SRPServer.modulus, g = BigUInt(5), a = BigUInt(bytes(SRPFixture.privateBytes))
        let aBytes = SRPServer.pad(g.power(a, modulus: n))
        let x = BigUInt(SRPServer.hash(salt, SRPServer.hash(Data("Pair-Setup:3939".utf8))))
        let u = BigUInt(SRPServer.hash(aBytes, bBytes))
        let k = BigUInt(SRPServer.hash(SRPServer.pad(n), SRPServer.pad(g)))
        let base = (BigUInt(bBytes) + n - (k * g.power(x, modulus: n)) % n) % n
        let shared = base.power(a + u * x, modulus: n)
        let keyBytes = SRPServer.hash(shared.serialize()), key = SymmetricKey(data: keyBytes)
        let xor = Data(zip(SRPServer.hash(n.serialize()), SRPServer.hash(g.serialize())).map { $0 ^ $1 })
        let proof = SRPServer.hash(xor, SRPServer.hash(Data("Pair-Setup".utf8)), salt, aBytes, bBytes, keyBytes)
        let m4 = try TLV8.decode(server.handle(TLV8.encode([(6, Data([3])), (3, aBytes), (4, proof)])))
        XCTAssertEqual(m4[4], SRPServer.hash(aBytes, proof, keyBytes))
        XCTAssertNil(saved)
        let encryption = PairVerify.derive(key, salt: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info")
        let signing = PairVerify.derive(key, salt: "Pair-Setup-Controller-Sign-Salt", info: "Pair-Setup-Controller-Sign-Info")
        let peer = controller.publicKey.rawRepresentation, identifier = Data("phone".utf8)
        var signature = try controller.signature(for: signing.withUnsafeBytes { Data($0) } + identifier + peer)
        if tamper { signature[0] ^= 1 }
        let sub = TLV8.encode([(1, identifier), (3, peer), (10, signature)])
        let sealed = try ChaChaPoly.seal(sub, using: encryption, nonce: PairVerify.nonce("PS-Msg05"))
        let m5 = TLV8.encode([(6, Data([5])), (5, sealed.ciphertext + sealed.tag)])
        if tamper {
            XCTAssertThrowsError(try server.handle(m5)); XCTAssertNil(saved); XCTAssertFalse(server.complete); return
        }
        let m6 = try TLV8.decode(server.handle(m5))
        let encrypted = try XCTUnwrap(m6[5])
        let box = try ChaChaPoly.SealedBox(nonce: PairVerify.nonce("PS-Msg06"), ciphertext: encrypted.dropLast(16), tag: encrypted.suffix(16))
        let response = try TLV8.decode(ChaChaPoly.open(box, using: encryption))
        let accessorySign = PairVerify.derive(key, salt: "Pair-Setup-Accessory-Sign-Salt", info: "Pair-Setup-Accessory-Sign-Info")
        XCTAssertTrue(accessory.publicKey.isValidSignature(try XCTUnwrap(response[10]),
            for: accessorySign.withUnsafeBytes { Data($0) } + Data("receiver".utf8) + accessory.publicKey.rawRepresentation))
        XCTAssertTrue(server.complete); XCTAssertEqual(saved?.0, "phone"); XCTAssertEqual(saved?.1, peer)
        XCTAssertThrowsError(try server.handle(m5))
    }
}
