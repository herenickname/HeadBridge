import CoreAudio
import Foundation

/// Physical wireless transport reported by the Phoenix 2 vendor RCSP FF/07 field.
/// Readback and physical Mode-button pushes were both verified on firmware V0.0.116.
enum HatorRadioMode: UInt8, CaseIterable, Identifiable {
    case bluetooth = 0
    case dongle = 1

    var id: UInt8 { rawValue }
    var title: String {
        switch self {
        case .bluetooth: "Bluetooth"
        case .dongle: "2.4 GHz dongle"
        }
    }

    /// Only dongle mode requires a separately enumerated USB receiver.
    /// When the headset uses the dongle, macOS often has no Bluetooth
    /// audio endpoint even though switching back over BLE still works.
    func isAvailable(with devices: [SystemAudioDevice]) -> Bool {
        switch self {
        case .bluetooth:
            return true
        case .dongle:
            return devices.contains { HatorAudioRoute.forDevice($0) == .usbDongle }
        }
    }

    var audioRoute: HatorAudioRoute {
        switch self {
        case .bluetooth: .bluetooth
        case .dongle: .usbDongle
        }
    }
}

/// Audio output selection is independent of the authenticated BLE control link.
enum HatorAudioRoute: Equatable {
    case bluetooth
    case usbDongle
    case wiredUSB
    case none

    var isWireless: Bool { self == .bluetooth || self == .usbDongle }

    var title: String {
        switch self {
        case .bluetooth: "Bluetooth"
        case .usbDongle: "2.4 GHz dongle"
        case .wiredUSB: "Wired USB-C"
        case .none: "Unavailable"
        }
    }

    static func forDevice(_ device: SystemAudioDevice) -> Self {
        guard BluetoothDeviceNameMatcher.normalized(device.name) == "hatorphoenix2" else {
            return .none
        }
        if device.isBluetooth { return .bluetooth }
        if device.transportType == kAudioDeviceTransportTypeUSB,
            HatorUSBDeviceInventory.serial(fromCoreAudioUID: device.uid) != nil
        {
            // Physical unplug/replug on Phoenix 2 confirmed the wired
            // headset as USB device class EF and the receiver as class 00.
            // An unknown descriptor must never be treated as the dongle.
            switch device.usbDeviceClass {
            case 0x00: return .usbDongle
            case 0xEF: return .wiredUSB
            default: return .none
            }
        }
        return .none
    }

    static func effectiveCapabilities(_ hardware: HeadphoneCapabilities, route: Self) -> HeadphoneCapabilities {
        guard route != .none, route != .wiredUSB else { return [] }
        var result = hardware
        if route == .usbDongle {
            result.remove(.spatialAudio)
        }
        return result
    }
}

/// Pure policy for following HATOR output or preserving another Mac output.
/// All decisions use the currently enumerated Core Audio devices, never IDs
/// cached across a wireless re-enumeration.
enum HatorAudioHandoffPolicy {
    static func preferredOutput(
        startedWithHator: Bool,
        target: HatorRadioMode,
        originalOutputUID: String?,
        devices: [SystemAudioDevice],
        currentID: AudioDeviceID?
    ) -> SystemAudioDevice? {
        let current = devices.first { $0.id == currentID }
        if startedWithHator {
            guard
                let targetDevice = devices.first(where: {
                    HatorAudioRoute.forDevice($0) == target.audioRoute
                }), targetDevice.id != currentID
            else { return nil }
            return targetDevice
        }
        guard let current,
            HatorAudioRoute.forDevice(current) != .none,
            let original = devices.first(where: { $0.uid == originalOutputUID }),
            original.id != current.id
        else { return nil }
        return original
    }
}

struct HatorRCSPFrame: Equatable {
    let isCommand: Bool
    let requiresAcknowledgement: Bool
    let opcode: UInt8
    let sequence: UInt8
    let status: UInt8?
    let parameters: [UInt8]
}

/// Framing and field parsing only. Transport and authentication are separate.
enum HatorRCSP {
    static let maxFrameSize = 512

    static func command(opcode: UInt8, sequence: UInt8, parameters: [UInt8]) -> [UInt8] {
        precondition(parameters.count < maxFrameSize - 9)
        let length = parameters.count + 1
        return [
            0xFE, 0xDC, 0xBA, 0xC0, opcode,
            UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF), sequence,
        ]
            + parameters + [0xEF]
    }

    static func targetInfo(sequence: UInt8) -> [UInt8] {
        command(opcode: 0x03, sequence: sequence, parameters: [0xFF, 0xFF, 0xFF, 0xFF, 0x01])
    }

    static func systemInfo(sequence: UInt8) -> [UInt8] {
        command(opcode: 0x07, sequence: sequence, parameters: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
    }

    static func vendorGet(_ code: UInt8, sequence: UInt8) -> [UInt8] {
        command(opcode: 0xFF, sequence: sequence, parameters: [code, 0xFF])
    }

    static func vendorSet(_ code: UInt8, value: UInt8, sequence: UInt8) -> [UInt8] {
        command(opcode: 0xFF, sequence: sequence, parameters: [code, value])
    }

    static func acknowledgeVendor(sequence: UInt8) -> [UInt8] {
        acknowledge(opcode: 0xFF, sequence: sequence)
    }

    static func acknowledge(opcode: UInt8, sequence: UInt8) -> [UInt8] {
        [0xFE, 0xDC, 0xBA, 0x00, opcode, 0x00, 0x02, 0x00, sequence, 0xEF]
    }

    static func decode(_ bytes: [UInt8]) -> HatorRCSPFrame? {
        guard bytes.count >= 9, bytes.count <= maxFrameSize,
            bytes.starts(with: [0xFE, 0xDC, 0xBA]), bytes.last == 0xEF,
            (Int(bytes[5]) << 8) + Int(bytes[6]) + 8 == bytes.count
        else {
            return nil
        }
        let isCommand = bytes[3] & 0x80 != 0
        if isCommand {
            return HatorRCSPFrame(
                isCommand: true, requiresAcknowledgement: bytes[3] & 0x40 != 0, opcode: bytes[4],
                sequence: bytes[7], status: nil,
                parameters: Array(bytes[8..<(bytes.count - 1)]))
        }
        guard bytes.count >= 10 else { return nil }
        return HatorRCSPFrame(
            isCommand: false, requiresAcknowledgement: false, opcode: bytes[4],
            sequence: bytes[8], status: bytes[7],
            parameters: Array(bytes[9..<(bytes.count - 1)]))
    }

    /// JieLi SYS_INFO_GET function FF: length includes the attribute byte.
    static func systemFields(_ payload: [UInt8]) -> [UInt8: [UInt8]]? {
        guard payload.first == 0xFF else { return nil }
        var result: [UInt8: [UInt8]] = [:]
        var index = 1
        while index < payload.count {
            let length = Int(payload[index])
            guard length >= 1, index + length < payload.count else { return nil }
            result[payload[index + 1]] = Array(payload[(index + 2)..<(index + length + 1)])
            index += length + 1
        }
        return result
    }
}

/// Bounded incremental framing: no allocations from unchecked peer lengths.
struct HatorRCSPParser {
    private var buffer: [UInt8] = []

    mutating func reset() { buffer.removeAll() }

    mutating func append(_ input: [UInt8]) -> [HatorRCSPFrame] {
        guard input.count <= 1024 else {
            reset()
            return []
        }
        buffer.append(contentsOf: input)
        if buffer.count > 2048 {
            reset()
            return []
        }
        var frames: [HatorRCSPFrame] = []
        while buffer.count >= 9 {
            guard buffer.starts(with: [0xFE, 0xDC, 0xBA]) else {
                buffer.removeFirst()
                continue
            }
            let size = (Int(buffer[5]) << 8) + Int(buffer[6]) + 8
            guard size >= 9, size <= HatorRCSP.maxFrameSize else {
                buffer.removeFirst()
                continue
            }
            guard buffer.count >= size else { break }
            if let frame = HatorRCSP.decode(Array(buffer.prefix(size))) {
                frames.append(frame)
                buffer.removeFirst(size)
            } else {
                buffer.removeFirst()
            }
        }
        return frames
    }
}

/// Preset IDs are sourced from JieLi SYS_INFO_GET; titles correspond to the
/// nine positions shown in HATOR SyncHUB's EQ Settings grid.
struct HatorEqualizerPreset: Equatable, Identifiable {
    let id: UInt8
    let gains: [Int]

    var title: String {
        switch id {
        case 0: return "Normal"
        case 1: return "Shooters"
        case 2: return "Rock"
        case 3: return "Movie"
        case 4: return "Action"
        case 5: return "Hip-Hop/Rap"
        case 6: return "EDM"
        case 7: return "Sport"
        case 8: return "Custom"
        default: return "Preset \(id)"
        }
    }
}

struct HatorEqualizerState: Equatable {
    let mode: UInt8
    let gains: [Int]
}

/// Audio DSP commands use standard SYS_INFO_SET opcode 08. The 10 data
/// bytes after the preset selector are present even for a preset change.
enum HatorDSP {
    static let frequencies = [31, 71, 145, 400, 800, 1400, 2100, 2900, 4800, 10000]
    static let editableRange = -12...12

    static func eqState(_ bytes: [UInt8]?) -> HatorEqualizerState? {
        guard let bytes, bytes.count == 11, bytes[0] <= 8 else { return nil }
        return HatorEqualizerState(mode: bytes[0], gains: bytes.dropFirst().map { Int(Int8(bitPattern: $0)) })
    }

    static func eqPresets(_ bytes: [UInt8]?) -> [HatorEqualizerPreset] {
        guard let bytes, bytes.count == 120 else { return [] }
        let headerSize = 21
        let presetSize = 11
        let raw = (0..<9).map { i -> HatorEqualizerPreset in
            let offset = headerSize + i * presetSize
            return HatorEqualizerPreset(
                id: bytes[offset],
                gains: bytes[(offset + 1)..<(offset + presetSize)].map { Int(Int8(bitPattern: $0)) }
            )
        }
        guard raw.map(\.id) == Array(UInt8(0)...UInt8(8)) else { return [] }
        return raw
    }

    static func availableANC(_ bytes: [UInt8]?) -> [HeadphoneNoiseMode] {
        guard let bytes, let count = bytes.first.map(Int.init), count > 0,
            count <= 8, bytes.count == 1 + count * 9
        else { return [] }
        let modes = (0..<count).compactMap { index -> HeadphoneNoiseMode? in
            switch bytes[1 + index * 9] {
            case 0: return .off
            case 1: return .noiseCancellation
            case 2: return .ambient
            default: return nil
            }
        }
        guard modes.count == count, Set(modes.map(\.rawValue)).count == count else { return [] }
        return modes
    }

    static func noiseControl(_ mode: HeadphoneNoiseMode, sequence: UInt8) -> [UInt8]? {
        guard [.off, .noiseCancellation, .ambient].contains(mode) else { return nil }
        let parameters: [UInt8] = [
            0xFF, 0x0A, 0x0D, UInt8(mode.rawValue),
            0x40, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00,
        ]
        return HatorRCSP.command(opcode: 0x08, sequence: sequence, parameters: parameters)
    }

    static func equalizerPreset(_ preset: UInt8, sequence: UInt8) -> [UInt8]? {
        guard preset <= 8 else { return nil }
        return HatorRCSP.command(
            opcode: 0x08, sequence: sequence,
            parameters: [0xFF, 0x02, 0x04, preset] + Array(repeating: 0, count: 10))
    }

    static func customEqualizer(_ gains: [Int], sequence: UInt8) -> [UInt8]? {
        guard gains.count == 10, gains.allSatisfy(editableRange.contains) else { return nil }
        return HatorRCSP.command(
            opcode: 0x08, sequence: sequence,
            parameters: [0xFF, 0x0C, 0x04, 0x08] + gains.map { UInt8(bitPattern: Int8($0)) })
    }
}
