import Foundation
import CoreBluetooth

/// Bluetooth discovery and handoff. Runs on the main queue/run loop.
final class BLEBootstrap: NSObject, CBPeripheralManagerDelegate, StreamDelegate {
    // Use the full UUID for GATT registration and the short UUID for advertising.
    private let serviceID = CBUUID(string: "0000FC94-0000-1000-8000-00805F9B34FB")
    private let advertisedServiceID = CBUUID(string: "FC94")
    private let psmID = CBUUID(string: "F20BFCDB-B5B1-484F-AFBA-29DDE86C972E")
    private var manager: CBPeripheralManager?
    private var characteristic: CBMutableCharacteristic?
    private var psm: CBL2CAPPSM?
    private var channel: CBL2CAPChannel?
    private var configuration: ReceiverConfiguration?
    private var pending = Data()
    private var parser = BLEFrameParser()
    private var active = false
    var onLog: ((String) -> Void)?
    var onFailure: ((String) -> Void)?
    var onAdvertising: (() -> Void)?

    func start(configuration: ReceiverConfiguration) {
        stop(); active = true; self.configuration = configuration
        manager = CBPeripheralManager(delegate: self, queue: .main)
    }
    func stop() {
        active = false
        closeChannel()
        manager?.stopAdvertising()
        if let psm { manager?.unpublishL2CAPChannel(psm) }
        manager?.removeAllServices(); manager?.delegate = nil; manager = nil
        psm = nil; characteristic = nil; configuration = nil
    }
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard active, peripheral === manager else { return }
        switch peripheral.state {
        case .poweredOn: peripheral.publishL2CAPChannel(withEncryption: false)
        case .unauthorized: fail("Bluetooth permission denied. Enable TDS Car Kit in system privacy settings.")
        case .unsupported: fail("Bluetooth peripheral/L2CAP unavailable on this runtime.")
        case .poweredOff: onLog?("Turn Bluetooth on to advertise the receiver.")
        default: onLog?("Bluetooth state: \(peripheral.state.rawValue)")
        }
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didPublishL2CAPChannel PSM: CBL2CAPPSM, error: Error?) {
        guard active, peripheral === manager else { return }
        if let error { fail("L2CAP publish failed", error: error); return }
        psm = PSM
        let value = CBMutableCharacteristic(type: psmID, properties: [.read, .notify], value: nil, permissions: [.readable])
        characteristic = value
        let service = CBMutableService(type: serviceID, primary: true); service.characteristics = [value]
        onLog?("Registering Bluetooth service \(serviceID.uuidString) (\(serviceID.data.count)-byte UUID)")
        peripheral.add(service)
        onLog?("Bluetooth control channel published (PSM \(PSM))")
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard active, peripheral === manager, let configuration else { return }
        if let error { fail("Bluetooth service \(service.uuid.uuidString) failed", error: error); return }
        onLog?("Bluetooth service registered; advertising \(advertisedServiceID.uuidString)")
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [advertisedServiceID], CBAdvertisementDataLocalNameKey: configuration.name])
    }
    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        guard active, peripheral === manager else { return }
        if let error { fail("Advertising failed", error: error); return }
        onLog?("Advertising native receiver over Bluetooth")
        onAdvertising?()
    }
    private func fail(_ message: String, error: Error? = nil) {
        let detail: String
        if let error {
            let nsError = error as NSError
            detail = "\(message): \(nsError.localizedDescription) [\(nsError.domain) \(nsError.code)]"
        } else { detail = message }
        onLog?(detail)
        stop()
        onFailure?(detail)
    }
    private var psmData: Data {
        let value = psm ?? 0
        return Data([UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard request.characteristic.uuid == psmID else { peripheral.respond(to: request, withResult: .requestNotSupported); return }
        guard request.offset <= psmData.count else { peripheral.respond(to: request, withResult: .invalidOffset); return }
        request.value = psmData.dropFirst(request.offset); peripheral.respond(to: request, withResult: .success)
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        if let characteristic = self.characteristic { peripheral.updateValue(psmData, for: characteristic, onSubscribedCentrals: [central]) }
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard active, peripheral === manager else { return }
        if let error { onLog?("L2CAP open failed: \(error.localizedDescription)"); return }
        guard let channel else { return }
        closeChannel(); self.channel = channel
        for stream: Stream in [channel.inputStream, channel.outputStream] {
            stream.delegate = self; stream.schedule(in: .main, forMode: .common); stream.open()
        }
        onLog?("iPhone opened Bluetooth control channel")
        sendIdentification()
    }
    private func closeChannel() {
        if let channel {
            for stream: Stream in [channel.inputStream, channel.outputStream] {
                stream.close(); stream.remove(from: .main, forMode: .common); stream.delegate = nil
            }
        }
        channel = nil; pending = Data(); parser = BLEFrameParser()
    }
    private func sendIdentification() {
        guard let configuration else { return }
        send(type: 1, dictionary: [
            "displayName": .string(configuration.name), "modelName": .string("TDS Car Kit"),
            "PPID": .string("TDS_CAR_KIT-0001"), "authSerial": .data(Data(configuration.deviceID.utf8.prefix(16))),
            "accessoryProtocols": .array([]), "supportsWired": .bool(false),
            "supportsOOBPairing": .bool(false), "supportsEnhancedIntegration": .bool(false), "supportsThemeAssets": .bool(false)
        ])
    }
    private func sendStartSession() {
        guard let configuration else { return }
        send(type: 3, dictionary: [
            "wireless": .dictionary(["SSID": .string(configuration.ssid), "passphrase": .string(configuration.password),
                "channel": .uint(UInt64(configuration.wifiChannel)), "securityType": .uint(configuration.password.isEmpty ? 0 : 2),
                "ipAddresses": .array([.string(configuration.address)])]),
            "port": .uint(UInt64(configuration.port)), "deviceID": .string(configuration.deviceID),
            "publicKey": .string(""), "sourceVersion": .string("509.11"), "sdkVersion": .string("26.0")
        ])
    }
    private func send(type: UInt16, dictionary: [String: OPACKValue]) {
        do {
            let data = try BLEFrame(type: type, payload: OPACK.encode(.dictionary(dictionary))).encoded()
            guard pending.count + data.count <= 131072 else { throw ProtocolError.limitExceeded("BLE output queue") }
            pending.append(data); flush()
            onLog?("Sent BLE message \(type) (\(data.count) bytes)")
        } catch { onLog?("Bluetooth encoding failed: \(error)"); closeChannel() }
    }
    private func flush() {
        guard let output = channel?.outputStream else { return }
        while !pending.isEmpty, output.hasSpaceAvailable {
            let count = pending.withUnsafeBytes { output.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: min(4096, pending.count)) }
            if count < 0 { onLog?("Bluetooth write failed"); closeChannel(); return }
            if count == 0 { return }
            pending = Data(pending.dropFirst(count))
        }
    }
    func stream(_ stream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .hasSpaceAvailable: flush()
        case .hasBytesAvailable:
            guard let input = stream as? InputStream else { return }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while input.hasBytesAvailable {
                let count = input.read(&bytes, maxLength: bytes.count)
                if count <= 0 { if count < 0 { closeChannel() }; return }
                do {
                    for frame in try parser.append(Data(bytes.prefix(count))) {
                        onLog?("Received BLE message \(frame.type) (\(frame.payload.count) bytes)")
                        // Message type 2 requests StartSession.
                        if frame.type == 2 { sendStartSession() }
                    }
                } catch { onLog?("Rejected Bluetooth frame: \(error)"); closeChannel(); return }
            }
        case .errorOccurred, .endEncountered: onLog?("Bluetooth control channel closed"); closeChannel()
        default: break
        }
    }
}
