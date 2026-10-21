import Foundation

public enum AnnexB {
    /// Splits complete Annex-B access units into raw NAL units (without start codes).
    public static func units(in data: Data) throws -> [Data] {
        let bytes = [UInt8](data)
        guard bytes.count <= 8 * 1024 * 1024 else { throw ProtocolError.limitExceeded("video access unit") }
        var starts: [(Int, Int)] = []; var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0 {
                if bytes[i + 2] == 1 { starts.append((i, 3)); i += 3; continue }
                if i + 3 < bytes.count, bytes[i + 2] == 0, bytes[i + 3] == 1 {
                    starts.append((i, 4)); i += 4; continue
                }
            }
            i += 1
        }
        guard let first = starts.first, bytes.prefix(first.0).allSatisfy({ $0 == 0 }) else {
            throw ProtocolError.malformed("Annex B start code")
        }
        return try starts.enumerated().map { index, entry in
            let begin = entry.0 + entry.1
            let end = index + 1 < starts.count ? starts[index + 1].0 : bytes.count
            guard end > begin else { throw ProtocolError.malformed("empty NAL unit") }
            return Data(bytes[begin..<end])
        }
    }
    public static func lengthPrefixed(_ units: [Data]) throws -> Data {
        var result = Data()
        for unit in units {
            guard !unit.isEmpty, unit.count <= 8 * 1024 * 1024 else { throw ProtocolError.malformed("NAL unit size") }
            result.putBE32(UInt32(unit.count)); result.append(unit)
        }
        return result
    }
}
