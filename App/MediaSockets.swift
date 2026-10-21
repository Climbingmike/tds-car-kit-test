import Foundation
import Darwin

/// Queue-confined socket helpers. Ports are bound synchronously before SETUP replies.
final class MediaTCPListener {
    let port: UInt16
    private var source: DispatchSourceRead?
    var onConnection: ((MediaTCPConnection) -> Void)?
    init(queue: DispatchQueue, peerAddress: String) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        var allowed = in_addr()
        guard inet_pton(AF_INET, peerAddress, &allowed) == 1 else { close(fd); throw ProtocolError.malformed("IPv4 media peer required") }
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd, 2) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { close(fd); throw POSIXError(.EIO) }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } }
        guard named == 0 else { close(fd); throw POSIXError(.EIO) }
        port = UInt16(bigEndian: address.sin_port)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        self.source = source
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var remote = sockaddr_in(); var count = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &remote) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &count) } }
            guard client >= 0 else { return }
            guard remote.sin_addr.s_addr == allowed.s_addr, let callback = self.onConnection else { close(client); return }
            callback(MediaTCPConnection(fd: client, queue: queue))
        }
        source.setCancelHandler { close(fd) }; source.resume()
    }
    func stop() { source?.cancel(); source = nil; onConnection = nil }
    deinit { stop() }
}

final class MediaTCPConnection {
    private let io: DispatchIO
    private let queue: DispatchQueue
    private var pending = 0
    private var stopped = false
    var onBytes: ((Data) throws -> Void)?
    var onClose: (() -> Void)?
    init(fd: Int32, queue: DispatchQueue) {
        self.queue = queue
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        io = DispatchIO(type: .stream, fileDescriptor: fd, queue: queue) { _ in close(fd) }
        io.setLimit(lowWater: 1); io.setLimit(highWater: 65536)
    }
    func start() {
        io.read(offset: 0, length: Int.max, queue: queue) { [weak self] done, data, error in
            guard let self, !self.stopped else { return }
            do { if let data, !data.isEmpty { try self.onBytes?(Data(data)) } }
            catch { self.stop(); self.onClose?(); return }
            if done || error != 0 { self.stop(); self.onClose?() }
        }
    }
    func send(_ data: Data) throws {
        guard !stopped, pending + data.count <= 256 * 1024 else { throw ProtocolError.limitExceeded("event output queue") }
        pending += data.count
        let bytes = data.withUnsafeBytes { DispatchData(bytes: $0) }
        io.write(offset: 0, data: bytes, queue: queue) { [weak self] done, _, error in
            guard let self else { return }
            if done { self.pending -= data.count }
            if error != 0 { self.stop(); self.onClose?() }
        }
    }
    func stop() { guard !stopped else { return }; stopped = true; io.close(flags: .stop); onBytes = nil }
    deinit { stop() }
}

final class MediaTiming {
    let port: UInt16
    private var source: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var pending: Data?
    private var offset: Double = 0
    private let origin = Date().timeIntervalSince1970 + 2_208_988_800
    private let monotonic = ProcessInfo.processInfo.systemUptime
    private func now() -> Double { origin + ProcessInfo.processInfo.systemUptime - monotonic + offset }
    func timestamp() -> UInt64 { Self.encode(now()).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } }
    private static func encode(_ time: Double) -> Data {
        let seconds = UInt64(time.rounded(.down)), fraction = UInt64((time - time.rounded(.down)) * 4_294_967_296)
        let value = (seconds << 32) | fraction
        return Data(stride(from: 56, through: 0, by: -8).map { UInt8(truncatingIfNeeded: value >> $0) })
    }
    private static func decode(_ bytes: Data) -> Double {
        let value = bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return Double(value >> 32) + Double(value & 0xffffffff) / 4_294_967_296
    }
    init(queue: DispatchQueue, peerAddress: String, peerPort: UInt16) throws {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var remote = sockaddr_in(); remote.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); remote.sin_family = sa_family_t(AF_INET); remote.sin_port = peerPort.bigEndian
        guard inet_pton(AF_INET, peerAddress, &remote.sin_addr) == 1 else { close(fd); throw ProtocolError.malformed("timing peer") }
        var local = sockaddr_in(); local.sin_len = remote.sin_len; local.sin_family = remote.sin_family
        let bound = withUnsafePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { close(fd); throw POSIXError(.EIO) }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } }
        guard named == 0 else { close(fd); throw POSIXError(.EIO) }
        port = UInt16(bigEndian: local.sin_port)
        let send: (Data) -> Void = { data in
            data.withUnsafeBytes { bytes in
                _ = withUnsafePointer(to: &remote) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            }
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue); self.source = source
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var bytes = [UInt8](repeating: 0, count: 2048), peer = sockaddr_in(); var count = socklen_t(MemoryLayout<sockaddr_in>.size)
            let length = withUnsafeMutablePointer(to: &peer) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &bytes, bytes.count, 0, $0, &count) } }
            guard length == 32, peer.sin_addr.s_addr == remote.sin_addr.s_addr, peer.sin_port == remote.sin_port else { return }
            let message = Data(bytes.prefix(length))
            if bytes[1] == 210 {
                var response = Data([0x80, 211, 0, 7]) + Data(count: 4)
                response += message.suffix(8); response += Self.encode(self.now()); response += Self.encode(self.now()); send(response)
            } else if bytes[1] == 211, let pending = self.pending, message.subdata(in: 8..<16) == pending {
                let t1 = Self.decode(pending), t2 = Self.decode(message.subdata(in: 16..<24)), t3 = Self.decode(message.suffix(8)), t4 = self.now()
                let rtt = (t4 - t1) - (t3 - t2)
                if rtt >= 0, rtt < 1 { self.offset += ((t2 - t1) + (t3 - t4)) / 2 }
                self.pending = nil
            }
        }
        source.setCancelHandler { close(fd) }; source.resume()
        if peerPort != 0 {
            let timer = DispatchSource.makeTimerSource(queue: queue); self.timer = timer
            timer.schedule(deadline: .now(), repeating: 1)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let stamp = Self.encode(self.now()); self.pending = stamp
                send(Data([0x80, 210, 0, 7]) + Data(count: 20) + stamp)
            }
            timer.resume()
        }
    }
    func stop() { timer?.cancel(); timer = nil; source?.cancel(); source = nil }
    deinit { stop() }
}
