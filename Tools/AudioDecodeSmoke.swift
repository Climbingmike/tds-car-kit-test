import Foundation
import AVFoundation

@main
struct AudioDecodeSmoke {
    static func main() throws {
        for (name, rate, bits) in [("44100", 44100, UInt64(0x400000)), ("48000", 48000, UInt64(0x800000))] {
            let decoder = try NativeAudioDecoder(format: ReceiverAudioFormat(bits: bits))
            let wire = [UInt8](try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(name + ".aac")))
            var offset = 0, frames = 0, energy = [Double](repeating: 0, count: 2)
            while offset + 7 <= wire.count {
                guard wire[offset] == 0xff, wire[offset + 1] & 0xf6 == 0xf0 else { fatalError("Invalid ADTS fixture") }
                let length = (Int(wire[offset + 3] & 3) << 11) | (Int(wire[offset + 4]) << 3) | Int(wire[offset + 5] >> 5)
                let header = wire[offset + 1] & 1 == 1 ? 7 : 9
                guard length > header, offset + length <= wire.count else { fatalError("Truncated fixture") }
                if let pcm = try decoder.decode(Data(wire[(offset + header)..<(offset + length)])), let channels = pcm.floatChannelData {
                    for channel in 0..<2 {
                        for frame in 0..<Int(pcm.frameLength) { energy[channel] += pow(Double(channels[channel][frame]), 2) }
                    }
                    frames += Int(pcm.frameLength)
                }
                offset += length
            }
            // Independently encoded one-second sine, left 0.5 amplitude, right 0.25.
            guard frames >= rate, frames < rate + 8192 else { fatalError("Unexpected AAC sample count: \(frames)") }
            let rms = energy.map { sqrt($0 / Double(frames)) }
            guard (0.30...0.38).contains(rms[0]), (0.15...0.20).contains(rms[1]) else { fatalError("Wrong decoded channels/amplitude: \(rms)") }
            print("PASS: AAC-LC \(rate) Hz stereo decoded \(frames) frames; RMS \(rms)")
        }
        for (bits, rate) in [(UInt64(0x10000000), 16000), (UInt64(0x20000000), 24000), (UInt64(0x40000000), 48000)] {
            let encoder = try NativeOpusEncoder(rate: rate)
            let decoder = try NativeAudioDecoder(format: ReceiverAudioFormat(bits: bits))
            var total = 0, energy = 0.0, packets = 0
            for packetIndex in 0..<50 {
                var input = Data()
                for frame in 0..<(rate / 50) {
                    let t = Double(packetIndex * (rate / 50) + frame) / Double(rate)
                    let sample = UInt16(bitPattern: Int16(sin(t * 2 * .pi * 440) * 16384))
                    input.append(UInt8(truncatingIfNeeded: sample >> 8)); input.append(UInt8(truncatingIfNeeded: sample))
                }
                if let payload = try encoder.encode(input) {
                    packets += 1
                    if let decoded = try decoder.decode(payload) {
                        total += Int(decoded.frameLength)
                        for frame in 0..<Int(decoded.frameLength) { energy += pow(Double(decoded.floatChannelData![0][frame]), 2) }
                    }
                }
            }
            let rms = sqrt(energy / Double(total))
            guard packets == 50, total >= rate * 9 / 10, total <= rate,
                  (0.30...0.39).contains(rms) else { fatalError("Opus \(rate) failed: \(packets) packets, \(total) frames, RMS \(rms)") }
            print("PASS: Opus \(rate) Hz mono: \(packets) raw packets, \(total) decoded frames; RMS \(rms)")
        }
        let pcm = try NativeAudioDecoder(format: ReceiverAudioFormat(bits: 0x8000))
        let buffer = try pcm.decode(Data([0x7f,0xff,0x80,0x00]))!
        guard buffer.frameLength == 1, buffer.floatChannelData![0][0] > 0.99, buffer.floatChannelData![1][0] == -1 else { fatalError("PCM endianness/channel regression") }
        do { _ = try pcm.decode(Data([1])); fatalError("Accepted partial PCM frame") } catch {}
        print("PASS: PCM byte order, stereo channels and partial-frame rejection")
    }
}
