import Foundation

public enum ProtocolError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case malformed(String)
    case limitExceeded(String)
    public var errorDescription: String? { description }
    public var description: String {
        switch self {
        case .malformed(let reason): return "Malformed packet: \(reason)"
        case .limitExceeded(let reason): return "Packet limit exceeded: \(reason)"
        }
    }
}

extension Data {
    func byte(_ offset: Int) -> UInt8 { self[index(startIndex, offsetBy: offset)] }
    func be16(_ offset: Int) -> UInt16 { UInt16(byte(offset)) << 8 | UInt16(byte(offset + 1)) }
    func be32(_ offset: Int) -> UInt32 { (0..<4).reduce(0) { ($0 << 8) | UInt32(byte(offset + $1)) } }
    mutating func putBE16(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 8)); append(UInt8(truncatingIfNeeded: value))
    }
    mutating func putBE32(_ value: UInt32) {
        for shift in stride(from: 24, through: 0, by: -8) { append(UInt8(truncatingIfNeeded: value >> shift)) }
    }
}
