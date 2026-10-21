// SPDX-License-Identifier: GPL-3.0-or-later
// AirPlay screen framing adapted from PlayPort ScreenStream.kt.
import Foundation
import CryptoKit

public final class ScreenStream {
    private let key: SymmetricKey
    private var buffer = Data()
    private var counter: UInt64 = 0
    private var failed = false
    public init(secret: SymmetricKey, connectionID: UInt64) {
        key = PairVerify.derive(secret, salt: "DataStream-Salt\(connectionID)", info: "DataStream-Output-Encryption-Key")
    }
    /// Each returned access unit is Annex-B, including SPS/PPS configuration units.
    public func append(_ bytes: Data) throws -> [Data] {
        guard !failed else { throw ProtocolError.malformed("closed video stream") }
        do {
            guard buffer.count + bytes.count <= 8 * 1024 * 1024 + 128 + 65536 else { throw ProtocolError.limitExceeded("video buffer") }
            buffer.append(bytes); var result: [Data] = []
            while buffer.count >= 128 {
                let length = (0..<4).reduce(0) { $0 | (Int(buffer.byte($1)) << ($1 * 8)) }
                guard length <= 8 * 1024 * 1024 else { throw ProtocolError.limitExceeded("video frame") }
                guard buffer.count >= 128 + length else { break }
                let header = Data(buffer.prefix(128)), body = Data(buffer.dropFirst(128).prefix(length))
                buffer = Data(buffer.dropFirst(128 + length))
                switch header.byte(4) {
                case 0:
                    guard body.count >= 16, counter < UInt64.max else { throw ProtocolError.malformed("encrypted video frame") }
                    var nonce = Data(count: 4)
                    for shift in stride(from: 0, through: 56, by: 8) { nonce.append(UInt8(truncatingIfNeeded: counter >> shift)) }
                    let box = try ChaChaPoly.SealedBox(nonce: .init(data: nonce), ciphertext: body.dropLast(16), tag: body.suffix(16))
                    let plain = try ChaChaPoly.open(box, using: key, authenticating: header)
                    counter += 1; result.append(try Self.annexB(plain))
                case 1: result.append(try Self.configuration(body))
                default: break // Timing/extension records have no picture data.
                }
            }
            return result
        } catch { failed = true; buffer = Data(); throw error }
    }
    private static func annexB(_ data: Data) throws -> Data {
        if data.starts(with: [0, 0, 0, 1]) { _ = try AnnexB.units(in: data); return data }
        var offset = 0, output = Data()
        while offset < data.count {
            guard offset + 4 <= data.count else { throw ProtocolError.malformed("video NAL length") }
            let length = Int(data.be32(offset)); offset += 4
            guard length > 0, length <= data.count - offset else { throw ProtocolError.malformed("video NAL body") }
            output.append(contentsOf: [0, 0, 0, 1]); output.append(data.dropFirst(offset).prefix(length)); offset += length
        }
        return output
    }
    static func configuration(_ body: Data) throws -> Data {
        let data: Data
        if let marker = body.range(of: Data("avcC".utf8)) { data = Data(body[marker.upperBound...]) }
        else { data = body }
        guard data.count >= 7, data.byte(0) == 1, data.byte(4) & 3 == 3 else { throw ProtocolError.malformed("unsupported AVC configuration") }
        var offset = 6, output = Data()
        func readUnits(_ count: Int) throws {
            guard count > 0 else { throw ProtocolError.malformed("missing H.264 parameters") }
            for _ in 0..<count {
                guard offset + 2 <= data.count else { throw ProtocolError.malformed("AVC parameter length") }
                let length = Int(data.be16(offset)); offset += 2
                guard length > 0, length <= data.count - offset else { throw ProtocolError.malformed("AVC parameter body") }
                output.append(contentsOf: [0, 0, 0, 1]); output.append(data.dropFirst(offset).prefix(length)); offset += length
            }
        }
        try readUnits(Int(data.byte(5) & 31))
        guard offset < data.count else { throw ProtocolError.malformed("missing AVC PPS count") }
        let count = Int(data.byte(offset)); offset += 1; try readUnits(count)
        return output
    }
}
