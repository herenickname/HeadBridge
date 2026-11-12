import Combine
import Foundation
import OSLog

private struct HatorRestoreProfile: Codable {
    var spatial: Bool?
    var rgb: Bool?
    var microphoneMuted: Bool?

    var isEmpty: Bool {
        spatial == nil && rgb == nil && microphoneMuted == nil
    }
}

/// One physical headset and one BLE control session, regardless of the audio route.
@MainActor
final class HatorProvider: ObservableObject, HeadphoneProvider {
    let providerID = "hator-phoenix"
    let vendorName = "HATOR"

    @Published private(set) var connectionState: HeadphoneConnectionState = .idle
    @Published private(set) var connectedName = "HATOR PHOENIX 2"
    @Published private(set) var batteryPercent: Int?
    @Published private(set) var isCharging: Bool?
    @Published private(set) var codecName: String?
    @Published private(set) var noiseMode: HeadphoneNoiseMode?
    @Published private(set) var capabilities: HeadphoneCapabilities = []
    @Published private(set) var spatialEnabled: Bool?
    @Published private(set) var rgbEnabled: Bool?
    @Published private(set) var microphoneMuted: Bool?
    @Published private(set) var audioRoute: HatorAudioRoute = .none
    @Published private(set) var restoreOnConnectEnabled = false

    var connectedDeviceID: String? { deviceUUID?.uuidString }
    var supportedNoiseModes: [HeadphoneNoiseMode] { [] }
    var connectionStatePublisher: AnyPublisher<HeadphoneConnectionState, Never> {
        $connectionState.eraseToAnyPublisher()
    }

    private let client = HatorBLEClient()
    private let logger = Logger(subsystem: "io.github.herenickname.HeadBridge", category: "Hator")
    private var hasAudioOutput = false
    private var hasPairedBluetoothDevice = false
    private var deviceUUID: UUID?
    private var hardwareCapabilities: HeadphoneCapabilities = []
    private var storedProfile: HatorRestoreProfile = .init()
    private var pendingRestoreCodes: Set<UInt8> = []

    init() {
        restoreOnConnectEnabled = HeadphoneProfileStore.isRestoreEnabled(for: providerID)
        client.onConnection = { [weak self] state in
            Task { @MainActor [weak self] in self?.applyConnection(state) }
        }
        client.onSnapshot = { [weak self] snapshot in
            Task { @MainActor [weak self] in self?.applySnapshot(snapshot) }
        }
        client.onVerifiedWrite = { [weak self] code, value, verified in
            Task { @MainActor [weak self] in self?.didVerifyWrite(code: code, value: value, verified: verified) }
        }
    }

    static func recognizesName(_ name: String) -> Bool {
        BluetoothDeviceNameMatcher.normalized(name) == "hatorphoenix2"
    }

    func recognizesBluetoothDevice(named name: String) -> Bool {
        Self.recognizesName(name)
    }

    func matches(audioDevice: SystemAudioDevice) -> Bool {
        HatorAudioRoute.forDevice(audioDevice) != .none
    }

    func recognizesExternalAudioDevice(_ device: SystemAudioDevice) -> Bool {
        HatorAudioRoute.forDevice(device) == .usbDongle
    }

    func updateBluetoothPairedDevices(_ devices: [BluetoothPairedDevice]) {
        let paired = devices.contains(where: { Self.recognizesName($0.name) })
        guard paired != hasPairedBluetoothDevice else { return }
        hasPairedBluetoothDevice = paired
        updateTransportAvailability()
    }

    func updateAudioConnectedDevices(_ devices: [SystemAudioDevice]) {
        let nowPresent = devices.contains(where: matches(audioDevice:))
        guard nowPresent != hasAudioOutput else { return }
        hasAudioOutput = nowPresent
        updateTransportAvailability()
    }

    func updateActiveAudioDevice(_ device: SystemAudioDevice?) {
        let next = device.map(HatorAudioRoute.forDevice) ?? .none
        guard next != audioRoute else { return }
        audioRoute = next
        client.spatialWritesAllowed = next == .bluetooth
        if next != .bluetooth { client.cancelQueuedVendor(0x02) }
        updateEffectiveCapabilities()
        if next == .bluetooth, connectionState == .ready, restoreOnConnectEnabled,
            let spatial = storedProfile.spatial, spatialEnabled != nil
        {
            pendingRestoreCodes.insert(0x02)
            setSpatialAudio(spatial)
        }
        // No new BLE session is created during an audio route switch.
    }

    private func updateTransportAvailability() {
        logger.notice("Control availability audio=\(self.hasAudioOutput) paired=\(self.hasPairedBluetoothDevice)")
        if hasAudioOutput && hasPairedBluetoothDevice {
            client.start()
        } else {
            client.stop()
            clearState()
        }
    }

    func refresh() {
        if hasAudioOutput && hasPairedBluetoothDevice {
            client.start()
            client.refresh()
        }
    }

    func refreshBatteryStatus() {
        guard connectionState == .ready else { return }
        client.refresh()
    }

    func disconnect() {
        client.stop()
        clearState()
    }

    func shutdown() {
        client.shutdown()
        client.onConnection = nil
        client.onSnapshot = nil
        client.onVerifiedWrite = nil
        clearState()
    }

    /// ANC is currently read-only: no independently verified setter is implemented.
    func setNoiseMode(_ mode: HeadphoneNoiseMode) {}

    func setDeviceVolume(normalized: Float) {}

    func setRestoreOnConnectEnabled(_ enabled: Bool) {
        restoreOnConnectEnabled = enabled
        HeadphoneProfileStore.setRestoreEnabled(enabled, for: providerID)
    }

    func setSpatialAudio(_ enabled: Bool) {
        guard connectionState == .ready, audioRoute == .bluetooth,
            capabilities.contains(.spatialAudio), spatialEnabled != nil
        else { return }
        client.setVendor(0x02, value: enabled ? 2 : 0)
    }

    func setRGB(_ enabled: Bool) {
        logger.notice("RGB UI request target=\(enabled) ready=\(self.connectionState == .ready)")
        guard connectionState == .ready, rgbEnabled != nil else { return }
        client.setVendor(0x05, value: enabled ? 1 : 0)
    }

    func setMicrophoneMuted(_ enabled: Bool) {
        guard connectionState == .ready, microphoneMuted != nil else { return }
        client.setVendor(0x08, value: enabled ? 1 : 0)
    }

    private func applyConnection(_ state: HeadphoneConnectionState) {
        logger.notice("BLE connection state: \(state.title, privacy: .public)")
        guard hasAudioOutput else { return }
        connectionState = state
        if state != .ready {
            clearPublishedValues()
            return
        }
        deviceUUID = client.connectedIdentifier
        if let connectedDeviceID {
            storedProfile =
                HeadphoneProfileStore.load(
                    HatorRestoreProfile.self, providerID: providerID, deviceID: connectedDeviceID
                ) ?? .init()
        }
        if restoreOnConnectEnabled, !storedProfile.isEmpty {
            if audioRoute == .bluetooth, let spatial = storedProfile.spatial, spatialEnabled != nil {
                pendingRestoreCodes.insert(0x02)
                setSpatialAudio(spatial)
            }
            if let rgb = storedProfile.rgb, rgbEnabled != nil {
                pendingRestoreCodes.insert(0x05)
                setRGB(rgb)
            }
            if let mute = storedProfile.microphoneMuted, microphoneMuted != nil {
                pendingRestoreCodes.insert(0x08)
                setMicrophoneMuted(mute)
            }
        }
    }

    private func applySnapshot(_ snapshot: HatorDeviceSnapshot) {
        guard hasAudioOutput, client.connectedIdentifier != nil else { return }
        batteryPercent = snapshot.batteryPercent
        noiseMode = snapshot.noiseMode
        spatialEnabled = snapshot.vendorBool(0x02)
        rgbEnabled = snapshot.vendorBool(0x05)
        microphoneMuted = snapshot.vendorBool(0x08)
        hardwareCapabilities = []
        if batteryPercent != nil { hardwareCapabilities.insert(.battery) }
        if spatialEnabled != nil { hardwareCapabilities.insert(.spatialAudio) }
        updateEffectiveCapabilities()
        logger.notice(
            "BLE state read batteryAvailable=\(self.batteryPercent != nil) spatialAvailable=\(self.spatialEnabled != nil) rgb=\(String(describing: self.rgbEnabled), privacy: .public) micAvailable=\(self.microphoneMuted != nil)"
        )
    }

    private func didVerifyWrite(code: UInt8, value: UInt8, verified: Bool) {
        logger.notice("BLE write verification code=\(code) value=\(value) confirmed=\(verified)")
        let wasRestore = pendingRestoreCodes.remove(code) != nil
        guard verified, !wasRestore, let connectedDeviceID else { return }
        switch code {
        case 0x02: storedProfile.spatial = value == 2
        case 0x05: storedProfile.rgb = value == 1
        case 0x08: storedProfile.microphoneMuted = value == 1
        default: return
        }
        HeadphoneProfileStore.save(storedProfile, providerID: providerID, deviceID: connectedDeviceID)
    }

    private func updateEffectiveCapabilities() {
        capabilities = HatorAudioRoute.effectiveCapabilities(hardwareCapabilities, route: audioRoute)
    }

    private func clearPublishedValues() {
        batteryPercent = nil
        isCharging = nil
        codecName = nil
        noiseMode = nil
        spatialEnabled = nil
        rgbEnabled = nil
        microphoneMuted = nil
        hardwareCapabilities = []
        capabilities = []
        deviceUUID = nil
        pendingRestoreCodes.removeAll()
    }

    private func clearState() {
        connectionState = .idle
        clearPublishedValues()
        storedProfile = .init()
    }
}
