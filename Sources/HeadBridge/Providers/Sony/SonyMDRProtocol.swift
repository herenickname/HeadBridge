import Foundation

/// The small transport envelope shared by Sony's first-generation MDR
/// protocol. Feature payloads intentionally live outside the framing layer so
/// additional Sony model profiles can be added without touching the parser.
struct SonyMDRPacket: Equatable, Sendable {
    static let ackType: UInt8 = 0x01
    static let commandType: UInt8 = 0x0C
    static let commandType2: UInt8 = 0x0E

    let dataType: UInt8
    let sequence: UInt8
    let payload: [UInt8]
}

enum SonyMDRFraming {
    static let startMarker: UInt8 = 0x3E
    static let endMarker: UInt8 = 0x3C
    static let escapeMarker: UInt8 = 0x3D
    private static let escapeMask: UInt8 = 0xEF

    static func encode(_ packet: SonyMDRPacket) -> Data {
        precondition(packet.payload.count <= Int(UInt32.max))

        let length = UInt32(packet.payload.count)
        var body: [UInt8] = [
            packet.dataType,
            packet.sequence,
            UInt8(truncatingIfNeeded: length >> 24),
            UInt8(truncatingIfNeeded: length >> 16),
            UInt8(truncatingIfNeeded: length >> 8),
            UInt8(truncatingIfNeeded: length),
        ]
        body.append(contentsOf: packet.payload)
        body.append(body.reduce(0, &+))

        var encoded: [UInt8] = [startMarker]
        encoded.reserveCapacity(body.count + 2)
        for byte in body {
            if byte == startMarker || byte == endMarker || byte == escapeMarker {
                encoded.append(escapeMarker)
                encoded.append(byte & escapeMask)
            } else {
                encoded.append(byte)
            }
        }
        encoded.append(endMarker)
        return Data(encoded)
    }
}

/// Incremental parser because RFCOMM may split one frame across callbacks or
/// coalesce several frames into one callback.
final class SonyMDRFrameParser {
    static let defaultMaximumPayloadLength = 1_048_576

    private enum State {
        case waitingForStart
        case readingBody
    }

    private var state: State = .waitingForStart
    private var body: [UInt8] = []
    private var isEscaped = false
    private let maximumPayloadLength: Int

    init(maximumPayloadLength: Int = SonyMDRFrameParser.defaultMaximumPayloadLength) {
        self.maximumPayloadLength = min(Int(UInt32.max), max(0, maximumPayloadLength))
    }

    func reset() {
        state = .waitingForStart
        body.removeAll(keepingCapacity: true)
        isEscaped = false
    }

    func append(_ data: Data) -> [SonyMDRPacket] {
        var packets: [SonyMDRPacket] = []

        for byte in data {
            switch state {
            case .waitingForStart:
                guard byte == SonyMDRFraming.startMarker else { continue }
                state = .readingBody
                body.removeAll(keepingCapacity: true)
                isEscaped = false

            case .readingBody:
                if isEscaped {
                    body.append(byte | 0x10)
                    isEscaped = false
                } else if byte == SonyMDRFraming.escapeMarker {
                    isEscaped = true
                } else if byte == SonyMDRFraming.endMarker {
                    if let packet = Self.decode(body, maximumPayloadLength: maximumPayloadLength) {
                        packets.append(packet)
                    }
                    state = .waitingForStart
                    body.removeAll(keepingCapacity: true)
                } else if byte == SonyMDRFraming.startMarker {
                    // A new marker before the previous frame ended is a useful
                    // resynchronization point after a corrupt byte stream.
                    body.removeAll(keepingCapacity: true)
                    isEscaped = false
                } else {
                    body.append(byte)
                }

                // A corrupt stream without an end marker must not grow the
                // process indefinitely. Seven bytes are the fixed envelope
                // (type, sequence, length, checksum) around the payload.
                if body.count > maximumPayloadLength + 7 {
                    reset()
                }
            }
        }

        return packets
    }

    private static func decode(
        _ body: [UInt8],
        maximumPayloadLength: Int
    ) -> SonyMDRPacket? {
        guard body.count >= 7 else { return nil }

        let length =
            (UInt32(body[2]) << 24) | (UInt32(body[3]) << 16) | (UInt32(body[4]) << 8) | UInt32(body[5])
        guard length <= UInt32(maximumPayloadLength),
            body.count == Int(length) + 7
        else { return nil }

        let checksumIndex = 6 + Int(length)
        let expectedChecksum = body[..<checksumIndex].reduce(UInt8(0), &+)
        guard body[checksumIndex] == expectedChecksum else { return nil }

        return SonyMDRPacket(
            dataType: body[0],
            sequence: body[1],
            payload: Array(body[6..<checksumIndex])
        )
    }
}

enum SonyV1Opcode {
    static let initGet: UInt8 = 0x00
    static let initReturn: UInt8 = 0x01

    static let modelGet: UInt8 = 0x04
    static let modelReturn: UInt8 = 0x05

    static let batteryGet: UInt8 = 0x10
    static let batteryReturn: UInt8 = 0x11
    static let batteryNotify: UInt8 = 0x13

    static let codecGet: UInt8 = 0x18
    static let codecReturn: UInt8 = 0x19
    static let codecNotify: UInt8 = 0x1B

    static let virtualSoundGet: UInt8 = 0x46
    static let virtualSoundReturn: UInt8 = 0x47
    static let virtualSoundSet: UInt8 = 0x48
    static let virtualSoundNotify: UInt8 = 0x49

    static let equalizerGet: UInt8 = 0x56
    static let equalizerReturn: UInt8 = 0x57
    static let equalizerSet: UInt8 = 0x58
    static let equalizerNotify: UInt8 = 0x59

    static let noiseCapabilityGet: UInt8 = 0x60
    static let noiseCapabilityReturn: UInt8 = 0x61
    static let noiseGet: UInt8 = 0x66
    static let noiseReturn: UInt8 = 0x67
    static let noiseSet: UInt8 = 0x68
    static let noiseNotify: UInt8 = 0x69

    static let optimizerStart: UInt8 = 0x84
    static let optimizerStatus: UInt8 = 0x85
    static let optimizerStateGet: UInt8 = 0x86
    static let optimizerStateReturn: UInt8 = 0x87
    static let optimizerStateNotify: UInt8 = 0x89

    static let playbackGet: UInt8 = 0xA6
    static let playbackReturn: UInt8 = 0xA7
    static let playbackSet: UInt8 = 0xA8
    static let playbackNotify: UInt8 = 0xA9

    static let touchSensorGet: UInt8 = 0xD6
    static let touchSensorReturn: UInt8 = 0xD7
    static let touchSensorSet: UInt8 = 0xD8
    static let touchSensorNotify: UInt8 = 0xD9

    static let audioSettingGet: UInt8 = 0xE6
    static let audioSettingReturn: UInt8 = 0xE7
    static let audioSettingSet: UInt8 = 0xE8
    static let audioSettingNotify: UInt8 = 0xE9

    static let systemSettingGet: UInt8 = 0xF6
    static let systemSettingReturn: UInt8 = 0xF7
    static let systemSettingSet: UInt8 = 0xF8
    static let systemSettingNotify: UInt8 = 0xF9
}

enum SonyV1NoiseMode: Equatable, Sendable {
    case off
    case noiseCancellation
    case ambient
    case windReduction

    static func decode(
        effect: UInt8,
        ncSettingType: UInt8,
        ncValue: UInt8,
        ambientLevel: Int
    ) -> Self {
        guard effect != 0x00 else { return .off }
        if ncSettingType == 0x02, ncValue == 0x01 { return .windReduction }
        if ncValue != 0x00 { return .noiseCancellation }
        if (1...20).contains(ambientLevel) { return .ambient }
        return .off
    }
}

enum SonyMDRProtocolVersion: String, Equatable, Codable, Sendable {
    case v1
    case v2

    /// The init reply includes its opcode. Known V1 replies are four bytes;
    /// Link2/V2 replies are eight bytes.
    static func detect(fromInitReply payload: [UInt8]) -> Self? {
        guard payload.first == SonyV1Opcode.initReturn else { return nil }
        return switch payload.count {
        case 4: .v1
        case 8: .v2
        default: nil
        }
    }
}

enum SonyV1EqualizerPreset: UInt8, CaseIterable, Identifiable, Codable, Sendable {
    case off = 0x00
    case bright = 0x10
    case excited = 0x11
    case mellow = 0x12
    case relaxed = 0x13
    case vocal = 0x14
    case trebleBoost = 0x15
    case bassBoost = 0x16
    case speech = 0x17
    case manual = 0xA0
    case custom1 = 0xA1
    case custom2 = 0xA2

    var id: UInt8 { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .bright: "Bright"
        case .excited: "Excited"
        case .mellow: "Mellow"
        case .relaxed: "Relaxed"
        case .vocal: "Vocal"
        case .trebleBoost: "Treble Boost"
        case .bassBoost: "Bass Boost"
        case .speech: "Speech"
        case .manual: "Manual"
        case .custom1: "Custom 1"
        case .custom2: "Custom 2"
        }
    }

    var acceptsCustomBands: Bool {
        self == .manual || self == .custom1 || self == .custom2
    }
}

enum SonyV1SurroundMode: UInt8, CaseIterable, Identifiable, Codable, Sendable {
    case off = 0x00
    case outdoorStage = 0x01
    case arena = 0x02
    case concertHall = 0x03
    case club = 0x04

    var id: UInt8 { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .outdoorStage: "Outdoor Stage"
        case .arena: "Arena"
        case .concertHall: "Concert Hall"
        case .club: "Club"
        }
    }
}

enum SonyV1SoundPosition: UInt8, CaseIterable, Identifiable, Codable, Sendable {
    case off = 0x00
    case frontLeft = 0x01
    case frontRight = 0x02
    case front = 0x03
    case rearLeft = 0x11
    case rearRight = 0x12

    var id: UInt8 { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .frontLeft: "Front Left"
        case .frontRight: "Front Right"
        case .front: "Front"
        case .rearLeft: "Rear Left"
        case .rearRight: "Rear Right"
        }
    }
}

enum SonyV1AutomaticPowerOff: String, CaseIterable, Identifiable, Codable, Sendable {
    case off
    case after5Minutes
    case after30Minutes
    case after1Hour
    case after3Hours

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .after5Minutes: "5 minutes"
        case .after30Minutes: "30 minutes"
        case .after1Hour: "1 hour"
        case .after3Hours: "3 hours"
        }
    }

    var code: (UInt8, UInt8) {
        switch self {
        case .off: (0x11, 0x00)
        case .after5Minutes: (0x00, 0x00)
        case .after30Minutes: (0x01, 0x01)
        case .after1Hour: (0x02, 0x02)
        case .after3Hours: (0x03, 0x03)
        }
    }

    init?(first: UInt8, second: UInt8) {
        guard
            let value = Self.allCases.first(where: {
                $0.code.0 == first && $0.code.1 == second
            })
        else { return nil }
        self = value
    }
}

enum SonyV1SoundQualityMode: UInt8, CaseIterable, Identifiable, Codable, Sendable {
    case prioritizeSoundQuality = 0x00
    case prioritizeStableConnection = 0x01

    var id: UInt8 { rawValue }

    var title: String {
        switch self {
        case .prioritizeSoundQuality: "Prioritize Sound Quality"
        case .prioritizeStableConnection: "Prioritize Stable Connection"
        }
    }
}

enum SonyV1OptimizerStatus: UInt8, Codable, Sendable {
    case notRunning = 0x00
    case wearingCondition = 0x01
    case atmosphericPressure = 0x02
    case analyzing = 0x10
    case finished = 0x11

    var title: String {
        switch self {
        case .notRunning: "Not running"
        case .wearingCondition: "Checking fit"
        case .atmosphericPressure: "Measuring pressure"
        case .analyzing: "Analyzing"
        case .finished: "Finished"
        }
    }

    var isRunning: Bool {
        self != .notRunning && self != .finished
    }
}

enum SonyV1Payloads {
    static func equalizerPreset(_ preset: SonyV1EqualizerPreset) -> [UInt8] {
        [SonyV1Opcode.equalizerSet, 0x01, preset.rawValue, 0x00]
    }

    /// UI order is 400 Hz, 1 kHz, 2.5 kHz, 6.3 kHz, 16 kHz, Clear Bass.
    static func equalizerBands(_ values: [Int]) -> [UInt8] {
        let normalized = Array((values + Array(repeating: 0, count: 6)).prefix(6))
            .map { UInt8(clamping: min(10, max(-10, $0)) + 10) }
        return [
            SonyV1Opcode.equalizerSet, 0x01, 0xFF, 0x06,
            normalized[5], normalized[0], normalized[1], normalized[2], normalized[3], normalized[4],
        ]
    }

    static func surroundMode(_ mode: SonyV1SurroundMode) -> [UInt8] {
        [SonyV1Opcode.virtualSoundSet, 0x01, mode.rawValue]
    }

    static func soundPosition(_ position: SonyV1SoundPosition) -> [UInt8] {
        [SonyV1Opcode.virtualSoundSet, 0x02, position.rawValue]
    }

    static func dsee(enabled: Bool) -> [UInt8] {
        [SonyV1Opcode.audioSettingSet, 0x02, 0x00, enabled ? 0x01 : 0x00]
    }

    static func soundQuality(_ mode: SonyV1SoundQualityMode) -> [UInt8] {
        [SonyV1Opcode.audioSettingSet, 0x01, 0x00, mode.rawValue]
    }

    static func touchSensor(enabled: Bool, slot: UInt8 = 0xD2) -> [UInt8] {
        [SonyV1Opcode.touchSensorSet, slot, 0x01, enabled ? 0x01 : 0x00]
    }

    static func optimizer(start: Bool) -> [UInt8] {
        [SonyV1Opcode.optimizerStart, 0x01, 0x00, start ? 0x01 : 0x00]
    }

    static func automaticPowerOff(_ mode: SonyV1AutomaticPowerOff) -> [UInt8] {
        [SonyV1Opcode.systemSettingSet, 0x04, 0x01, mode.code.0, mode.code.1]
    }
}

struct SonyV1State: Equatable, Sendable {
    var modelName: String?
    var batteryPercent: Int?
    var isCharging: Bool?
    var codecName: String?
    var noiseMode: SonyV1NoiseMode?
    var windReductionSupported = false
    var ambientLevel = 20
    var volume: Int?
    var equalizerPreset: SonyV1EqualizerPreset?
    var equalizerBands = Array(repeating: 0, count: 6)
    var surroundMode: SonyV1SurroundMode?
    var soundPosition: SonyV1SoundPosition?
    var dseeEnabled: Bool?
    var soundQualityMode: SonyV1SoundQualityMode?
    var touchSensorEnabled: Bool?
    var automaticPowerOff: SonyV1AutomaticPowerOff?
    var optimizerStatus: SonyV1OptimizerStatus?
    var atmosphericPressure: Double?
}

struct SonyV1ProfileFeatures: OptionSet, Equatable, Sendable {
    let rawValue: UInt16

    static let equalizer = Self(rawValue: 1 << 0)
    static let virtualSound = Self(rawValue: 1 << 1)
    static let audioUpsampling = Self(rawValue: 1 << 2)
    static let soundQualityMode = Self(rawValue: 1 << 3)
    static let touchSensor = Self(rawValue: 1 << 4)
    static let automaticPowerOff = Self(rawValue: 1 << 5)
    static let noiseOptimizer = Self(rawValue: 1 << 6)
}

/// Model names select only the capability profile. Transport ownership stays
/// in the Sony MDR V1 provider, shared by every device exposing the V1 service.
/// Unknown V1 devices still receive the common battery/noise/codec/volume
/// queries; extra controls are queried only when their layout is known.
struct SonyV1DeviceProfile: Equatable, Sendable {
    enum NoiseEncoding: Equatable, Sendable {
        case fixedDualMicrophone
        case reportedByDevice
    }

    let noiseEncoding: NoiseEncoding
    let features: SonyV1ProfileFeatures

    init(deviceName: String) {
        let model = deviceName.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()

        noiseEncoding =
            model.contains("wh1000xm2") || model.contains("wh1000xm3")
            ? .fixedDualMicrophone
            : .reportedByDevice

        if model.contains("wh1000xm3") {
            features = [
                .equalizer, .virtualSound, .audioUpsampling, .soundQualityMode,
                .touchSensor, .automaticPowerOff, .noiseOptimizer,
            ]
        } else if model.contains("wh1000xm2") {
            features = [.equalizer, .virtualSound, .audioUpsampling, .noiseOptimizer]
        } else if model.contains("wh1000xm4") {
            features = [.equalizer, .audioUpsampling, .touchSensor, .noiseOptimizer]
        } else if model.contains("wf1000xm3") {
            features = [.equalizer, .audioUpsampling]
        } else if model.contains("wfsp800n") {
            features = [.equalizer]
        } else if model.contains("wisp600n") {
            features = [.equalizer, .virtualSound, .automaticPowerOff]
        } else {
            features = []
        }
    }

    func noisePayload(
        mode: SonyV1NoiseMode,
        ambientLevel: Int,
        reportedNCType: UInt8,
        reportedASMType: UInt8,
        reportedASMID: UInt8
    ) -> [UInt8] {
        let level = UInt8(clamping: min(20, max(1, ambientLevel)))

        switch noiseEncoding {
        case .fixedDualMicrophone:
            // This V1 profile exposes combined NC/ASM: NC type 0x02
            // means OFF / wind reduction / dual-microphone cancellation,
            // while ASM type 0x01 carries the 1...20 ambient level.
            switch mode {
            case .off:
                return [SonyV1Opcode.noiseSet, 0x02, 0x00, 0x02, 0x00, 0x01, 0x00, 0x00]
            case .noiseCancellation:
                return [SonyV1Opcode.noiseSet, 0x02, 0x11, 0x02, 0x02, 0x01, 0x00, 0x00]
            case .windReduction:
                return [SonyV1Opcode.noiseSet, 0x02, 0x11, 0x02, 0x01, 0x01, 0x00, 0x00]
            case .ambient:
                return [SonyV1Opcode.noiseSet, 0x02, 0x11, 0x02, 0x00, 0x01, 0x00, level]
            }

        case .reportedByDevice:
            switch mode {
            case .off:
                return [
                    SonyV1Opcode.noiseSet, 0x02, 0x00, reportedNCType, 0x00,
                    reportedASMType, reportedASMID, 0x00,
                ]
            case .noiseCancellation:
                return [
                    SonyV1Opcode.noiseSet, 0x02, 0x11, reportedNCType, 0x02,
                    reportedASMType, reportedASMID, 0x00,
                ]
            case .windReduction:
                return [
                    SonyV1Opcode.noiseSet, 0x02, 0x11, reportedNCType, 0x01,
                    reportedASMType, reportedASMID, 0x00,
                ]
            case .ambient:
                return [
                    SonyV1Opcode.noiseSet, 0x02, 0x11, reportedNCType, 0x00,
                    reportedASMType, reportedASMID, level,
                ]
            }
        }
    }
}
