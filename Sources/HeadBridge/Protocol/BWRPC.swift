import Foundation

struct BWRPCCommand: Hashable, Sendable {
    let namespace: UInt8
    let id: UInt8
    let name: String

    var key: String { String(format: "%02X:%02X", namespace, id) }
}

struct BWRPCMessage: Sendable {
    enum Kind: Sendable { case response, notification }

    let kind: Kind
    let command: BWRPCCommand
    let errorCode: UInt16
    let payload: MessagePackValue?
    let raw: Data

    var succeeded: Bool { errorCode == 0 }
}

enum BWRPCError: Error, LocalizedError {
    case packetTooShort
    case unsupportedType(UInt16)
    case invalidPayloadLength

    var errorDescription: String? {
        switch self {
        case .packetTooShort: "RPC packet is too short"
        case .unsupportedType(let value): String(format: "Unsupported RPC type 0x%04X", value)
        case .invalidPayloadLength: "RPC payload length exceeds packet length"
        }
    }
}

enum BWRPC {
    static let requestUUID = "ada50ce9-67b8-4a97-9d8e-37e1d083156c"
    static let responseUUID = "cb909093-3559-4b0c-9a7f-3f1773122fdc"
    static let notificationUUID = "df55d475-9a32-457a-9e20-38cf14e853fb"

    static func request(_ command: BWRPCCommand, payload: MessagePackValue? = nil) -> Data {
        let payloadData = MessagePack.encode(payload)
        let hasPayload = !payloadData.isEmpty
        let packetSize = hasPayload ? payloadData.count + 6 : 4
        var data = Data([UInt8(packetSize)])
        data.append(contentsOf: hasPayload ? [0x0B, 0x92] : [0x0B, 0x12])
        data.append(command.id)
        data.append(command.namespace)
        if hasPayload {
            data.append(UInt8(payloadData.count & 0xFF))
            data.append(UInt8((payloadData.count >> 8) & 0xFF))
            data.append(payloadData)
        }
        return data
    }

    static func decode(_ data: Data) throws -> BWRPCMessage {
        let bytes = Array(data)
        guard bytes.count >= 4 else { throw BWRPCError.packetTooShort }
        let type = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        let command = BWRPCCommand(
            namespace: bytes[3], id: bytes[2], name: BWRPCatalog.name(namespace: bytes[3], id: bytes[2]))

        let kind: BWRPCMessage.Kind
        let errorCode: UInt16
        let payloadOffset: Int
        let lengthOffset: Int
        switch type {
        case 0x120C, 0x920C:
            kind = .response
            guard bytes.count >= 5 else { throw BWRPCError.packetTooShort }
            errorCode = UInt16(bytes[4]) | (bytes.count > 5 ? UInt16(bytes[5]) << 8 : 0)
            lengthOffset = 6
            payloadOffset = 8
        case 0x120D, 0x920D:
            kind = .notification
            errorCode = 0
            lengthOffset = 4
            payloadOffset = 6
        default:
            throw BWRPCError.unsupportedType(type)
        }

        let hasPayload = type == 0x920C || type == 0x920D
        var payload: MessagePackValue?
        if hasPayload {
            guard bytes.count >= payloadOffset else { throw BWRPCError.packetTooShort }
            let length = Int(bytes[lengthOffset]) | (Int(bytes[lengthOffset + 1]) << 8)
            guard payloadOffset + length <= bytes.count else { throw BWRPCError.invalidPayloadLength }
            payload = try MessagePack.decode(data.subdata(in: payloadOffset..<(payloadOffset + length)))
        }
        return BWRPCMessage(kind: kind, command: command, errorCode: errorCode, payload: payload, raw: data)
    }
}

enum BWRPCatalog {
    // Safe controls exposed by the current Bowers & Wilkins RPC family.
    static let ancGet = command(0x03, 0x01, "ANC mode")
    static let ancSet = command(0x03, 0x02, "Set ANC mode")
    static let eqSet = command(0x04, 0x29, "Set 5-band EQ")
    static let eqGet = command(0x04, 0x2A, "5-band EQ")
    static let eqBypassSet = command(0x04, 0x2B, "Set EQ bypass")
    static let eqBypassGet = command(0x04, 0x2C, "EQ bypass")
    static let wearGet = command(0x0A, 0x01, "Wear sensor")
    static let wearSet = command(0x0A, 0x02, "Set wear sensor")
    static let wearSensitivityGet = command(0x0A, 0x03, "Wear sensitivity")
    static let wearSensitivitySet = command(0x0A, 0x04, "Set wear sensitivity")
    static let sleepGet = command(0x02, 0x06, "Sleep timer")
    static let sleepSet = command(0x02, 0x05, "Set sleep timer")
    static let buttonGet = command(0x08, 0x2B, "Custom button")
    static let buttonSet = command(0x08, 0x2A, "Set custom button")
    static let voiceGet = command(0x04, 0x09, "Voice prompts")
    static let voiceSet = command(0x04, 0x08, "Set voice prompts")
    static let nameGet = command(0x05, 0x01, "Local name")
    static let nameSet = command(0x05, 0x02, "Set local name")
    static let spatialEnabledSet = command(0x04, 0x2D, "Set spatial audio")
    static let spatialEnabledGet = command(0x04, 0x2E, "Spatial audio enabled")
    static let spatialPresetSet = command(0x04, 0x2F, "Set spatial audio preset")
    static let spatialPresetGet = command(0x04, 0x30, "Spatial audio preset")
    static let pairedDeviceGet = command(0x05, 0x04, "Paired device")
    static let pairedDeviceCountGet = command(0x05, 0x0B, "Paired device list size")
    static let batteryPercentageGet = command(0x08, 0x0C, "Battery percentage")
    static let chargingStatusGet = command(0x08, 0x0B, "Charging status")

    static let primaryReads: [BWRPCCommand] = [
        ancGet, eqGet, eqBypassGet, wearGet, wearSensitivityGet, sleepGet,
        buttonGet, voiceGet, nameGet, spatialEnabledGet, spatialPresetGet,
        batteryPercentageGet, chargingStatusGet,
        command(0x04, 0x0C, "Audio source"),
        command(0x05, 0x06, "Audio codec"),
        command(0x04, 0x14, "Sampling rate"),
        command(0x02, 0x01, "Software version"),
        command(0x08, 0x04, "Serial number"),
        command(0x08, 0x02, "MAC address"),
    ]

    // Read-only explorer. Unsupported commands simply return a device error.
    static let explorerReads: [BWRPCCommand] =
        primaryReads + [
            command(0x02, 0x02, "Component version"),
            command(0x02, 0x07, "Device state"),
            command(0x02, 0x0B, "Current mode"),
            pairedDeviceCountGet,
            command(0x05, 0x11, "Pairing mode enabled"),
            command(0x08, 0x06, "Battery info"),
            command(0x08, 0x0A, "Battery temperature"),
            command(0x08, 0x11, "Battery current"),
            command(0x08, 0x12, "Battery voltage"),
            command(0x08, 0x23, "Battery time to empty"),
            command(0x08, 0x24, "Battery time to full"),
            command(0x08, 0x25, "Battery cycles"),
            command(0x08, 0x26, "Battery age"),
            command(0x08, 0x32, "Battery learned reset count"),
        ]

    private static let allKnown: [BWRPCCommand] =
        explorerReads + [
            ancSet, eqSet, eqBypassSet, wearSet, wearSensitivitySet, sleepSet,
            buttonSet, voiceSet, nameSet, spatialEnabledSet, spatialPresetSet,
            command(0x04, 0x16, "Audio info notification"),
            command(0x02, 0x09, "Sleep notification"), pairedDeviceGet,
        ]

    static func name(namespace: UInt8, id: UInt8) -> String {
        allKnown.first { $0.namespace == namespace && $0.id == id }?.name
            ?? String(format: "Unknown %02X:%02X", namespace, id)
    }

    private static func command(_ namespace: UInt8, _ id: UInt8, _ name: String) -> BWRPCCommand {
        BWRPCCommand(namespace: namespace, id: id, name: name)
    }
}
