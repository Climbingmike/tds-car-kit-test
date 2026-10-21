import Foundation

/// iAP2 link packet framing and checksums.
public struct IAP2Packet: Equatable {
    public static let presence = Data([0xff, 0x55, 0x02, 0x00, 0xee, 0x10])
    public var control: UInt8
    public var sequence: UInt8
    public var acknowledgement: UInt8
    public var session: UInt8
    public var payload: Data

    public init(control: UInt8, sequence: UInt8, acknowledgement: UInt8, session: UInt8, payload: Data = Data()) {
        self.control = control; self.sequence = sequence
        self.acknowledgement = acknowledgement; self.session = session; self.payload = payload
    }
    public func encoded() throws -> Data {
        let count = 9 + (payload.isEmpty ? 0 : payload.count + 1)
        guard count <= 65535 else { throw ProtocolError.limitExceeded("iAP2 packet") }
        var result = Data([0xff, 0x5a])
        result.putBE16(UInt16(count))
        result.append(contentsOf: [control, sequence, acknowledgement, session])
        result.append(Self.checksum(result))
        if !payload.isEmpty { result.append(payload); result.append(Self.checksum(payload)) }
        return result
    }
    static func checksum(_ bytes: Data) -> UInt8 { 0 &- bytes.reduce(UInt8(0), &+) }
}

public enum IAP2Event: Equatable { case presence; case packet(IAP2Packet) }

/// Incremental, bounded parser. No unvalidated peer lengths are used to allocate memory.
public struct IAP2Parser {
    private var bytes = Data()
    public init() {}
    public mutating func append(_ data: Data) throws -> [IAP2Event] {
        guard bytes.count + data.count <= 131072 else { throw ProtocolError.limitExceeded("iAP2 input buffer") }
        bytes.append(data)
        var result: [IAP2Event] = []
        while bytes.count >= 2 {
            if bytes.prefix(2) == IAP2Packet.presence.prefix(2) {
                guard bytes.count >= 6 else { break }
                guard bytes.prefix(6) == IAP2Packet.presence else { throw ProtocolError.malformed("presence signature") }
                bytes = Data(bytes.dropFirst(6)); result.append(.presence); continue
            }
            guard bytes.prefix(2) == Data([0xff, 0x5a]) else { throw ProtocolError.malformed("iAP2 sync") }
            guard bytes.count >= 9 else { break }
            let length = Int(bytes.be16(2))
            guard length >= 9, length != 10 else { throw ProtocolError.malformed("iAP2 length") }
            guard IAP2Packet.checksum(Data(bytes.prefix(9))) == 0 else { throw ProtocolError.malformed("iAP2 header checksum") }
            guard bytes.count >= length else { break }
            let payload = length > 9 ? Data(bytes.dropFirst(9).prefix(length - 10)) : Data()
            if length > 9, IAP2Packet.checksum(payload) != bytes.byte(length - 1) {
                throw ProtocolError.malformed("iAP2 payload checksum")
            }
            result.append(.packet(IAP2Packet(control: bytes.byte(4), sequence: bytes.byte(5),
                acknowledgement: bytes.byte(6), session: bytes.byte(7), payload: payload)))
            bytes = Data(bytes.dropFirst(length))
        }
        return result
    }
}

public struct IAP2Parameter: Equatable {
    public let id: UInt16
    public let value: Data
    public init(id: UInt16, value: Data) { self.id = id; self.value = value }
    public func encoded() throws -> Data {
        guard value.count <= 65531 else { throw ProtocolError.limitExceeded("iAP2 parameter") }
        var data = Data(); data.putBE16(UInt16(value.count + 4)); data.putBE16(id); data.append(value)
        return data
    }
    public static func parse(_ data: Data) throws -> [Self] {
        var rest = data; var values: [Self] = []
        while !rest.isEmpty {
            guard rest.count >= 4 else { throw ProtocolError.malformed("parameter header") }
            let count = Int(rest.be16(0))
            guard count >= 4, count <= rest.count else { throw ProtocolError.malformed("parameter length") }
            values.append(Self(id: rest.be16(2), value: Data(rest.dropFirst(4).prefix(count - 4))))
            rest = Data(rest.dropFirst(count))
        }
        return values
    }
}

public struct IAP2Message: Equatable {
    public let id: UInt16
    public let parameters: [IAP2Parameter]
    public init(id: UInt16, parameters: [IAP2Parameter] = []) { self.id = id; self.parameters = parameters }
    public func encoded() throws -> Data {
        var body = Data()
        for parameter in parameters { body.append(try parameter.encoded()) }
        guard body.count <= 65529 else { throw ProtocolError.limitExceeded("control message") }
        var data = Data([0x40, 0x40]); data.putBE16(UInt16(body.count + 6)); data.putBE16(id); data.append(body)
        return data
    }
    public static func parse(_ data: Data) throws -> Self {
        guard data.count >= 6, data.prefix(2) == Data([0x40, 0x40]), Int(data.be16(2)) == data.count else {
            throw ProtocolError.malformed("control message header")
        }
        return Self(id: data.be16(4), parameters: try IAP2Parameter.parse(Data(data.dropFirst(6))))
    }
}
