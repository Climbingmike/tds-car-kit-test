import Foundation

/// Subset used by BLE identification and Wi-Fi handoff dictionaries.
/// Reference-free encoding deliberately avoids an object-cache dependency.
public indirect enum OPACKValue {
    case bool(Bool), uint(UInt64), string(String), data(Data), array([OPACKValue]), dictionary([String: OPACKValue])
}
public enum OPACK {
    public static func encode(_ value: OPACKValue) throws -> Data { try encode(value, depth: 0) }
    private static func encode(_ value: OPACKValue, depth: Int) throws -> Data {
        guard depth <= 32 else { throw ProtocolError.limitExceeded("OPACK nesting") }
        switch value {
        case .bool(let value): return Data([value ? 1 : 2])
        case .uint(let value):
            if value <= 39 { return Data([UInt8(value) + 8]) }
            let count = value <= 0xff ? 1 : value <= 0xffff ? 2 : value <= 0xffffffff ? 4 : 8
            var data = Data([count == 1 ? 0x30 : count == 2 ? 0x31 : count == 4 ? 0x32 : 0x33])
            for index in 0..<count { data.append(UInt8(truncatingIfNeeded: value >> (index * 8))) }
            return data
        case .string(let text): return try bytes(Data(text.utf8), shortBase: 0x40, longBase: 0x60)
        case .data(let data): return try bytes(data, shortBase: 0x70, longBase: 0x90)
        case .array(let values):
            guard values.count <= 1024 else { throw ProtocolError.limitExceeded("OPACK array") }
            var data = Data([0xd0 + UInt8(min(values.count, 15))])
            for value in values { data.append(try encode(value, depth: depth + 1)) }
            if values.count >= 15 { data.append(3) }; return data
        case .dictionary(let values):
            guard values.count <= 1024 else { throw ProtocolError.limitExceeded("OPACK dictionary") }
            var data = Data([0xe0 + UInt8(min(values.count, 15))])
            for key in values.keys.sorted() {
                data.append(try encode(.string(key), depth: depth + 1))
                data.append(try encode(values[key]!, depth: depth + 1))
            }
            if values.count >= 15 { data.append(3) }; return data
        }
    }
    private static func bytes(_ value: Data, shortBase: UInt8, longBase: UInt8) throws -> Data {
        guard value.count <= 65536 else { throw ProtocolError.limitExceeded("OPACK byte string") }
        var output = Data()
        if value.count <= 32 { output.append(shortBase + UInt8(value.count)) }
        else {
            let count = value.count <= 255 ? 1 : value.count <= 65535 ? 2 : 4
            output.append(longBase + UInt8(count == 4 ? 3 : count))
            for index in 0..<count { output.append(UInt8(truncatingIfNeeded: value.count >> (8 * index))) }
        }
        output.append(value); return output
    }
}
