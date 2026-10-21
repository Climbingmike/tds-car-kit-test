// SPDX-License-Identifier: GPL-3.0-or-later
// Capability profile adapted from PlayPort AirPlayInfoPlist/AirPlayHid.
import Foundation

enum CarPlayInfo {
    static let displayID = "b7e6c5a0-1111-4000-8000-000000000001"
    static func features(audio: Bool) -> UInt64 { audio ? 0x615653aee2 : 0x615653aee2 & ~UInt64(0x10004540a00) }
    static func build(_ config: ReceiverConfiguration) -> [String: Any] {
        let area: [String: Any] = ["widthPixels": config.width, "heightPixels": config.height, "originXPixels": 0, "originYPixels": 0]
        var view = area; var safe = area; safe["drawUIOutsideSafeArea"] = true; view["safeArea"] = safe
        let display: [String: Any] = ["uuid": displayID, "type": 110, "maxFPS": 30,
            "widthPixels": config.width, "heightPixels": config.height, "widthPhysical": 180,
            "heightPhysical": Int((180.0 * Double(config.height) / Double(config.width)).rounded()),
            "features": 8, "primaryInputDevice": 1, "viewAreas": [view], "initialViewArea": 0]
        let resource: [String: Any] = ["resourceID": 1, "transferType": 1, "transferPriority": 100,
            "takeConstraint": 100, "borrowConstraint": 100, "unborrowConstraint": 100]
        var resources = [resource]
        if config.audioEnabled { var audio = resource; audio["resourceID"] = 2; resources.append(audio) }
        let modes: [String: Any] = ["resources": resources, "appStates": [
            ["appStateID": 2, "state": false], ["appStateID": 1, "speechMode": -1], ["appStateID": 3, "state": false]]]
        let hid: [String: Any] = ["hidProductID": 1, "hidVendorID": 2, "hidCountryCode": 0,
            "uuid": "2a2a2a2a", "name": "TDS Car Kit Touchscreen", "displayUUID": displayID,
            "hidDescriptor": descriptor(width: config.width, height: config.height)]
        var info: [String: Any] = ["sourceVersion": "509.11", "features": NSNumber(value: features(audio: config.audioEnabled)), "statusFlags": 4,
            "model": "TDSCarKit1,1", "manufacturer": "TDS Car Kit", "deviceID": config.deviceID,
            "bluetoothIDs": [config.deviceID], "name": config.name, "rightHandDrive": config.rightHandDrive,
            "keepAliveLowPower": false, "keepAliveSendStatsAsBody": false, "modes": modes,
            "displays": [display], "hidDevices": [hid]]
        if config.audioEnabled {
            // Wireless CarPlay requires a compressed codec for every interactive
            // voice/alternate category, even when only music is currently playing.
            let types: [(Int, String)] = [(100,"compatibility"),(101,"compatibility"),(100,"default"),
                (100,"media"),(100,"alert"),(100,"telephony"),(100,"speechRecognition"),(101,"default")]
            let profiles: [(Int, String, Int, Int)] = [
                (100, "compatibility", 0x8854, 0x54),
                (101, "compatibility", 0x8800, 0),
                (100, "default", 0x30000050, 0x30000050),
                (100, "media", 0x8800, 0),
                (100, "alert", 0x40008800, 0),
                (100, "telephony", 0x70000150, 0x70000150),
                (100, "speechRecognition", 0x20000040, 0x20000040),
                (101, "default", 0x40008800, 0),
                (102, "media", 0xc00000, 0)]
            info["audioFormats"] = profiles.map { type, audioType, output, input -> [String: Any] in
                var entry: [String: Any] = ["type": type, "audioType": audioType, "audioOutputFormats": output]
                if input != 0 { entry["audioInputFormats"] = input }
                return entry
            }
            // A type-only latency entry is the fallback for requests without an audioType.
            info["audioLatencies"] = (types + [(102,"media"),(102,"default")]).map { ["type": $0.0, "audioType": $0.1, "inputLatencyMicros": 0, "outputLatencyMicros": $0.0 == 102 ? 200000 : 50000] as [String: Any] }
                + [100, 101, 102].map { ["type": $0, "inputLatencyMicros": 0, "outputLatencyMicros": $0 == 102 ? 200000 : 50000] as [String: Any] }
        }
        return info
    }
    private static func descriptor(width: Int, height: Int) -> Data {
        let finger: [UInt8] = [0x05,0x0d,0x09,0x22,0xa1,0x02,0x09,0x38,0x75,0x08,0x95,0x01,0x81,0x02,
            0x15,0x00,0x25,0x01,0x09,0x33,0x75,0x01,0x95,0x01,0x81,0x02,0x95,0x07,0x81,0x03,
            0x05,0x01,0x26,UInt8(truncatingIfNeeded: width),UInt8(truncatingIfNeeded: width >> 8),
            0x09,0x30,0x75,0x10,0x95,0x01,0x81,0x02,0x26,UInt8(truncatingIfNeeded: height),UInt8(truncatingIfNeeded: height >> 8),
            0x09,0x31,0x81,0x02,0xc0]
        return Data([0x05,0x0d,0x09,0x04,0xa1,0x01] + finger + finger + [0xc0])
    }
}
