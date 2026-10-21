// SPDX-License-Identifier: GPL-3.0-or-later
// AirPlay RTP audio layout adapted from PlayPort AudioStream.kt.
import Foundation
import CryptoKit

public struct PCMFormat {
    public let sampleRate: Int
    public let channels: Int
    public init(bits: UInt64) throws {
        let formats: [UInt64: (Int, Int)] = [4:(8000,1),8:(8000,2),16:(16000,1),32:(16000,2),
            64:(24000,1),128:(24000,2),256:(32000,1),512:(32000,2),1024:(44100,1),2048:(44100,2),
            16384:(48000,1),32768:(48000,2)]
        guard let format = formats[bits] else { throw ProtocolError.malformed("unsupported PCM format \(bits)") }
        sampleRate = format.0; channels = format.1
    }
}

/// Formats supported by the receiver, including wireless music's AAC-LC stream.
public struct ReceiverAudioFormat {
    public let sampleRate: Int
    public let channels: Int
    public let isAAC: Bool
    public let isOpus: Bool
    public var name: String { isAAC ? "AAC-LC" : isOpus ? "Opus" : "PCM" }
    public init(bits: UInt64) throws {
        if bits == 0x400000 || bits == 0x800000 {
            sampleRate = bits == 0x400000 ? 44100 : 48000; channels = 2; isAAC = true; isOpus = false
        } else if let rate = [UInt64(0x10000000): 16000, 0x20000000: 24000, 0x40000000: 48000][bits] {
            sampleRate = rate; channels = 1; isAAC = false; isOpus = true
        } else {
            let pcm = try PCMFormat(bits: bits)
            sampleRate = pcm.sampleRate; channels = pcm.channels; isAAC = false; isOpus = false
        }
    }
}

public final class AudioStream {
    public struct Packet { public let timestamp: UInt32; public let samples: Data }
    private let key: SymmetricKey
    private var highestNonce: UInt64?
    private var seen: UInt64 = 0
    public init(secret: SymmetricKey, connectionID: UInt64) {
        key = PairVerify.derive(secret, salt: "DataStream-Salt\(connectionID)", info: "DataStream-Output-Encryption-Key")
    }
    /// Accepts authenticated, possibly reordered packets within a 64-packet replay window.
    public func receive(_ data: Data) throws -> Packet {
        guard (36...65507).contains(data.count), data.byte(0) == 0x80 else {
            throw ProtocolError.malformed("audio RTP header")
        }
        let shortNonce = Data(data.suffix(8))
        let nonce = (0..<8).reduce(UInt64(0)) { $0 | (UInt64(shortNonce.byte($1)) << ($1 * 8)) }
        if let highestNonce, nonce <= highestNonce {
            let distance = highestNonce - nonce
            guard distance < 64, seen & (UInt64(1) << distance) == 0 else { throw ProtocolError.malformed("replayed audio packet") }
        }
        let ciphertext = data.dropFirst(12).dropLast(24)
        let tag = data.dropLast(8).suffix(16)
        let box = try ChaChaPoly.SealedBox(nonce: .init(data: Data(count: 4) + shortNonce), ciphertext: ciphertext, tag: tag)
        let samples = try ChaChaPoly.open(box, using: key, authenticating: data.subdata(in: 4..<12))
        if let highestNonce {
            if nonce > highestNonce {
                let distance = nonce - highestNonce
                seen = distance >= 64 ? 1 : (seen << distance) | 1; self.highestNonce = nonce
            } else { seen |= UInt64(1) << (highestNonce - nonce) }
        } else { highestNonce = nonce; seen = 1 }
        return Packet(timestamp: data.be32(4), samples: samples)
    }
}

/// PCM or Opus microphone RTP uplink. Input and output use different HKDF keys/counters.
public final class MicrophonePacketizer {
    private let key: SymmetricKey
    private var sequence: UInt16 = 0
    private var timestamp: UInt32 = 0
    private var counter: UInt64 = 0
    public init(secret: SymmetricKey, connectionID: UInt64) {
        key = PairVerify.derive(secret, salt: "DataStream-Salt\(connectionID)", info: "DataStream-Input-Encryption-Key")
    }
    public func seal(_ pcm: Data, frames: UInt32) throws -> Data {
        guard !pcm.isEmpty, pcm.count <= 64000, frames > 0, counter < UInt64.max else {
            throw ProtocolError.malformed("microphone packet size/counter")
        }
        let header = Data([0x80, 100, UInt8(truncatingIfNeeded: sequence >> 8), UInt8(truncatingIfNeeded: sequence),
            UInt8(truncatingIfNeeded: timestamp >> 24), UInt8(truncatingIfNeeded: timestamp >> 16),
            UInt8(truncatingIfNeeded: timestamp >> 8), UInt8(truncatingIfNeeded: timestamp), 0, 0, 0, 0])
        let nonce = Data(stride(from: 0, through: 56, by: 8).map { UInt8(truncatingIfNeeded: counter >> $0) })
        let box = try ChaChaPoly.seal(pcm, using: key, nonce: .init(data: Data(count: 4) + nonce), authenticating: header.suffix(8))
        counter += 1; sequence &+= 1; timestamp &+= frames
        return header + box.ciphertext + box.tag + nonce
    }
}
