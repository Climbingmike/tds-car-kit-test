import Foundation
import CryptoKit
import Security

/// Per-network credentials stay on this device, accessible only while unlocked.
enum WiFiCredentials {
    private static func query(_ ssid: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "local.tds.carkit.wifi",
         kSecAttrAccount as String: ssid]
    }
    static func password(for ssid: String) throws -> String? {
        guard !ssid.isEmpty else { return nil }
        var lookup = query(ssid); lookup[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return password
    }
    static func save(_ password: String, for ssid: String) throws {
        let attributes: [String: Any] = [kSecValueData as String: Data(password.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query(ssid) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query(ssid).merging(attributes) { _, value in value } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
    static func forget(_ ssid: String) throws {
        let status = SecItemDelete(query(ssid) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}

/// Persistent receiver key, independent of the accessory certificate identity.
final class AirPlayCredentials {
    let signingKey: Curve25519.Signing.PrivateKey
    let identifier: String
    private func pairingQuery(_ identifier: String) -> [String: Any] {
        let account = SHA256.hash(data: Data(identifier.utf8)).map { String(format: "%02x", $0) }.joined()
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "local.tds.carkit.controllers", kSecAttrAccount as String: account]
    }
    func controller(_ identifier: String) throws -> Curve25519.Signing.PublicKey? {
        var query = pairingQuery(identifier); query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return try Curve25519.Signing.PublicKey(rawRepresentation: data)
    }
    func saveController(_ identifier: String, key: Data) throws {
        if let existing = try controller(identifier) {
            guard existing.rawRepresentation == key else { throw ProtocolError.malformed("paired controller key changed") }
            return
        }
        var item = pairingQuery(identifier); item[kSecValueData as String] = key
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
    init() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "local.tds.carkit.airplay", kSecAttrAccount as String: "identity"]
        var lookup = query; lookup[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data {
            let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            guard let key = values?["key"] as? Data, let id = values?["id"] as? String else { throw ProtocolError.malformed("stored AirPlay identity") }
            signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: key); identifier = id
        } else if status == errSecItemNotFound {
            signingKey = Curve25519.Signing.PrivateKey(); identifier = UUID().uuidString
            let data = try PropertyListSerialization.data(fromPropertyList: ["key": signingKey.rawRepresentation, "id": identifier], format: .binary, options: 0)
            var item = query; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let stored = SecItemAdd(item as CFDictionary, nil)
            guard stored == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(stored)) }
        } else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}
