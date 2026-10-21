import Foundation

/// BLE frames use a big-endian u16 type and u32 OPACK payload size.
public struct BLEFrame: Equatable {
    public let type: UInt16
    public let payload: Data
    public init(type: UInt16, payload: Data) { self.type = type; self.payload = payload }
    public func encoded() throws -> Data {
        guard payload.count <= 65536 else { throw ProtocolError.limitExceeded("BLE control payload") }
        var data = Data(); data.putBE16(type); data.putBE32(UInt32(payload.count)); data.append(payload); return data
    }
}
public struct BLEFrameParser {
    private var buffer = Data()
    public init() {}
    public mutating func append(_ data: Data) throws -> [BLEFrame] {
        guard buffer.count + data.count <= 131084 else { throw ProtocolError.limitExceeded("BLE input buffer") }
        buffer.append(data); var frames: [BLEFrame] = []
        while buffer.count >= 6 {
            let length = Int(buffer.be32(2))
            guard length <= 65536 else { throw ProtocolError.limitExceeded("BLE control payload") }
            guard buffer.count >= length + 6 else { break }
            frames.append(BLEFrame(type: buffer.be16(0), payload: Data(buffer.dropFirst(6).prefix(length))))
            buffer = Data(buffer.dropFirst(length + 6))
        }
        return frames
    }
}
