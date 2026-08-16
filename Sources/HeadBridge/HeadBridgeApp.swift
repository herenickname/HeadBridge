import AppKit
import Darwin
import SwiftUI

@MainActor
enum HeadBridgeWindowCoordinator {
    @discardableResult
    static func focusSettingsWindow() -> Bool {
        guard
            let window = NSApp.windows.first(where: {
                !($0 is NSPanel) && $0.canBecomeKey
            })
        else { return false }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        return true
    }
}

@MainActor
enum HeadBridgeInstanceGuard {
    private static var lockFileDescriptor: Int32 = -1

    /// Takes an advisory lock before the app constructs any Bluetooth objects.
    /// `LSMultipleInstancesProhibited` handles normal LaunchServices launches;
    /// this lock also closes the race between two direct executable launches.
    static func acquireProcessLock() -> Bool {
        if lockFileDescriptor >= 0 {
            return true
        }

        let fileManager = FileManager.default
        let supportDirectory: URL
        do {
            supportDirectory = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("HeadBridge", isDirectory: true)
            try fileManager.createDirectory(
                at: supportDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            // Preserve launchability on an unusual read-only home directory;
            // the running-application check still provides a fallback guard.
            return !activateExistingInstance()
        }

        let lockPath = supportDirectory.appendingPathComponent("Instance.lock").path
        let descriptor = Darwin.open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            return !activateExistingInstance()
        }
        _ = Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR)

        var advisoryLock = Darwin.flock()
        advisoryLock.l_type = Int16(F_WRLCK)
        advisoryLock.l_whence = Int16(SEEK_SET)
        advisoryLock.l_start = 0
        advisoryLock.l_len = 0
        guard Darwin.fcntl(descriptor, F_SETLK, &advisoryLock) != -1 else {
            Darwin.close(descriptor)
            _ = activateExistingInstance()
            return false
        }

        lockFileDescriptor = descriptor
        return true
    }

    /// SwiftUI constructs the `App` value before AppDelegate receives its first
    /// launch callback. Detect an existing process here so a duplicate never
    /// creates Bluetooth providers or opens a second control transport.
    static func activateExistingInstance() -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return false }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        guard
            let existing =
                NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleIdentifier)
                .first(where: { $0.processIdentifier != currentPID && !$0.isTerminated })
        else {
            return false
        }
        existing.activate(options: [.activateAllWindows])
        return true
    }
}

@MainActor
final class HeadBridgeAppDelegate: NSObject, NSApplicationDelegate {
    private var isDuplicateInstance = false
    var shutdownHandler: (@MainActor () -> Void)?

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard let application = notification.object as? NSApplication,
            HeadBridgeInstanceGuard.activateExistingInstance()
        else { return }

        isDuplicateInstance = true
        DispatchQueue.main.async { application.terminate(nil) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !isDuplicateInstance else { return false }
        return !HeadBridgeWindowCoordinator.focusSettingsWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        shutdownHandler?()
        shutdownHandler = nil
    }
}

@main
struct HeadBridgeApp: App {
    @NSApplicationDelegateAdaptor(HeadBridgeAppDelegate.self) private var appDelegate
    @StateObject private var manager: HeadphoneManager
    @StateObject private var bowersWilkins: BowersWilkinsProvider
    @StateObject private var sony: SonyMDRProvider
    @StateObject private var systemAudio: SystemAudioController
    @StateObject private var settings: AppSettings
    @StateObject private var updates: UpdateController
    @StateObject private var batteryHistory: BatteryHistoryStore

    init() {
        if !HeadBridgeInstanceGuard.acquireProcessLock() {
            exit(EXIT_SUCCESS)
        }

        let bowersWilkins = BowersWilkinsProvider()
        let sony = SonyMDRProvider()
        let systemAudio = SystemAudioController()
        let settings = AppSettings()
        let updates = UpdateController()
        bowersWilkins.setDiagnosticsEnabled(settings.developerModeEnabled)
        sony.setDiagnosticsEnabled(settings.developerModeEnabled)
        let manager = HeadphoneManager(providers: [bowersWilkins, sony])
        let batteryHistory = BatteryHistoryStore(providers: [bowersWilkins, sony])
        manager.installAudioDeviceDiscovery(systemAudio: systemAudio)
        manager.installVolumeSynchronization(settings: settings, systemAudio: systemAudio)

        _manager = StateObject(wrappedValue: manager)
        _bowersWilkins = StateObject(wrappedValue: bowersWilkins)
        _sony = StateObject(wrappedValue: sony)
        _systemAudio = StateObject(wrappedValue: systemAudio)
        _settings = StateObject(wrappedValue: settings)
        _updates = StateObject(wrappedValue: updates)
        _batteryHistory = StateObject(wrappedValue: batteryHistory)
        ControlCenterCommandBridge.shared.install(
            headphones: manager,
            systemAudio: systemAudio
        )
        appDelegate.shutdownHandler = { [weak manager, weak systemAudio] in
            manager?.shutdown()
            systemAudio?.shutdown()
        }
    }

    var body: some Scene {
        WindowGroup("HeadBridge", id: "settings") {
            ContentView()
                .environmentObject(manager)
                .environmentObject(bowersWilkins)
                .environmentObject(sony)
                .environmentObject(systemAudio)
                .environmentObject(settings)
                .environmentObject(updates)
                .environmentObject(batteryHistory)
                .frame(
                    minWidth: 680,
                    idealWidth: 760,
                    maxWidth: .infinity,
                    minHeight: 520,
                    idealHeight: 760,
                    maxHeight: .infinity
                )
        }
        .defaultSize(width: 760, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updates.checkForUpdates()
                }
            }
        }

        MenuBarExtra {
            MenuPopoverView()
                .environmentObject(manager)
                .environmentObject(bowersWilkins)
                .environmentObject(sony)
                .environmentObject(systemAudio)
                .environmentObject(settings)
                .environmentObject(updates)
                .environmentObject(batteryHistory)
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.window)
    }

    @ViewBuilder
    private var menuBarLabel: some View {
        // `Label` inherits the menu-bar's icon-only style on recent macOS
        // versions, so keep the icon and battery text as explicit siblings.
        HStack(spacing: 4) {
            Image(systemName: "headphones")
            if let text = menuBarStatusText {
                Text(text)
                    .monospacedDigit()
            }
        }
        .fixedSize(horizontal: true, vertical: true)
    }

    private var menuBarStatusText: String? {
        // Prefer the current CoreAudio output. During Bluetooth route changes
        // CoreAudio can briefly report another output even though a provider is
        // already ready, so fall back to the connected/connecting provider.
        let provider =
            manager.activeProvider(systemAudio: systemAudio)
            ?? manager.providers.first(where: {
                $0.connectionState == .ready || $0.connectionState.isConnecting
            })
        guard let provider else { return nil }
        if provider.connectionState.isConnecting {
            return "Connecting…"
        }
        guard provider.connectionState == .ready,
            settings.batteryDisplayMode.shouldDisplay(level: provider.batteryPercent),
            let battery = provider.batteryPercent
        else { return nil }
        return "\(battery)%"
    }
}
