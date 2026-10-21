import XCTest
import CryptoKit
@testable import TDSCarKitCore

final class ScreenStreamTests: XCTestCase {
    private func header(_ length: Int, opcode: UInt8) -> Data {
        var result = Data(count: 128)
        for offset in 0..<4 { result[offset] = UInt8(truncatingIfNeeded: length >> (offset * 8)) }
        result[4] = opcode; return result
    }
    func testFragmentedEncryptedVideoAndConfiguration() throws {
        let secret = SymmetricKey(size: .bits256)
        let connectionID: UInt64 = 0xf123456789abcdef
        let key = PairVerify.derive(secret, salt: "DataStream-Salt\(connectionID)", info: "DataStream-Output-Encryption-Key")
        let receiver = ScreenStream(secret: secret, connectionID: connectionID)
        let config = Data([1, 0x64, 0, 0x28, 0xff, 0xe1, 0, 2, 0x67, 0x01, 1, 0, 2, 0x68, 0x02])
        let plain = Data([0, 0, 0, 3, 0x65, 0x88, 0x99])
        let head = header(plain.count + 16, opcode: 0)
        let box = try ChaChaPoly.seal(plain, using: key, nonce: .init(data: Data(count: 12)), authenticating: head)
        let wire = header(config.count, opcode: 1) + config + head + box.ciphertext + box.tag
        var output: [Data] = []
        for offset in stride(from: 0, to: wire.count, by: 13) { output += try receiver.append(Data(wire.dropFirst(offset).prefix(13))) }
        XCTAssertEqual(output, [Data([0,0,0,1,0x67,1,0,0,0,1,0x68,2]), Data([0,0,0,1,0x65,0x88,0x99])])
        var corrupt = head + box.ciphertext + box.tag; corrupt[128] ^= 1
        XCTAssertThrowsError(try receiver.append(corrupt))
        XCTAssertThrowsError(try receiver.append(Data()))
    }
    func testRejectsOversizedFrameAndTruncatedAVC() throws {
        let receiver = ScreenStream(secret: .init(size: .bits256), connectionID: 1)
        XCTAssertThrowsError(try receiver.append(header(9 * 1024 * 1024, opcode: 0)))
        XCTAssertThrowsError(try ScreenStream.configuration(Data([1,0,0,0,0xff,0xe1,0,10,0x67])))
    }
    func testEventParserAcceptsResponsesWithoutTreatingThemAsRequests() throws {
        var parser = RTSPParser(allowResponses: true)
        let values = try parser.append(Data("RTSP/1.0 200 OK\r\nContent-Length: 0\r\n\r\nPOST /command RTSP/1.0\r\nContent-Length: 0\r\n\r\n".utf8))
        XCTAssertEqual(values.map(\.method), ["RTSP/1.0", "POST"])
    }
}
