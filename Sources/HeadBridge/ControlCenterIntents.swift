import AppIntents
import Foundation

enum HeadBridgeControlConstants {
    private static let namespace = "io.github.herenickname.HeadBridge"

    static let noiseControlKind = "\(namespace).control.noise"
    static let stickyInputKind = "\(namespace).control.sticky-input"

    static let cycleNoiseNotification = Notification.Name("\(namespace).command.cycle-noise")
    static let stickyInputOnNotification = Notification.Name("\(namespace).command.sticky-input-on")
    static let stickyInputOffNotification = Notification.Name("\(namespace).command.sticky-input-off")

    fileprivate static let preferencesSuite = "\(namespace).control-state"
    fileprivate static let noiseModeKey = "noiseMode"
    fileprivate static let supportedNoiseModesKey = "supportedNoiseModes"
    fileprivate static let stickyInputKey = "stickyInput"
}

enum HeadBridgeControlStateStore {
    private static var defaults: UserDefaults {
        UserDefaults(suiteName: HeadBridgeControlConstants.preferencesSuite) ?? .standard
    }

    static var noiseMode: Int {
        defaults.integer(forKey: HeadBridgeControlConstants.noiseModeKey)
    }

    static var stickyInputEnabled: Bool {
        defaults.bool(forKey: HeadBridgeControlConstants.stickyInputKey)
    }

    static var supportedNoiseModes: [Int] {
        let stored =
            defaults.array(forKey: HeadBridgeControlConstants.supportedNoiseModesKey)?
            .compactMap { ($0 as? NSNumber)?.intValue } ?? []
        return stored.isEmpty ? [0, 2, 1] : stored
    }

    static func setNoiseMode(_ mode: Int) {
        defaults.set(mode, forKey: HeadBridgeControlConstants.noiseModeKey)
    }

    static func setSupportedNoiseModes(_ modes: [Int]) {
        defaults.set(modes, forKey: HeadBridgeControlConstants.supportedNoiseModesKey)
    }

    static func setStickyInputEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: HeadBridgeControlConstants.stickyInputKey)
    }
}

@available(macOS 26.0, *)
struct CycleNoiseControlIntent: AppIntent {
    static var title: LocalizedStringResource = "Cycle Headphones Noise Control"
    static var description = IntentDescription(
        "Switch between the noise-control modes supported by the active headphones.")
    static var isDiscoverable = false
    static var supportedModes: IntentModes { .background }

    func perform() async throws -> some IntentResult {
        let modes = HeadBridgeControlStateStore.supportedNoiseModes
        let current = HeadBridgeControlStateStore.noiseMode
        let nextMode: Int
        if let index = modes.firstIndex(of: current) {
            nextMode = modes[(index + 1) % modes.count]
        } else {
            nextMode = modes[0]
        }
        HeadBridgeControlStateStore.setNoiseMode(nextMode)
        DistributedNotificationCenter.default().postNotificationName(
            HeadBridgeControlConstants.cycleNoiseNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        return .result()
    }
}

@available(macOS 26.0, *)
struct SetStickyInputControlIntent: SetValueIntent {
    static var title: LocalizedStringResource = "Set Sticky Input"
    static var description = IntentDescription("Keep macOS on the currently selected microphone.")
    static var isDiscoverable = false
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Enabled")
    var value: Bool

    init() {}

    func perform() async throws -> some IntentResult {
        HeadBridgeControlStateStore.setStickyInputEnabled(value)
        let name =
            value
            ? HeadBridgeControlConstants.stickyInputOnNotification
            : HeadBridgeControlConstants.stickyInputOffNotification
        DistributedNotificationCenter.default().postNotificationName(
            name,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        return .result()
    }
}
