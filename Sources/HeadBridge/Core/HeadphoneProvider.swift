import Combine
import Foundation

enum HeadphoneConnectionState: Equatable {
    case idle
    case scanning
    case connecting
    case ready
    case failed(String)

    var isConnecting: Bool {
        switch self {
        case .scanning, .connecting: true
        default: false
        }
    }

    var title: String {
        switch self {
        case .idle: "Not connected"
        case .scanning: "Scanning…"
        case .connecting: "Connecting…"
        case .ready: "Connected"
        case .failed(let message): message
        }
    }
}

enum HeadphoneNoiseMode: Int, CaseIterable, Identifiable {
    case off = 0
    case noiseCancellation = 1
    case ambient = 2
    case windReduction = 3

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .noiseCancellation: "Noise Cancellation"
        case .ambient: "Ambient"
        case .windReduction: "Wind Reduction"
        }
    }

    var icon: String {
        switch self {
        case .off: "person.fill"
        case .noiseCancellation: "waveform.badge.minus"
        case .ambient: "ear"
        case .windReduction: "wind"
        }
    }
}

struct HeadphoneCapabilities: OptionSet {
    let rawValue: UInt64

    static let battery = Self(rawValue: 1 << 0)
    static let noiseControl = Self(rawValue: 1 << 1)
    static let ambientLevel = Self(rawValue: 1 << 2)
    static let deviceVolume = Self(rawValue: 1 << 3)
    static let equalizer = Self(rawValue: 1 << 4)
    static let wearSensor = Self(rawValue: 1 << 5)
    static let spatialAudio = Self(rawValue: 1 << 6)
    static let voicePrompts = Self(rawValue: 1 << 7)
    static let surroundSound = Self(rawValue: 1 << 8)
    static let soundPosition = Self(rawValue: 1 << 9)
    static let audioUpsampling = Self(rawValue: 1 << 10)
    static let touchSensor = Self(rawValue: 1 << 11)
    static let automaticPowerOff = Self(rawValue: 1 << 12)
    static let noiseOptimizer = Self(rawValue: 1 << 13)
    static let soundQualityMode = Self(rawValue: 1 << 14)
    static let standbyTimer = Self(rawValue: 1 << 15)
    static let customButton = Self(rawValue: 1 << 16)
    static let deviceName = Self(rawValue: 1 << 17)
    static let windReduction = Self(rawValue: 1 << 18)
}

enum HeadphoneBatterySymbol {
    /// SF Symbols exposes battery fill in 25-point steps. Pick the nearest
    /// symbol instead of showing the same decorative 75% icon for every value.
    static func name(for level: Int?) -> String {
        guard let level else { return "battery.0percent" }
        return switch min(100, max(0, level)) {
        case ...12: "battery.0percent"
        case ...37: "battery.25percent"
        case ...62: "battery.50percent"
        case ...87: "battery.75percent"
        default: "battery.100percent"
        }
    }
}

/// Shared normalization for matching the Core Audio and vendor-transport names
/// of the same physical device. Providers still own their model prefilters;
/// this helper only removes punctuation/case differences once a candidate is
/// known to belong to that vendor.
enum BluetoothDeviceNameMatcher {
    static func normalized(_ value: String) -> String {
        value.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    static func matches(_ lhs: String, _ rhs: String, minimumLength: Int = 4) -> Bool {
        let a = normalized(lhs)
        let b = normalized(rhs)
        guard a.count >= minimumLength, b.count >= minimumLength else { return false }
        return a == b || a.contains(b) || b.contains(a)
    }
}

/// Shared persistence for provider-owned restore profiles. The profile body is
/// intentionally generic: each driver remains responsible for describing and
/// applying only the settings its hardware actually supports.
@MainActor
enum HeadphoneProfileStore {
    private static let restorePrefix = "HeadBridge.RestoreOnConnect"
    private static let profilePrefix = "HeadBridge.RestoreProfile"

    static func isRestoreEnabled(for providerID: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: "\(restorePrefix).\(providerID)")
    }

    static func setRestoreEnabled(
        _ enabled: Bool,
        for providerID: String,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(enabled, forKey: "\(restorePrefix).\(providerID)")
    }

    static func load<Profile: Decodable>(
        _ type: Profile.Type,
        providerID: String,
        deviceID: String,
        defaults: UserDefaults = .standard
    ) -> Profile? {
        guard let data = defaults.data(forKey: profileKey(providerID: providerID, deviceID: deviceID)) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<Profile: Encodable>(
        _ profile: Profile,
        providerID: String,
        deviceID: String,
        defaults: UserDefaults = .standard
    ) {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        defaults.set(data, forKey: profileKey(providerID: providerID, deviceID: deviceID))
    }

    private static func profileKey(providerID: String, deviceID: String) -> String {
        "\(profilePrefix).\(providerID).\(deviceID.lowercased())"
    }
}

@MainActor
protocol HeadphoneProvider: AnyObject {
    var objectWillChange: ObservableObjectPublisher { get }
    var providerID: String { get }
    var vendorName: String { get }
    var connectedDeviceID: String? { get }
    var connectionState: HeadphoneConnectionState { get }
    var connectedName: String { get }
    var batteryPercent: Int? { get }
    var isCharging: Bool? { get }
    var codecName: String? { get }
    var capabilities: HeadphoneCapabilities { get }
    var noiseMode: HeadphoneNoiseMode? { get }
    var supportedNoiseModes: [HeadphoneNoiseMode] { get }
    var restoreOnConnectEnabled: Bool { get }
    var supportsSystemVolumeSynchronization: Bool { get }
    var defaultSystemVolumeSynchronizationEnabled: Bool { get }
    var connectionStatePublisher: AnyPublisher<HeadphoneConnectionState, Never> { get }

    func recognizesBluetoothDevice(named name: String) -> Bool
    func updateBluetoothPairedDevices(_ devices: [BluetoothPairedDevice])
    func matches(audioDevice: SystemAudioDevice) -> Bool
    func updateAudioConnectedDevices(_ devices: [SystemAudioDevice])
    func refresh()
    func refreshBatteryStatus()
    func disconnect()
    func shutdown()
    func setNoiseMode(_ mode: HeadphoneNoiseMode)
    func setRestoreOnConnectEnabled(_ enabled: Bool)
    func setDeviceVolume(normalized: Float)
}

extension HeadphoneProvider {
    var supportsSystemVolumeSynchronization: Bool { false }
    var defaultSystemVolumeSynchronizationEnabled: Bool { false }

    func recognizesBluetoothDevice(named name: String) -> Bool { false }
    func updateBluetoothPairedDevices(_ devices: [BluetoothPairedDevice]) {}
    func setDeviceVolume(normalized: Float) {}
    func refreshBatteryStatus() {}
    func shutdown() { disconnect() }
}
