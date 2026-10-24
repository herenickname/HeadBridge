import Foundation

/// Command ids observed on OPPO/OnePlus/realme earbuds that expose the
/// `0000079A-D102-11E1-9B23-00025B00A5A5` RFCOMM service.
///
/// The wire facts here were verified against an OPPO Enco Air5s
/// (product id `0x06C810`) on 2026-10-24: battery, firmware and the
/// off/noise-cancellation/ambient transitions all round-trip on hardware.
enum OppoCommand: UInt16 {
    case productID = 0x0103
    case firmware = 0x0105
    case battery = 0x0106
    case wearing = 0x0109
    case noiseControl = 0x010C
    case setNoiseControl = 0x0404
    case event = 0x0204
    case gestures = 0x0108
    case features = 0x010D
    case equalizer = 0x010F
    case dualDevices = 0x0112
    case codec = 0x0114
    case customEqualizer = 0x0122
    case codecList = 0x0123
    case spatialType = 0x012A
    case gameSound = 0x012B
    case alertVolume = 0x0130
    case preferredDevice = 0x0132
    case setFeature = 0x0403
    case findEarbuds = 0x0400
    case setGestures = 0x0401
    case selectEqualizer = 0x0406
    case writeEqualizer = 0x0418
    case setCodec = 0x041A
    case setSpatialType = 0x0422
    case setGameSound = 0x0423
    case setAlertVolume = 0x0427
    case dualDeviceAction = 0x0429
}

struct OppoMessage: Equatable {
    let command: UInt16
    let sequence: UInt8
    let payload: [UInt8]
}

enum OppoWire {
    /// `AA <LEB128 total length> 00 00 <cmd LE> <seq> <payload length LE> <payload>`.
    ///
    /// The length counts every byte after the length field, including the two
    /// reserved zero bytes, so an empty payload still produces a length of 7.
    static func encode(command: UInt16, sequence: UInt8, payload: [UInt8]) -> Data {
        let bodyLength = 7 + payload.count
        var bytes: [UInt8] = [0xAA]
        bytes.append(contentsOf: encodeLEB128(bodyLength))
        bytes.append(contentsOf: [0x00, 0x00])
        bytes.append(UInt8(command & 0xFF))
        bytes.append(UInt8(command >> 8))
        bytes.append(sequence)
        bytes.append(UInt8(payload.count & 0xFF))
        bytes.append(UInt8((payload.count >> 8) & 0xFF))
        bytes.append(contentsOf: payload)
        return Data(bytes)
    }

    /// Commands that take a device address write the six bytes in the reverse
    /// order of the human-readable list entry.
    static func macBytes(from address: String) -> [UInt8]? {
        let parts = address.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        guard parts.count == 6 else { return nil }
        return parts.reversed()
    }

    static func encodeLEB128(_ value: Int) -> [UInt8] {
        precondition(value >= 0)
        var remaining = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 {
                byte |= 0x80
            }
            bytes.append(byte)
        } while remaining != 0
        return bytes
    }
}

/// Bounded frame reassembler. Notifications may be split across RFCOMM reads
/// and may contain more than one frame; malformed length prefixes are dropped
/// instead of allowing the buffer to grow without limit.
struct OppoFrameParser {
    private static let maximumFrameLength = 2_048
    private static let maximumBufferLength = 4_096
    private var buffer: [UInt8] = []

    mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
    }

    mutating func append(_ data: Data) -> [OppoMessage] {
        buffer.append(contentsOf: data)
        var messages: [OppoMessage] = []

        while let preamble = buffer.firstIndex(of: 0xAA) {
            if preamble > 0 {
                buffer.removeFirst(preamble)
            }
            guard buffer.count >= 3 else { break }

            var length = 0
            var shift = 0
            var cursor = 1
            var lengthComplete = false
            while cursor < buffer.count {
                let byte = buffer[cursor]
                length |= Int(byte & 0x7F) << shift
                cursor += 1
                if byte & 0x80 == 0 {
                    lengthComplete = true
                    break
                }
                shift += 7
                if shift > 21 {
                    break
                }
            }

            guard lengthComplete else {
                // A frame longer than the supported prefix is not recoverable.
                if buffer.count > 4 {
                    buffer.removeFirst()
                    continue
                }
                break
            }

            guard length >= 7, length <= Self.maximumFrameLength else {
                buffer.removeFirst()
                continue
            }

            let total = cursor + length
            guard buffer.count >= total else { break }

            // The two reserved bytes are always zero for a whole message. If
            // they are not, this is a stray 0xAA in another frame: resync.
            guard buffer[cursor] == 0x00, buffer[cursor + 1] == 0x00 else {
                buffer.removeFirst()
                continue
            }

            let frame = Array(buffer[0..<total])
            buffer.removeFirst(total)
            if let message = Self.parse(frame) {
                messages.append(message)
            }
        }

        if buffer.count > Self.maximumBufferLength {
            buffer.removeAll(keepingCapacity: true)
        }
        return messages
    }

    static func parse(_ frame: [UInt8]) -> OppoMessage? {
        guard frame.count >= 9, frame[0] == 0xAA else { return nil }

        var cursor = 1
        var shift = 0
        var length = 0
        var lengthComplete = false
        while cursor < frame.count {
            let byte = frame[cursor]
            length |= Int(byte & 0x7F) << shift
            cursor += 1
            if byte & 0x80 == 0 {
                lengthComplete = true
                break
            }
            shift += 7
            if shift > 21 { return nil }
        }
        guard lengthComplete, length >= 7, length <= maximumFrameLength else { return nil }
        guard cursor + length <= frame.count else { return nil }

        let command = UInt16(frame[cursor + 2]) | (UInt16(frame[cursor + 3]) << 8)
        let sequence = frame[cursor + 4]
        let payloadLength = Int(frame[cursor + 5]) | (Int(frame[cursor + 6]) << 8)
        guard payloadLength <= maximumFrameLength else { return nil }
        let payloadStart = cursor + 7
        guard payloadStart + payloadLength <= frame.count else { return nil }

        return OppoMessage(
            command: command,
            sequence: sequence,
            payload: Array(frame[payloadStart..<(payloadStart + payloadLength)])
        )
    }
}

struct OppoBattery: Equatable {
    var left: Int?
    var right: Int?
    var caseLevel: Int?
    var isCharging = false

    /// HeadBridge exposes one battery percentage per device. Report the lowest
    /// earbud so the menu never claims more charge than either bud has.
    var lowestEarbudLevel: Int? {
        switch (left, right) {
        case let (left?, right?): min(left, right)
        case let (left?, nil): left
        case let (nil, right?): right
        case (nil, nil): caseLevel
        }
    }
}

enum OppoBatteryCodec {
    /// Payload begins with the status byte, then `<count>` and `(id, level)`
    /// pairs. Id 1 is the left bud, 2 the right bud, 3 the charging case.
    static func decode(_ payload: [UInt8]) -> OppoBattery? {
        guard payload.count >= 2, payload[0] == 0x00 else { return nil }
        let count = Int(payload[1])
        guard count > 0, count <= 8 else { return nil }

        var reading = OppoBattery()
        var cursor = 2
        for _ in 0..<count {
            guard cursor + 1 < payload.count else { break }
            let identifier = payload[cursor]
            let rawLevel = payload[cursor + 1]
            cursor += 2
            guard identifier != 0xFF else { continue }

            let level = Int(rawLevel & 0x7F)
            if rawLevel & 0x80 != 0 {
                reading.isCharging = true
            }

            switch identifier {
            case 1: reading.left = level
            case 2: reading.right = level
            case 3: reading.caseLevel = level
            default: break
            }
        }

        guard reading.left != nil || reading.right != nil || reading.caseLevel != nil else {
            return nil
        }
        return reading
    }
}

/// Ringing safety is based on an explicit, recent both-out-of-ear report.
/// A cached complete report is not enough if polling stops answering.
enum OppoRingSafety {
    static let maxWearingAge: TimeInterval = 3

    static func canRing(
        wearing: OppoWearingState?,
        updatedAt: Date?,
        now: Date = Date()
    ) -> Bool {
        guard let wearing, let updatedAt, wearing.bothOutOfEar else { return false }
        let age = now.timeIntervalSince(updatedAt)
        return age >= 0 && age <= maxWearingAge
    }
}

enum OppoNoiseLevel: Int, CaseIterable, Identifiable {
    case light = 0x40
    case deep = 0x10
    case smart = 0x80

    var id: Int { rawValue }
}

enum OppoNoiseCodec {
    /// Reply to `0x010C 01 01`: `00 01 01 <mode LE>`.
    static func decodeReport(_ payload: [UInt8]) -> HeadphoneNoiseMode? {
        reportRawValue(payload).flatMap(mode(forRawValue:))
    }

    static func reportRawValue(_ payload: [UInt8]) -> UInt32? {
        guard payload.count >= 5, payload[0] == 0x00, payload[1] == 0x01, payload[2] == 0x01
        else { return nil }
        return littleEndianValue(payload, from: 3)
    }

    static func level(forRawValue raw: UInt32) -> OppoNoiseLevel? {
        OppoNoiseLevel(rawValue: Int(raw))
    }

    /// `0x010C 02 01` → `00 02 01 <mask LE>`; modes the touch-and-hold cycles.
    static func decodeHoldCycle(_ payload: [UInt8]) -> UInt16? {
        guard payload.count >= 5, payload[0] == 0x00, payload[1] == 0x02, payload[2] == 0x01
        else { return nil }
        return UInt16(payload[3]) | (UInt16(payload[4]) << 8)
    }

    static func encodeHoldCycle(_ mask: UInt16, sequence: UInt8) -> Data {
        OppoWire.encode(
            command: OppoCommand.setNoiseControl.rawValue,
            sequence: sequence,
            payload: [0x02, 0x01, UInt8(mask & 0xFF)]
        )
    }

    /// `0x010C 04 01` → `00 04 01 <mask LE>`; Smart's chosen level.
    static func decodeSmartLevel(_ payload: [UInt8]) -> OppoNoiseLevel? {
        guard payload.count >= 5, payload[0] == 0x00, payload[1] == 0x04, payload[2] == 0x01
        else { return nil }
        return littleEndianValue(payload, from: 3).flatMap(level(forRawValue:))
    }

    /// Unsolicited push `02 04` event code `03`: `01 01 <mode LE>`.
    static func decodeEvent(_ payload: [UInt8]) -> HeadphoneNoiseMode? {
        guard payload.count >= 4, payload[0] == 0x01, payload[1] == 0x01 else { return nil }
        return littleEndianValue(payload, from: 2).flatMap(mode(forRawValue:))
    }

    /// The mode is 1-4 bytes little-endian in replies and pushes.
    private static func littleEndianValue(_ payload: [UInt8], from index: Int) -> UInt32? {
        let available = min(4, payload.count - index)
        guard available > 0 else { return nil }
        var value: UInt32 = 0
        for offset in 0..<available {
            value |= UInt32(payload[index + offset]) << (8 * offset)
        }
        return value
    }

    /// Reports use a mask that is not the same table as the write bits. The
    /// four ANC levels all belong to the single noise-cancellation control
    /// HeadBridge exposes.
    static func mode(forRawValue raw: UInt32) -> HeadphoneNoiseMode? {
        switch raw {
        case 0x0008:
            .off
        case 0x0002, 0x0010, 0x0020, 0x0040, 0x0080:
            .noiseCancellation
        case 0x0100, 0x0200:
            .ambient
        default:
            nil
        }
    }

    static func encodeSetLevel(_ level: OppoNoiseLevel, sequence: UInt8) -> Data {
        OppoWire.encode(
            command: OppoCommand.setNoiseControl.rawValue,
            sequence: sequence,
            payload: [0x01, 0x01, UInt8(level.rawValue)]
        )
    }

    /// `0x0404 01 01 <mask LE>`; the mask is one bit for the model's slot.
    static func encodeSet(mode: HeadphoneNoiseMode, profile: OppoModelProfile, sequence: UInt8) -> Data? {
        guard let bit = profile.noiseBits[mode] else { return nil }
        let byteCount = Int(bit) / 8 + 1
        var mask = [UInt8](repeating: 0, count: byteCount)
        mask[Int(bit) / 8] = 1 << (bit % 8)
        return OppoWire.encode(
            command: OppoCommand.setNoiseControl.rawValue,
            sequence: sequence,
            payload: [0x01, 0x01] + mask
        )
    }
}

/// Model-specific write slots. Only models whose table has been verified on
/// hardware belong here: an incorrect slot changes the wrong noise mode.
struct OppoModelProfile {
    let productID: UInt32
    let displayName: String
    let noiseBits: [HeadphoneNoiseMode: UInt8]
    let featureQuery: [UInt8]
    let builtInEQPresets: [OppoBuiltInEQPreset]

    static let knownProfiles: [OppoModelProfile] = [
        OppoModelProfile(
            productID: 0x06C810,
            displayName: "OPPO Enco Air5s",
            // Verified on hardware: bit 0 = off, 1 = ANC, 2 = ambient.
            noiseBits: [.off: 0, .noiseCancellation: 1, .ambient: 2],
            // Ids the firmware answered on 2026-10-24.
            featureQuery: [0x05, 0x04, 0x11, 0x18, 0x06, 0x1B, 0x1D, 0x1E, 0x27, 0x28, 0x37],
            builtInEQPresets: [
                OppoBuiltInEQPreset(id: 0, name: "Ultimate"),
                OppoBuiltInEQPreset(id: 1, name: "Thundering Bass"),
                OppoBuiltInEQPreset(id: 2, name: "Pure Vocals"),
            ]
        )
    ]

    static func profile(for productID: UInt32) -> OppoModelProfile? {
        knownProfiles.first { $0.productID == productID }
    }

    static func productID(from payload: [UInt8]) -> UInt32? {
        guard payload.count >= 4, payload[0] == 0x00 else { return nil }
        return UInt32(payload[1]) | (UInt32(payload[2]) << 8) | (UInt32(payload[3]) << 16)
    }
}

enum OppoPushEvent: Equatable {
    case battery(OppoBattery)
    case noiseMode(HeadphoneNoiseMode)
}

enum OppoEventCodec {
    /// Command `0x0204` is a multiplexed event channel; payload byte 0 selects
    /// the event. Codes 2 (wearing), 6 (multipoint list) and others are ignored.
    static func decode(_ message: OppoMessage) -> OppoPushEvent? {
        guard message.command == OppoCommand.event.rawValue, let code = message.payload.first else {
            return nil
        }
        let body = Array(message.payload.dropFirst())
        switch code {
        case 0x01:
            return OppoBatteryCodec.decode(body).map(OppoPushEvent.battery)
        case 0x03:
            return OppoNoiseCodec.decodeEvent(body).map(OppoPushEvent.noiseMode)
        default:
            return nil
        }
    }
}

// MARK: - Extended status used by the OPPO settings screen

struct OppoBuiltInEQPreset: Identifiable, Equatable {
    let id: UInt8
    let name: String
}

struct OppoEQBand: Equatable {
    let frequency: Int
    let gain: Int
}

struct OppoEQPreset: Identifiable, Equatable {
    let id: UInt8
    let name: String
    let isSelected: Bool
    let bands: [OppoEQBand]
}

struct OppoGameSoundState: Equatable {
    let selected: Int
    let options: [Int]
}

struct OppoWearingState: Equatable {
    let left: UInt8?
    let right: UInt8?
    let caseStatus: UInt8?

    var bothBudsReported: Bool { left != nil && right != nil }
    var bothOutOfEar: Bool {
        guard let left, let right else { return false }
        return left & 0x02 == 0 && right & 0x02 == 0
    }

    var leftInEar: Bool { left.map { $0 & 0x02 != 0 } ?? false }
    var rightInEar: Bool { right.map { $0 & 0x02 != 0 } ?? false }
    var leftInCase: Bool { left.map { $0 & 0x01 == 0 } ?? false }
    var rightInCase: Bool { right.map { $0 & 0x01 == 0 } ?? false }
    var leftOutOfCase: Bool { left.map { $0 & 0x01 != 0 } ?? false }
    var rightOutOfCase: Bool { right.map { $0 & 0x01 != 0 } ?? false }
    var leftLidOpen: Bool { left.map { $0 & 0x04 != 0 } ?? false }
    var rightLidOpen: Bool { right.map { $0 & 0x04 != 0 } ?? false }
    var leftFlag: Bool { left.map { $0 & 0x08 != 0 } ?? false }
    var rightFlag: Bool { right.map { $0 & 0x08 != 0 } ?? false }
    var lidOpen: Bool {
        [left, right, caseStatus].compactMap { $0 }.contains { $0 & 0x04 != 0 }
    }

    static func bitSummary(_ status: UInt8?) -> String {
        guard let status else { return "No data" }
        return String(
            format: "0x%02X · outOfCase %@ · inEar %@ · lidOpen %@ · flag %@",
            status,
            status & 0x01 != 0 ? "true" : "false",
            status & 0x02 != 0 ? "true" : "false",
            status & 0x04 != 0 ? "true" : "false",
            status & 0x08 != 0 ? "true" : "false"
        )
    }

    static func budLabel(status: UInt8?, inEar: Bool, inCase: Bool) -> String {
        guard status != nil else { return "Unknown" }
        if inEar { return "In ear" }
        if inCase { return "In case" }
        return "Out of ear"
    }
}

struct OppoDualDevice: Identifiable, Equatable {
    let mac: String
    let name: String
    let isConnected: Bool
    let flags: UInt8

    var id: String { mac }
    var isThisHost: Bool { flags & 0x01 != 0 }
    var isMainAudio: Bool { flags & 0x02 != 0 }
}

struct OppoGestureBinding: Identifiable, Equatable {
    let device: UInt8
    let button: UInt8
    let action: UInt8
    let function: UInt8

    var id: String { "\(device)-\(button)-\(action)" }

    var sideLabel: String {
        switch device {
        case 1: "Left"
        case 2: "Right"
        case 4: "Both"
        default: "Side \(device)"
        }
    }

    var groupLabel: String {
        button == 6 ? "Call" : "Tap"
    }

    var actionLabel: String {
        switch action {
        case 1: "Single"
        case 2: "Double"
        case 3: "Triple"
        case 4: "Touch and hold"
        case 5: "Slide"
        case 6: "Long hold"
        default: "Action \(action)"
        }
    }

    var functionLabel: String {
        switch function {
        case 0x00: "None"
        case 0x01: "Play / pause"
        case 0x03: "Voice assistant"
        case 0x05: "Previous track"
        case 0x06: "Next track"
        case 0x07: "Volume"
        case 0x08: "Noise control cycle"
        case 0x09: "Favourite music"
        case 0x0A: "Switch track"
        case 0x0B: "Volume up"
        case 0x0C: "Volume down"
        case 0x0D: "Switch devices"
        case 0x11: "Game mode"
        case 0x12: "Zen mode"
        case 0x16: "Collect music"
        case 0x1C: "Decline call"
        case 0x1D: "Answer / end call"
        default: String(format: "Function %02X", function)
        }
    }
}

enum OppoStatusCodec {
    static func littleEndian16(_ bytes: [UInt8], at index: Int) -> Int? {
        guard index + 1 < bytes.count else { return nil }
        return Int(bytes[index]) | (Int(bytes[index + 1]) << 8)
    }

    static func firmware(_ payload: [UInt8]) -> String? {
        guard payload.count >= 4, payload[0] == 0x00 else { return nil }
        let textBytes = payload.dropFirst(2).prefix { $0 != 0x00 }
        guard let text = String(bytes: textBytes, encoding: .utf8) else { return nil }
        let parts = text.split(separator: ",").map(String.init)
        guard parts.count >= 3 else { return text.isEmpty ? nil : text }

        var versions = [String?](repeating: nil, count: 3)
        var index = 0
        while index + 2 < parts.count {
            let deviceType = Int(parts[index])
            let versionType = Int(parts[index + 1])
            let version = parts[index + 2]
            if versionType == 2, let deviceType, (1...3).contains(deviceType) {
                versions[deviceType - 1] = version
            }
            index += 3
        }
        let values = versions.compactMap { $0 }
        return values.isEmpty ? nil : values.joined(separator: ".")
    }

    static func featureSwitches(_ payload: [UInt8]) -> [UInt8: UInt8]? {
        guard payload.count >= 2, payload[0] == 0x00 else { return nil }
        let count = Int(payload[1])
        guard count > 0, count <= 32, payload.count >= 2 + count * 2 else { return nil }

        var values: [UInt8: UInt8] = [:]
        var index = 2
        for _ in 0..<count {
            values[payload[index]] = payload[index + 1]
            index += 2
        }
        return values
    }

    static func currentEQ(_ payload: [UInt8]) -> UInt8? {
        guard payload.count >= 2, payload[0] == 0x00 else { return nil }
        return payload[1]
    }

    static func eqPresets(_ payload: [UInt8]) -> [OppoEQPreset]? {
        guard payload.count >= 2, payload[0] == 0x00 else { return nil }
        let count = Int(payload[1])
        guard count <= 8 else { return nil }

        var presets: [OppoEQPreset] = []
        var index = 2
        for _ in 0..<count {
            guard index + 6 <= payload.count else { return nil }
            let selected = payload[index] == 0x01
            // payload[index + 1 ... index + 2] is the gain range (-6...+6).
            let identifier = payload[index + 3]
            let nameLength = Int(payload[index + 4])
            guard index + 5 + nameLength + 1 <= payload.count else { return nil }
            let nameStart = index + 5
            let nameBytes = payload[nameStart..<(nameStart + nameLength)]
            let name = String(bytes: nameBytes, encoding: .utf8) ?? "Preset \(identifier)"
            let bandCount = Int(payload[nameStart + nameLength])
            guard bandCount <= 16 else { return nil }
            let bandsStart = nameStart + nameLength + 1
            guard bandsStart + bandCount * 3 <= payload.count else { return nil }

            var bands: [OppoEQBand] = []
            for band in 0..<bandCount {
                let offset = bandsStart + band * 3
                let frequency = Int(payload[offset]) | (Int(payload[offset + 1]) << 8)
                let gain = Int(Int8(bitPattern: payload[offset + 2]))
                bands.append(OppoEQBand(frequency: frequency, gain: gain))
            }
            presets.append(OppoEQPreset(id: identifier, name: name, isSelected: selected, bands: bands))
            index = bandsStart + bandCount * 3
        }
        return presets
    }

    static func gameSound(_ payload: [UInt8]) -> OppoGameSoundState? {
        guard payload.count >= 3, payload[0] == 0x00 else { return nil }
        let selected = Int(payload[1])
        let count = Int(payload[2])
        guard count <= 8, payload.count >= 3 + count else { return nil }
        return OppoGameSoundState(selected: selected, options: payload[3..<(3 + count)].map(Int.init))
    }

    static func spatialType(_ payload: [UInt8]) -> Int? {
        guard payload.count >= 2, payload[0] == 0x00 else { return nil }
        return Int(payload[1])
    }

    /// `00 03 0C <12 values> <4-byte id> <name>`; status `01` means no record.
    static func codec(_ payload: [UInt8]) -> Int? {
        guard payload.count >= 2, payload[0] == 0x00 else { return nil }
        return Int(payload[1])
    }

    /// `0x0123` returns a little-endian mask; bit `k` selects codec `k + 1`.
    static func codecMask(_ payload: [UInt8]) -> [Int]? {
        guard payload.count >= 3, payload[0] == 0x00 else { return nil }
        let mask = UInt16(payload[1]) | (UInt16(payload[2]) << 8)
        guard mask != 0 else { return [] }
        var codecs: [Int] = []
        for bit in 0..<16 where mask & (1 << bit) != 0 {
            let codec = bit + 1
            if (1...8).contains(codec), !codecs.contains(codec) {
                codecs.append(codec)
            }
        }
        return codecs
    }

    static func alertVolume(_ payload: [UInt8]) -> Int? {
        guard payload.count >= 2, payload[0] == 0x00 else { return nil }
        return Int(payload[1])
    }

    static func wearing(_ payload: [UInt8]) -> OppoWearingState? {
        guard payload.count >= 2, payload[0] == 0x00 else { return nil }
        let count = Int(payload[1])
        guard count <= 8, payload.count >= 2 + count * 2 else { return nil }

        var left: UInt8?
        var right: UInt8?
        var caseStatus: UInt8?
        var index = 2
        for _ in 0..<count {
            let identifier = payload[index]
            let status = payload[index + 1]
            switch identifier {
            case 1: left = status
            case 2: right = status
            case 3: caseStatus = status
            default: break
            }
            index += 2
        }
        // A partial report is not enough to decide that a bud is out of ear.
        guard let left, let right else { return nil }
        return OppoWearingState(left: left, right: right, caseStatus: caseStatus)
    }

    /// Entry: `<MAC, 6 bytes reversed> <len> <state> <flags> <nameLen> <name>`.
    static func dualDevices(_ payload: [UInt8]) -> [OppoDualDevice]? {
        guard payload.count >= 2, payload[0] == 0x00 else { return nil }
        let count = Int(payload[1])
        guard count <= 8 else { return nil }

        var devices: [OppoDualDevice] = []
        var index = 2
        for _ in 0..<count {
            guard index + 6 <= payload.count else { return nil }
            let macBytes = Array(payload[index..<(index + 6)]).reversed()
            let mac = macBytes.map { String(format: "%02X", $0) }.joined(separator: ":")
            let cursor = index + 6
            guard cursor + 4 <= payload.count else { return nil }
            let state = payload[cursor + 1]
            let flags = payload[cursor + 2]
            let nameLength = Int(payload[cursor + 3])
            guard cursor + 4 + nameLength <= payload.count else { return nil }
            let nameBytes = payload[(cursor + 4)..<(cursor + 4 + nameLength)]
            let name = String(bytes: nameBytes, encoding: .utf8) ?? "Unknown device"
            devices.append(
                OppoDualDevice(mac: mac, name: name, isConnected: state == 0x02, flags: flags)
            )
            index = cursor + 4 + nameLength
        }
        return devices
    }

    /// `00 02 00` = automatic, `00 02 01 <MAC 6>` = preferred device.
    static func preferredDevice(_ payload: [UInt8]) -> String? {
        guard payload.count >= 9, payload[0] == 0x00, payload[1] == 0x02, payload[2] == 0x01 else {
            return nil
        }
        return payload[3..<9].map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    static func gestures(_ payload: [UInt8]) -> [OppoGestureBinding]? {
        guard payload.count >= 2, payload[0] == 0x00 else { return nil }
        let count = Int(payload[1])
        guard count <= 32, payload.count >= 2 + count * 4 else { return nil }

        var bindings: [OppoGestureBinding] = []
        var index = 2
        for _ in 0..<count {
            bindings.append(
                OppoGestureBinding(
                    device: payload[index],
                    button: payload[index + 1],
                    action: payload[index + 2],
                    function: payload[index + 3]
                )
            )
            index += 4
        }
        return bindings
    }
}

enum OppoCodecName {
    static func name(for codec: Int) -> String {
        switch codec {
        case 1: "SBC"
        case 2: "AAC"
        case 3: "LDAC"
        case 4: "aptX"
        case 5: "aptX HD"
        case 6: "aptX Adaptive"
        case 7: "LHDC"
        case 8: "LHDC 5.0"
        default: "Codec \(codec)"
        }
    }
}

// MARK: - Custom EQ frames

enum OppoEQWrite {
    /// `0x0418 <action> FA 06 <id> <nameLen> <name> <bands> [freq u16 LE, gain s8]...`
    static func frame(
        action: UInt8,
        id: UInt8,
        name: String,
        bands: [OppoEQBand],
        sequence: UInt8
    ) -> Data {
        var payload: [UInt8] = [action, 0xFA, 0x06, id]
        let nameBytes = Array(name.utf8.prefix(64))
        payload.append(UInt8(nameBytes.count))
        payload += nameBytes
        payload.append(UInt8(bands.count))
        for band in bands {
            payload.append(UInt8(band.frequency & 0xFF))
            payload.append(UInt8((band.frequency >> 8) & 0xFF))
            payload.append(UInt8(bitPattern: Int8(clamping: band.gain)))
        }
        return OppoWire.encode(command: 0x0418, sequence: sequence, payload: payload)
    }
}
