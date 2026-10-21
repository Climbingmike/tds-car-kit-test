import XCTest
@testable import TDSCarKitCore

final class AccessoryMessagesTests: XCTestCase {
    func testWirelessSessionFieldsPreserveSSID() throws {
        let wifi = try AccessoryMessages.WiFi(ssid: "Test Network", password: "test-passphrase", channel: 44)
        let message = try AccessoryMessages.startSession(address: "10.0.2.126", port: 7000, deviceID: "02:03:04:05:06:07", wifi: wifi)
        let decoded = try IAP2Message.parse(message.encoded())
        let wireless = try IAP2Parameter.parse(XCTUnwrap(decoded.parameters.first { $0.id == 1 }).value)
        XCTAssertEqual(wireless, [
            .init(id: 0, value: Data("Test Network\0".utf8)),
            .init(id: 1, value: Data("test-passphrase\0".utf8)),
            .init(id: 2, value: Data([44])),
            .init(id: 3, value: Data("10.0.2.126\0".utf8)),
            .init(id: 4, value: Data([2]))])
    }
    func testOpenNetworkAndInvalidCredentials() throws {
        let message = try AccessoryMessages.startSession(address: "10.0.2.126", port: 7000, deviceID: "02:03:04:05:06:07",
            wifi: .init(ssid: "Open", password: ""))
        let wireless = try IAP2Parameter.parse(XCTUnwrap(message.parameters.first { $0.id == 1 }).value)
        XCTAssertEqual(wireless.first { $0.id == 4 }?.value, Data([0]))
        XCTAssertThrowsError(try AccessoryMessages.WiFi(ssid: "", password: ""))
        XCTAssertThrowsError(try AccessoryMessages.WiFi(ssid: "Test", password: "short"))
        XCTAssertThrowsError(try AccessoryMessages.WiFi(ssid: String(repeating: "é", count: 17), password: ""))
        XCTAssertThrowsError(try AccessoryMessages.WiFi(ssid: "Test\0bad", password: ""))
        XCTAssertThrowsError(try AccessoryMessages.WiFi(ssid: "Test", password: "", channel: 0))
    }
    func testSessionPortUsesUInt32EncodingAndNestedAddress() throws {
        let message = try AccessoryMessages.startSession(address: "127.0.0.1", port: 51962, deviceID: "02:03:04:05:06:07")
        let decoded = try IAP2Message.parse(message.encoded())
        XCTAssertEqual(decoded.id, 0x4301)
        let port = try XCTUnwrap(decoded.parameters.first { $0.id == 2 })
        XCTAssertEqual(port.value, Data([0, 0, 0xca, 0xfa]))
        let group = try XCTUnwrap(decoded.parameters.first { $0.id == 0 })
        let address = try IAP2Parameter.parse(group.value)
        XCTAssertEqual(address, [.init(id: 0, value: Data("127.0.0.1\0".utf8))])
        XCTAssertNil(decoded.parameters.first { $0.id == 1 }, "Local mode must not supply invented Wi-Fi credentials")
    }
    func testIdentificationTransportIDsAndBluetoothAddress() throws {
        let message = try AccessoryMessages.identification(name: "Test", deviceID: "02:03:04:05:06:07")
        for (groupID, transportID) in [(UInt16(16), UInt8(1)), (17, 2), (24, 3)] {
            let group = try XCTUnwrap(message.parameters.first { $0.id == groupID })
            let values = try IAP2Parameter.parse(group.value)
            XCTAssertEqual(values.first { $0.id == 0 }?.value, Data([0, transportID]))
            if groupID == 17 { XCTAssertEqual(values.first { $0.id == 3 }?.value, Data([2, 3, 4, 5, 6, 7])) }
        }
        XCTAssertThrowsError(try AccessoryMessages.identification(name: "Test", deviceID: "bad"))
    }
}
