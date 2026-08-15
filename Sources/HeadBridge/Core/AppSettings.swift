import Combine
import Foundation
import OSLog
import ServiceManagement

enum BatteryDisplayMode: String, CaseIterable, Identifiable {
    case never
    case low
    case always

    var id: String { rawValue }

    var title: String {
        switch self {
        case .never: "Never"
        case .low: "Only below 20%"
        case .always: "Always"
        }
    }

    func shouldDisplay(level: Int?) -> Bool {
        guard let level else { return false }
        return switch self {
        case .never: false
        case .low: level < 20
        case .always: true
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let batteryDisplayMode = "BatteryDisplayMode"
        static let legacySonyVolumeSync = "SonyVolumeSync"
        static let volumeSyncPrefix = "VolumeSyncEnabled"
        static let developerMode = "DeveloperModeEnabled"
        static let launchAtLoginRequested = "LaunchAtLoginRequested"

        static func volumeSync(providerID: String) -> String {
            "\(volumeSyncPrefix).\(providerID)"
        }
    }

    @Published var batteryDisplayMode: BatteryDisplayMode {
        didSet { defaults.set(batteryDisplayMode.rawValue, forKey: Key.batteryDisplayMode) }
    }

    @Published private var volumeSyncEnabledByProvider: [String: Bool] = [:]

    @Published var developerModeEnabled: Bool {
        didSet { defaults.set(developerModeEnabled, forKey: Key.developerMode) }
    }

    @Published private(set) var launchAtLoginEnabled = false
    @Published private(set) var launchAtLoginRequiresApproval = false
    @Published private(set) var launchAtLoginError: String?

    private let defaults: UserDefaults
    private let launchAtLoginLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "io.github.herenickname.HeadBridge",
        category: "LaunchAtLogin"
    )

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        batteryDisplayMode =
            defaults.string(forKey: Key.batteryDisplayMode)
            .flatMap(BatteryDisplayMode.init(rawValue:)) ?? .always
        developerModeEnabled = defaults.bool(forKey: Key.developerMode)

        let status = SMAppService.mainApp.status
        if defaults.object(forKey: Key.launchAtLoginRequested) == nil,
            status == .enabled || status == .requiresApproval
        {
            defaults.set(true, forKey: Key.launchAtLoginRequested)
        }
        reconcileLaunchAtLoginRegistration()
    }

    func registerVolumeSynchronization(
        providerID: String,
        defaultEnabled: Bool
    ) {
        guard volumeSyncEnabledByProvider[providerID] == nil else { return }

        let key = Key.volumeSync(providerID: providerID)
        let value: Bool
        if let stored = defaults.object(forKey: key) as? Bool {
            value = stored
        } else if providerID == "sony-mdr",
            let legacy = defaults.object(forKey: Key.legacySonyVolumeSync) as? Bool
        {
            value = legacy
            defaults.set(legacy, forKey: key)
            defaults.removeObject(forKey: Key.legacySonyVolumeSync)
        } else {
            value = defaultEnabled
        }
        volumeSyncEnabledByProvider[providerID] = value
    }

    func volumeSynchronizationEnabled(for providerID: String) -> Bool {
        volumeSyncEnabledByProvider[providerID] ?? false
    }

    func setVolumeSynchronizationEnabled(_ enabled: Bool, for providerID: String) {
        volumeSyncEnabledByProvider[providerID] = enabled
        defaults.set(enabled, forKey: Key.volumeSync(providerID: providerID))
    }

    func volumeSynchronizationPublisher(for providerID: String) -> AnyPublisher<Bool, Never> {
        $volumeSyncEnabledByProvider
            .map { $0[providerID] ?? false }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Key.launchAtLoginRequested)
        reconcileLaunchAtLoginRegistration()
    }

    private func reconcileLaunchAtLoginRegistration() {
        launchAtLoginError = nil
        let requested = defaults.bool(forKey: Key.launchAtLoginRequested)
        do {
            if requested {
                switch SMAppService.mainApp.status {
                case .notRegistered, .notFound:
                    try SMAppService.mainApp.register()
                    launchAtLoginLogger.info("Registered the main app as a login item")
                case .enabled, .requiresApproval:
                    break
                @unknown default:
                    break
                }
            } else if SMAppService.mainApp.status != .notRegistered,
                SMAppService.mainApp.status != .notFound
            {
                try SMAppService.mainApp.unregister()
                launchAtLoginLogger.info("Unregistered the main app login item")
            }
        } catch {
            launchAtLoginError = error.localizedDescription
            launchAtLoginLogger.error(
                "Could not update login-item registration: \(error.localizedDescription, privacy: .public)")
        }
        refreshLaunchAtLoginStatus()
    }

    func refreshLaunchAtLoginStatus() {
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLoginEnabled = true
            launchAtLoginRequiresApproval = false
        case .requiresApproval:
            launchAtLoginEnabled = true
            launchAtLoginRequiresApproval = true
        case .notRegistered, .notFound:
            launchAtLoginEnabled = false
            launchAtLoginRequiresApproval = false
        @unknown default:
            launchAtLoginEnabled = false
            launchAtLoginRequiresApproval = false
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
