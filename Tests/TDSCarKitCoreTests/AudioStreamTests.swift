import XCTest
import CryptoKit
@testable import TDSCarKitCore

final class AudioStreamTests: XCTestCase {
    private func packet(_ key: SymmetricKey, nonce counter: UInt64, payload: Data) throws -> Data {
        let header = Data([0x80, 96, 0, 1, 0, 0, 4, 0, 0, 0, 0, 0])
        let nonce = Data(stride(from: 0, through: 56, by: 8).map { UInt8(truncatingIfNeeded: counter >> $0) })
        let box = try ChaChaPoly.seal(payload, using: key, nonce: .init(data: Data(count: 4) + nonce), authenticating: header.suffix(8))
        return header + box.ciphertext + box.tag + nonce
    }
    func testAudioDecryptsAndAllowsReorderingButRejectsReplay() throws {
        let secret = SymmetricKey(size: .bits256), connection: UInt64 = 1234
        let key = PairVerify.derive(secret, salt: "DataStream-Salt\(connection)", info: "DataStream-Output-Encryption-Key")
        let receiver = AudioStream(secret: secret, connectionID: connection)
        let pcm = Data([0x7f, 0xff, 0x80, 0, 0, 0])
        let first = try packet(key, nonce: 2, payload: pcm)
        let decoded = try receiver.receive(first)
        XCTAssertEqual(decoded.timestamp, 1024); XCTAssertEqual(decoded.samples, pcm)
        XCTAssertEqual(try receiver.receive(packet(key, nonce: 1, payload: pcm)).samples, pcm)
        XCTAssertThrowsError(try receiver.receive(first))
        _ = try receiver.receive(packet(key, nonce: 80, payload: pcm))
        XCTAssertThrowsError(try receiver.receive(packet(key, nonce: 3, payload: pcm)))
    }
    func testBadTagDoesNotAdvanceReplayWindow() throws {
        let secret = SymmetricKey(size: .bits256)
        let key = PairVerify.derive(secret, salt: "DataStream-Salt1", info: "DataStream-Output-Encryption-Key")
        let receiver = AudioStream(secret: secret, connectionID: 1)
        let valid = try packet(key, nonce: 0, payload: Data([0, 0]))
        var bad = valid; bad[12] ^= 1
        XCTAssertThrowsError(try receiver.receive(bad))
        XCTAssertEqual(try receiver.receive(valid).samples, Data([0, 0]))
    }
    func testMicrophoneUplinkUsesInputKeyAndUniqueCounters() throws {
        let secret = SymmetricKey(size: .bits256)
        let sender = MicrophonePacketizer(secret: secret, connectionID: 42)
        let key = PairVerify.derive(secret, salt: "DataStream-Salt42", info: "DataStream-Input-Encryption-Key")
        let pcm = Data([0x7f,0xff,0x80,0])
        for index in 0..<2 {
            let wire = try sender.seal(pcm, frames: 2)
            XCTAssertEqual(wire.prefix(4), Data([0x80,100,0,UInt8(index)]))
            XCTAssertEqual(wire[7], UInt8(index * 2))
            let nonce = Data(wire.suffix(8)); XCTAssertEqual(nonce.first, UInt8(index))
            let sealed = try ChaChaPoly.SealedBox(nonce: .init(data: Data(count: 4) + nonce),
                ciphertext: wire.dropFirst(12).dropLast(24), tag: wire.dropLast(8).suffix(16))
            XCTAssertEqual(try ChaChaPoly.open(sealed, using: key, authenticating: wire.subdata(in: 4..<12)), pcm)
            let wrongDirection = AudioStream(secret: secret, connectionID: 42)
            XCTAssertThrowsError(try wrongDirection.receive(wire))
        }
    }
    func testReceiverMusicFormats() throws {
        for (bits, rate) in [(UInt64(0x400000), 44100), (UInt64(0x800000), 48000)] {
            let format = try ReceiverAudioFormat(bits: bits)
            XCTAssertTrue(format.isAAC); XCTAssertEqual(format.sampleRate, rate); XCTAssertEqual(format.channels, 2)
        }
        XCTAssertFalse(try ReceiverAudioFormat(bits: 0x8000).isAAC)
        XCTAssertThrowsError(try ReceiverAudioFormat(bits: 0xc00000))
    }
    func testWirelessVoiceFormats() throws {
        for (bits, rate) in [(UInt64(0x10000000), 16000), (UInt64(0x20000000), 24000), (UInt64(0x40000000), 48000)] {
            let format = try ReceiverAudioFormat(bits: bits)
            XCTAssertTrue(format.isOpus); XCTAssertFalse(format.isAAC)
            XCTAssertEqual(format.sampleRate, rate); XCTAssertEqual(format.channels, 1)
        }
        XCTAssertThrowsError(try ReceiverAudioFormat(bits: 0x70000000))
        // Compressed packets need not be an even number of bytes.
        let sender = MicrophonePacketizer(secret: SymmetricKey(size: .bits256), connectionID: 9)
        XCTAssertNoThrow(try sender.seal(Data([1, 2, 3]), frames: 480))
    }
    func testPCMNegotiationRejectsUnimplementedCompressedFormats() throws {
        let stereo = try PCMFormat(bits: 0x8000)
        XCTAssertEqual(stereo.sampleRate, 48000); XCTAssertEqual(stereo.channels, 2)
        XCTAssertThrowsError(try PCMFormat(bits: 0x400000))
        XCTAssertThrowsError(try PCMFormat(bits: 0))
    }
}
