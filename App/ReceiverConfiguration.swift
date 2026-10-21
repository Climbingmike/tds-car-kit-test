import Foundation
import Darwin

struct ReceiverConfiguration {
    var name = "TDS Car Kit"
    static let discoveryType = "_tds-carkit._tcp."
    var address: String
    var ssid: String
    var password: String
    var port: UInt16 = 7000
    var width = 1280
    var height = 720
    var wifiChannel: UInt8 = 36
    var audioEnabled = true
    var rightHandDrive = true
    let deviceID: String

    static func localIPv4Addresses() -> [String] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var result: [String] = []
        var current = first
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  entry.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let value = String(cString: host)
                if String(cString: entry.pointee.ifa_name) == "en0" { result.insert(value, at: 0) }
                else { result.append(value) }
            }
        }
        return result
    }
    /// Personal Hotspot exposes an active bridge interface; never infer it from
    /// a cellular address or a hard-coded 172.20.10.x subnet.
    static func personalHotspotAddress() -> String? {
        #if targetEnvironment(macCatalyst) || os(macOS)
        return nil
        #else
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return nil }
        defer { freeifaddrs(first) }
        var current = first
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            guard String(cString: entry.pointee.ifa_name).hasPrefix("bridge"),
                  entry.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
        #endif
    }
    static func persistentDeviceID() -> String {
        if let existing = UserDefaults.standard.string(forKey: "receiverDeviceID") { return existing }
        var random = [UInt8](repeating: 0, count: 6)
        _ = SecRandomCopyBytes(kSecRandomDefault, random.count, &random)
        random[0] = (random[0] | 2) & 0xfe
        let value = random.map { String(format: "%02X", $0) }.joined(separator: ":")
        UserDefaults.standard.set(value, forKey: "receiverDeviceID")
        return value
    }
    func validate(requiresLocalAddress: Bool = true, requiresWiFiCredentials: Bool = true) throws {
        var parsed = in_addr()
        guard inet_pton(AF_INET, address, &parsed) == 1 else {
            throw ConfigurationError("Choose a receiver with a valid IPv4 address.")
        }
        if requiresLocalAddress && !Self.localIPv4Addresses().contains(address) {
            throw ConfigurationError("Choose an IP address belonging to this device’s network connection.")
        }
        guard requiresWiFiCredentials else { return }
        guard !ssid.isEmpty, ssid.utf8.count <= 32 else { throw ConfigurationError(ssid.isEmpty ? "Enter the Wi-Fi network name before starting." : "Wi-Fi network names cannot exceed 32 UTF-8 bytes.") }
        guard password.isEmpty || (8...63).contains(password.utf8.count) else {
            throw ConfigurationError("Enter an 8–63-byte Wi-Fi password, or leave it empty for an open network.")
        }
    }
}
import Security

struct ConfigurationError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
