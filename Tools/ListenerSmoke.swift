import Foundation
import Network
import Darwin

/// Reserves a TCP port, exercises the actual app listener's fallback, then sends RTSP locally.
/// Does not advertise Bluetooth or hand Wi-Fi credentials to another device.
@main
struct ListenerSmoke {
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let identity = try AccessoryIdentity(certificateChain: Data(contentsOf: directory.appendingPathComponent("certificate.p7b")),
            leafCertificate: Data(contentsOf: directory.appendingPathComponent("leaf.cer")),
            privateKeyX963: Data(contentsOf: directory.appendingPathComponent("private.x963")))
        let reservation = socket(AF_INET, SOCK_STREAM, 0)
        guard reservation >= 0 else { exit(1) }
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(reservation, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Darwin.listen(reservation, 1) == 0 else { exit(2) }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(reservation, $0, &size) }
        }
        let occupiedPort = UInt16(bigEndian: address.sin_port)
        let receiver = NativeReceiver()
        receiver.onLog = { print($0) }
        receiver.onFailure = { print("FAIL: listener"); exit(3) }
        receiver.onListening = { actual in
            guard actual != occupiedPort else { print("FAIL: did not fall back"); exit(4) }
            let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: actual)!, using: .tcp)
            connection.stateUpdateHandler = { state in
                if case .ready = state {
                    connection.send(content: Data("OPTIONS * RTSP/1.0\r\nCSeq: 42\r\n\r\n".utf8), completion: .contentProcessed { error in
                        if error != nil { exit(5) }
                    })
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
                        let text = String(decoding: data ?? Data(), as: UTF8.self)
                        guard error == nil, text.contains("200 OK"), text.contains("CSeq: 42") else { print("FAIL: response"); exit(6) }
                        connection.cancel(); receiver.stop(); close(reservation)
                        print("PASS: occupied-port fallback and native RTSP request/response"); exit(0)
                    }
                }
                if case .failed = state { exit(7) }
            }
            connection.start(queue: .main)
        }
        receiver.start(configuration: ReceiverConfiguration(address: "127.0.0.1", ssid: "", password: "", port: occupiedPort, deviceID: "02:00:00:00:00:01"), identity: identity, advertise: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { print("FAIL: timeout"); exit(8) }
        dispatchMain()
    }
}
