import CoreAudio
import Foundation

/// Audio output selection is independent of the authenticated BLE control link.
enum HatorAudioRoute: Equatable {
    case bluetooth
    case usbDongle
    case none

    static func forDevice(_ device: SystemAudioDevice) -> Self {
        guard BluetoothDeviceNameMatcher.normalized(device.name) == "hatorphoenix2" else {
            return .none
        }
        if device.isBluetooth { return .bluetooth }
        if device.transportType == kAudioDeviceTransportTypeUSB,
            device.uid.lowercased().hasPrefix("appleusbaudioengine:jieli technology:usb composite device:")
        {
            return .usbDongle
        }
        return .none
    }

    static func effectiveCapabilities(_ hardware: HeadphoneCapabilities, route: Self) -> HeadphoneCapabilities {
        guard route != .none else { return [] }
        var result = hardware
        if route == .usbDongle {
            result.remove(.spatialAudio)
        }
        return result
    }
}

struct HatorRCSPFrame: Equatable {
    let isCommand: Bool
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
        [0xFE, 0xDC, 0xBA, 0x00, 0xFF, 0x00, 0x02, 0x00, sequence, 0xEF]
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
                isCommand: true, opcode: bytes[4],
                sequence: bytes[7], status: nil,
                parameters: Array(bytes[8..<(bytes.count - 1)]))
        }
        guard bytes.count >= 10 else { return nil }
        return HatorRCSPFrame(
            isCommand: false, opcode: bytes[4],
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
