import Foundation

/// Main-queue session for the direct accessory transport.
final class SameDeviceProbe {
    private let transport = DirectAccessoryTransport()
    private var parser = IAP2Parser()
    private var generation = UUID()
    private var active = false
    private var linked = false
    private var authenticated = false
    private var identified = false
    private var sequence: UInt8 = 0x10
    private var acknowledgement: UInt8 = 0
    private var lastPayloadSequence: UInt8?
    private var session: UInt8 = 1
    private var identity: AccessoryIdentity?
    private var configuration: ReceiverConfiguration?
    private var messageBytes = Data()
    private var requested = false
    private var controlConnected = false
    private var expectsLocalControl = true
    var onLog: ((String) -> Void)?
    var onFinished: ((String) -> Void)?
    var onStage: ((String) -> Void)?

    func start(configuration: ReceiverConfiguration, identity: AccessoryIdentity, expectsLocalControl: Bool = true) {
        stop(); active = true; self.identity = identity; self.configuration = configuration
        self.expectsLocalControl = expectsLocalControl
        let run = generation
        transport.onData = { [weak self] data in self?.receive(data) }
        do {
            // Use transport type 2 for a Wi-Fi accessory connection.
            try transport.start(withIdentifier: configuration.deviceID, transportType: 2)
            stage("Local accessory endpoint created (transport 2); establishing iAP2")
            try transport.send(IAP2Packet.presence)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, self.active, self.generation == run else { return }
                do {
                    let syn = IAP2Packet(control: 0x80, sequence: self.sequence, acknowledgement: 0, session: 0,
                        payload: Data([1, 5, 8, 0, 7, 0xd0, 0, 0xfa, 3, 3, 1, 0, 1]))
                    try self.transport.send(syn.encoded())
                } catch { self.finish("Same-device write failed: \(error.localizedDescription)") }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                guard let self, self.active, self.generation == run, !self.requested else { return }
                self.finish("Session startup timed out (link=\(self.linked), authenticated=\(self.authenticated), identified=\(self.identified))")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
                guard let self, self.active, self.generation == run, self.expectsLocalControl, !self.controlConnected else { return }
                self.finish("No CarPlay control connection received. Check the Wi-Fi name, password and channel, then retry.")
            }
        } catch { finish("Same-device transport failed: \(error.localizedDescription)") }
    }
    func stop() {
        active = false; generation = UUID(); transport.stop(); transport.onData = nil; parser = IAP2Parser()
        identity = nil; configuration = nil; messageBytes = Data(); sequence = 0x10; acknowledgement = 0
        session = 1; lastPayloadSequence = nil; linked = false; authenticated = false; identified = false; requested = false; controlConnected = false
    }
    func didConnectControl() {
        guard active else { return }
        controlConnected = true
        stage("CarPlay control connected; negotiating session")
    }
    private func requestSession(_ configuration: ReceiverConfiguration) throws {
        let wifi = try AccessoryMessages.WiFi(ssid: configuration.ssid, password: configuration.password, channel: configuration.wifiChannel)
        try send(AccessoryMessages.startSession(address: configuration.address, port: configuration.port,
            deviceID: configuration.deviceID, wifi: wifi))
    }
    private func stage(_ message: String) { onLog?(message); onStage?(message) }
    private func finish(_ message: String) { onLog?(message); stop(); onFinished?(message) }
    private func ack() throws {
        try transport.send(IAP2Packet(control: 0x40, sequence: sequence, acknowledgement: acknowledgement, session: 0).encoded())
    }
    private func send(_ message: IAP2Message) throws {
        sequence &+= 1
        try transport.send(IAP2Packet(control: 0x40, sequence: sequence, acknowledgement: acknowledgement,
            session: session, payload: message.encoded()).encoded())
        onLog?(String(format: "TX iAP2 message 0x%04X", message.id))
    }
    private func receive(_ data: Data) {
        guard active else { return }
        do {
            for event in try parser.append(data) {
                switch event {
                case .presence: onLog?("Local iOS service answered iAP2 presence detect")
                case .packet(let packet):
                    acknowledgement = packet.sequence
                    if packet.control & 0x20 != 0 { throw ProtocolError.malformed("iOS reset the iAP2 link") }
                    if packet.control & 0x80 != 0 {
                        guard packet.payload.count >= 13 else { throw ProtocolError.malformed("short iAP2 SYN") }
                        session = packet.payload[packet.payload.startIndex + 10]
                        linked = true; try ack(); stage("Local iAP2 link connected; awaiting accessory authentication")
                        continue
                    }
                    guard linked, packet.session == session, !packet.payload.isEmpty else { continue }
                    try ack()
                    if lastPayloadSequence == packet.sequence { continue }
                    lastPayloadSequence = packet.sequence
                    guard messageBytes.count + packet.payload.count <= 65535 else { throw ProtocolError.limitExceeded("iAP2 control reassembly") }
                    messageBytes.append(packet.payload)
                    while messageBytes.count >= 6 {
                        let count = Int(messageBytes[messageBytes.startIndex + 2]) * 256 + Int(messageBytes[messageBytes.startIndex + 3])
                        guard count >= 6 else { throw ProtocolError.malformed("control length") }
                        guard messageBytes.count >= count else { break }
                        let message = try IAP2Message.parse(Data(messageBytes.prefix(count)))
                        messageBytes = Data(messageBytes.dropFirst(count))
                        try handle(message)
                        if !active { return }
                    }
                }
            }
        } catch { finish("Local accessory session failed: \(error.localizedDescription)") }
    }
    private func handle(_ message: IAP2Message) throws {
        guard let identity, let configuration else { return }
        onLog?(String(format: "RX iAP2 message 0x%04X", message.id))
        switch message.id {
        case 0xaa00:
            try send(IAP2Message(id: 0xaa01, parameters: [IAP2Parameter(id: 0, value: identity.certificateChain)]))
        case 0xaa02:
            guard let challenge = message.parameters.first(where: { $0.id == 0 })?.value else { throw ProtocolError.malformed("missing authentication challenge") }
            try send(IAP2Message(id: 0xaa03, parameters: [IAP2Parameter(id: 0, value: identity.sign(challenge: challenge))]))
        case 0xaa04: finish("iOS rejected accessory authentication (0xAA04)")
        case 0xaa05: authenticated = true; stage("iOS accepted accessory authentication")
        case 0x1d00: try send(AccessoryMessages.identification(name: configuration.name, deviceID: configuration.deviceID))
        case 0x1d02: identified = true; stage("iOS accepted accessory identification; waiting for CarPlay availability")
        case 0x1d03:
            let rejected = message.parameters.map { String(format: "%04X:%@", $0.id, $0.value.prefix(32).map { String(format: "%02X", $0) }.joined()) }.joined(separator: ",")
            finish("iOS rejected identification (0x1D03): \(rejected)")
        case 0x4300:
            guard authenticated, identified else { throw ProtocolError.malformed("CarPlay availability before authentication/identification") }
            for group in message.parameters {
                let nested = try IAP2Parameter.parse(group.value)
                if let value = nested.first(where: { $0.id == 0 })?.value.first {
                    onLog?("CarPlay availability transport \(group.id): \(value)")
                }
            }
            if controlConnected || (!expectsLocalControl && requested) { return }
            try requestSession(configuration)
            if !requested && expectsLocalControl {
                let run = generation
                for delay in [3.0, 6.0, 9.0] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        guard let self, self.active, self.generation == run, !self.controlConnected else { return }
                        do { try self.requestSession(configuration) }
                        catch { self.finish("Session retry failed: \(error)") }
                    }
                }
            }
            requested = true
            stage(expectsLocalControl
                ? "CarPlay session requested on \(configuration.address):\(configuration.port); awaiting TCP connection"
                : "CarPlay requested on \(configuration.name) (\(configuration.address):\(configuration.port)). Keep this app open and check the iPad display.")
        default: onLog?(String(format: "Unhandled accessory message 0x%04X", message.id))
        }
    }
}
