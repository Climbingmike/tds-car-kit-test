import XCTest
import CryptoKit
import Security
@testable import TDSCarKitCore

final class ProtocolTests: XCTestCase {
    func testIAP2KnownHeaderAndFragmentedPackets() throws {
        let ack = IAP2Packet(control: 0x40, sequence: 1, acknowledgement: 2, session: 0)
        XCTAssertEqual(try ack.encoded(), Data([0xff, 0x5a, 0, 9, 0x40, 1, 2, 0, 0x5b]))
        let message = IAP2Message(id: 0xaa03, parameters: [.init(id: 0, value: Data([1, 2, 3]))])
        let packet = IAP2Packet(control: 0x40, sequence: 255, acknowledgement: 2, session: 10, payload: try message.encoded())
        let bytes = IAP2Packet.presence + (try ack.encoded()) + (try packet.encoded())
        var parser = IAP2Parser(); var events: [IAP2Event] = []
        for byte in bytes { events += try parser.append(Data([byte])) }
        XCTAssertEqual(events, [.presence, .packet(ack), .packet(packet)])
        XCTAssertEqual(try IAP2Message.parse(packet.payload), message)
    }
    func testIAP2RejectsCorruptionAndMalformedParameters() throws {
        var bytes = try IAP2Packet(control: 0x40, sequence: 0, acknowledgement: 0, session: 1, payload: Data([1])).encoded()
        bytes[9] ^= 1
        var parser = IAP2Parser(); XCTAssertThrowsError(try parser.append(bytes))
        XCTAssertThrowsError(try IAP2Parameter.parse(Data([0, 0, 0, 1])))
        XCTAssertThrowsError(try IAP2Message(id: 1, parameters: [.init(id: 0, value: Data(count: 65535))]).encoded())
    }
    func testRTSPFragmentationBinaryBodyAndPipelining() throws {
        let first = Data("POST /auth-setup RTSP/1.0\r\nCSeq: 1\r\nContent-Length: 4\r\n\r\n".utf8) + Data([0, 255, 13, 10])
        let second = Data("OPTIONS * RTSP/1.0\r\nCSeq: 2\r\n\r\n".utf8)
        var parser = RTSPParser(); var requests: [RTSPRequest] = []
        for byte in first + second { requests += try parser.append(Data([byte])) }
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].body, Data([0, 255, 13, 10]))
        XCTAssertEqual(requests[1].method, "OPTIONS")
        let response = String(decoding: RTSPResponse().encoded(for: requests[1]), as: UTF8.self)
        XCTAssertTrue(response.contains("CSeq: 2\r\n"))
    }
    func testRTSPRejectsAmbiguousOrOversizedLengths() {
        for headers in ["Content-Length: -1", "Content-Length: 99999999", "Content-Length: 0\r\nContent-Length: 1", "Transfer-Encoding: chunked"] {
            var parser = RTSPParser()
            XCTAssertThrowsError(try parser.append(Data("POST / RTSP/1.0\r\n\(headers)\r\n\r\n".utf8)))
        }
    }
    func testBLEFramePartialAndOversize() throws {
        let frame = BLEFrame(type: 3, payload: Data([0xe1, 0x41, 0x61, 0x01]))
        XCTAssertEqual(try frame.encoded().prefix(6), Data([0, 3, 0, 0, 0, 4]))
        var parser = BLEFrameParser(); var frames: [BLEFrame] = []
        for byte in try frame.encoded() { frames += try parser.append(Data([byte])) }
        XCTAssertEqual(frames, [frame])
        XCTAssertThrowsError(try parser.append(Data([0, 1, 0, 1, 0, 1])))
    }
    func testAnnexBConversion() throws {
        let units = try AnnexB.units(in: Data([0, 0, 0, 1, 0x67, 2, 0, 0, 1, 0x68, 3]))
        XCTAssertEqual(units, [Data([0x67, 2]), Data([0x68, 3])])
        XCTAssertEqual(try AnnexB.lengthPrefixed(units), Data([0, 0, 0, 2, 0x67, 2, 0, 0, 0, 2, 0x68, 3]))
        XCTAssertThrowsError(try AnnexB.units(in: Data([0, 0, 1])))
    }
    func testLocalIdentityMatchesCertificateAndSigns() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".local/Identity")
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("private.x963").path) else {
            throw XCTSkip("Local identity has not been imported")
        }
        let identity = try AccessoryIdentity(certificateChain: Data(contentsOf: folder.appendingPathComponent("certificate.p7b")),
            leafCertificate: Data(contentsOf: folder.appendingPathComponent("leaf.cer")),
            privateKeyX963: Data(contentsOf: folder.appendingPathComponent("private.x963")))
        XCTAssertEqual(try identity.sign(challenge: Data(repeating: 3, count: 32)).count, 64)
        XCTAssertThrowsError(try identity.sign(challenge: Data([1])))
    }
    func testOPACKIdentificationEncoding() throws {
        XCTAssertEqual(try OPACK.encode(.dictionary(["a": .bool(true)])), Data([0xe1, 0x41, 0x61, 0x01]))
        XCTAssertEqual(try OPACK.encode(.uint(7000)), Data([0x31, 0x58, 0x1b]))
        XCTAssertEqual(try OPACK.encode(.string(String(repeating: "a", count: 33))).prefix(2), Data([0x61, 33]))
    }
    func testAESCTRKnownNISTVector() throws {
        func hex(_ text: String) -> Data {
            let chars = Array(text); return Data(stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...$0+1]), radix: 16)! })
        }
        let encrypted = try MFiSAP.aesCTR(key: hex("2b7e151628aed2a6abf7158809cf4f3c"),
            iv: hex("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff"), data: hex("6bc1bee22e409f96e93d7e117393172a"))
        XCTAssertEqual(encrypted, hex("874d6191b620e3261bef6864990db6ce"))
    }
    func testMFiSAPResponseCanBeVerifiedByController() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".local/Identity")
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("private.x963").path) else {
            throw XCTSkip("Local identity has not been imported")
        }
        let chain = try Data(contentsOf: folder.appendingPathComponent("certificate.p7b"))
        let leaf = try Data(contentsOf: folder.appendingPathComponent("leaf.cer"))
        let identity = try AccessoryIdentity(certificateChain: chain, leafCertificate: leaf,
            privateKeyX963: Data(contentsOf: folder.appendingPathComponent("private.x963")))
        let controller = Curve25519.KeyAgreement.PrivateKey()
        let response = try MFiSAP.respond(to: Data([1]) + controller.publicKey.rawRepresentation, identity: identity)
        let accessoryPublic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: response.prefix(32))
        let shared = try controller.sharedSecretFromKeyAgreement(with: accessoryPublic)
        let secret = shared.withUnsafeBytes { Data($0) }
        XCTAssertEqual(Int(response.be32(32)), chain.count)
        XCTAssertEqual(Data(response.dropFirst(36).prefix(chain.count)), chain)
        XCTAssertEqual(response.be32(36 + chain.count), 64)
        let encryptedSignature = Data(response.dropFirst(40 + chain.count))
        let signature = try MFiSAP.aesCTR(key: Data(Insecure.SHA1.hash(data: Data("AES-KEY".utf8) + secret).prefix(16)),
            iv: Data(Insecure.SHA1.hash(data: Data("AES-IV".utf8) + secret).prefix(16)), data: encryptedSignature)
        let certificate = SecCertificateCreateWithData(nil, leaf as CFData)!
        let publicKey = SecCertificateCopyKey(certificate)!
        let digest = Data(SHA256.hash(data: accessoryPublic.rawRepresentation + controller.publicKey.rawRepresentation))
        XCTAssertTrue(SecKeyVerifySignature(publicKey, .ecdsaSignatureRFC4754, digest as CFData, signature as CFData, nil))
        XCTAssertThrowsError(try MFiSAP.respond(to: Data([2]) + controller.publicKey.rawRepresentation, identity: identity))
    }
}
