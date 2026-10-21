import Foundation

public struct RTSPRequest: Equatable {
    public let method: String
    public let target: String
    public let version: String
    public let headers: [String: String]
    public let body: Data
}

public struct RTSPParser {
    private var buffer = Data()
    private let allowResponses: Bool
    public static let maximumBody = 2 * 1024 * 1024
    public init(allowResponses: Bool = false) { self.allowResponses = allowResponses }
    public mutating func takeBufferedData() -> Data {
        let data = buffer; buffer = Data(); return data
    }
    public mutating func append(_ data: Data, maximumRequests: Int = .max) throws -> [RTSPRequest] {
        guard buffer.count + data.count <= Self.maximumBody + 32768 else { throw ProtocolError.limitExceeded("RTSP buffer") }
        buffer.append(data)
        var output: [RTSPRequest] = []
        while let boundary = buffer.range(of: Data("\r\n\r\n".utf8)) {
            let headerSize = buffer.distance(from: buffer.startIndex, to: boundary.lowerBound)
            guard headerSize <= 16384 else { throw ProtocolError.limitExceeded("RTSP headers") }
            guard let headerText = String(data: buffer.prefix(headerSize), encoding: .utf8) else {
                throw ProtocolError.malformed("RTSP header encoding")
            }
            var lines = headerText.components(separatedBy: "\r\n")
            let parts = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
            let response = allowResponses && parts.count >= 3 && ["RTSP/1.0", "HTTP/1.1"].contains(String(parts[0]))
            guard response || (parts.count == 3 && ["RTSP/1.0", "HTTP/1.1"].contains(String(parts[2]))) else {
                throw ProtocolError.malformed("request line")
            }
            var headers: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { throw ProtocolError.malformed("header") }
                let name = line[..<colon].lowercased()
                guard !name.isEmpty, headers[name] == nil else { throw ProtocolError.malformed("duplicate/empty header") }
                headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard headers["transfer-encoding"] == nil else { throw ProtocolError.malformed("chunked transfer unsupported") }
            let lengthText = headers["content-length"] ?? "0"
            guard !lengthText.isEmpty, lengthText.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  let length = Int(lengthText), length <= Self.maximumBody else {
                throw ProtocolError.malformed("content length")
            }
            let total = headerSize + 4 + length
            guard buffer.count >= total else { return output }
            output.append(RTSPRequest(method: String(parts[0]), target: String(parts[1]), version: String(response ? parts[0] : parts[2]),
                headers: headers, body: Data(buffer.dropFirst(headerSize + 4).prefix(length))))
            buffer = Data(buffer.dropFirst(total))
            if output.count >= maximumRequests { return output }
        }
        if buffer.count > 16384 { throw ProtocolError.limitExceeded("unterminated RTSP header") }
        return output
    }
}

public struct RTSPResponse {
    public var status: Int
    public var reason: String
    public var body: Data
    public var contentType: String
    public init(status: Int = 200, reason: String = "OK", body: Data = Data(), contentType: String = "application/octet-stream") {
        self.status = status; self.reason = reason; self.body = body; self.contentType = contentType
    }
    public func encoded(for request: RTSPRequest) -> Data {
        var lines = ["\(request.version) \(status) \(reason)", "Server: TDSCarKit/0.1", "Content-Length: \(body.count)", "Content-Type: \(contentType)"]
        if let sequence = request.headers["cseq"] { lines.append("CSeq: \(sequence)") }
        if request.method == "OPTIONS" { lines.append("Public: OPTIONS, GET, POST, SETUP, RECORD, TEARDOWN") }
        var data = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8); data.append(body); return data
    }
}
