import Foundation
import Network
import Darwin

/// Observes the phone's CarPlay control service. Discovery is diagnostic until a
/// service can be matched to the intended phone; never triggers unrelated peers.
final class CarPlayControlBrowser {
    private var browser: NWBrowser?
    var onLog: ((String) -> Void)?
    func start() {
        stop()
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_carplay-ctrl._tcp", domain: nil), using: .tcp)
        self.browser = browser
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state { self?.onLog?("CarPlay control discovery failed: \(error.localizedDescription)") }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.onLog?("CarPlay control services discovered: \(results.count)")
            for result in results { self?.onLog?("CarPlay control endpoint: \(result.endpoint)") }
        }
        browser.start(queue: .main)
    }
    func stop() { browser?.cancel(); browser = nil }
}

/// Explicitly choose a TDS Car Kit
/// receiver, then use the source iPhone's accessory transport to request that display.
final class TDSCarKitReceiverBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    struct Target: Equatable {
        let name: String
        let address: String
        let port: UInt16
        let deviceID: String
    }
    private var browser: NetServiceBrowser?
    private var services: [NetService] = []
    private var resolved: [ObjectIdentifier: Target] = [:]
    var onTargets: (([Target]) -> Void)?
    var onLog: ((String) -> Void)?
    func start() {
        stop()
        let browser = NetServiceBrowser(); self.browser = browser; browser.delegate = self
        browser.searchForServices(ofType: ReceiverConfiguration.discoveryType, inDomain: "local.")
    }
    func stop() {
        browser?.delegate = nil; browser?.stop(); browser = nil
        services.forEach { $0.delegate = nil; $0.stop() }; services = []; resolved = [:]
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard browser === self.browser else { return }
        services.append(service); service.delegate = self; service.resolve(withTimeout: 8)
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        guard browser === self.browser else { return }
        let removed = services.filter { $0.name == service.name && $0.type == service.type && $0.domain == service.domain }
        removed.forEach { resolved.removeValue(forKey: ObjectIdentifier($0)); $0.delegate = nil; $0.stop() }
        services.removeAll { candidate in removed.contains { $0 === candidate } }; publish()
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        onLog?("Receiver discovery failed: \(errorDict)")
    }
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard services.contains(where: { $0 === sender }), let txtData = sender.txtRecordData() else { return }
        let txt = NetService.dictionary(fromTXTRecord: txtData)
        guard txt["app"] == Data("TDSCarKit".utf8),
              let deviceID = txt["deviceid"].flatMap({ String(data: $0, encoding: .utf8) }),
              deviceID.range(of: "^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$", options: .regularExpression) != nil,
              deviceID.caseInsensitiveCompare(ReceiverConfiguration.persistentDeviceID()) != .orderedSame,
              let port = UInt16(exactly: sender.port), port > 0 else { return }
        for data in sender.addresses ?? [] {
            var address = sockaddr_in()
            guard data.count >= MemoryLayout<sockaddr_in>.size else { continue }
            _ = withUnsafeMutableBytes(of: &address) { data.copyBytes(to: $0, count: MemoryLayout<sockaddr_in>.size) }
            guard address.sin_family == sa_family_t(AF_INET) else { continue }
            let numeric = UInt32(bigEndian: address.sin_addr.s_addr)
            guard numeric >> 24 != 0, numeric >> 24 != 127, numeric >> 24 < 224 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &address.sin_addr, &buffer, socklen_t(buffer.count)) != nil else { continue }
            let target = Target(name: sender.name, address: String(cString: buffer), port: port, deviceID: deviceID)
            resolved[ObjectIdentifier(sender)] = target
            onLog?("Found receiver \(target.name) at \(target.address):\(target.port)")
            publish(); return
        }
    }
    private func publish() {
        var unique: [String: Target] = [:]
        resolved.values.forEach { unique[$0.deviceID.uppercased()] = $0 }
        onTargets?(unique.values.sorted { $0.name < $1.name })
    }
}
