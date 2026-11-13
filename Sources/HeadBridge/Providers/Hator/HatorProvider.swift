import Combine
import CoreAudio
import Foundation
import OSLog

/// Watches the selected Core Audio output without accessing audio samples.
/// The global scope is required for DeviceIsRunningSomewhere notifications.
@MainActor
private final class HatorPlaybackActivityMonitor {
    var onChange: ((Bool) -> Void)?

    private var deviceID: AudioDeviceID?
    private var listener: AudioObjectPropertyListenerBlock?

    func observe(deviceID nextID: AudioDeviceID?) {
        guard nextID != deviceID else { return }
        stop()
        guard let nextID else { return }

        var address = Self.propertyAddress()
        guard AudioObjectHasProperty(nextID, &address) else { return }
        let callback: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        guard AudioObjectAddPropertyListenerBlock(nextID, &address, .main, callback) == noErr else { return }
        deviceID = nextID
        listener = callback
        refresh()
    }

    func stop() {
        if let deviceID, let listener {
            var address = Self.propertyAddress()
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, .main, listener)
        }
        deviceID = nil
        listener = nil
        onChange?(false)
    }

    func refresh() {
        guard let deviceID else { return }
        var address = Self.propertyAddress()
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let success = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &isRunning) == noErr
        onChange?(success && isRunning != 0)
    }

    private static func propertyAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}

private struct HatorRestoreProfile: Codable {
    var spatial: Bool?
    var rgb: Bool?
    var microphoneMuted: Bool?
    var noiseMode: Int?
    var equalizerPreset: UInt8?
    var customEqualizer: [Int]?

    var isEmpty: Bool {
        spatial == nil && rgb == nil && microphoneMuted == nil
            && noiseMode == nil && equalizerPreset == nil && customEqualizer == nil
    }
}

/// Last user intent is shown immediately, independently of RCSP readback.
/// Rapid taps coalesce to one latest target while at most one command is in flight.
struct HatorSpatialSwitchState: Equatable {
    enum Completion: Equatable {
        case stale
        case settled
        case failed
        case send(Bool)
    }

    private(set) var confirmed: Bool?
    private(set) var requested: Bool?
    private(set) var inFlight: Bool?

    var displayed: Bool? { requested ?? confirmed }
    var isPending: Bool { requested != nil }

    mutating func receiveDevice(_ value: Bool?) {
        if let value { confirmed = value }
    }

    /// Accepts another click even while a previous BLE command is pending.
    mutating func select(_ value: Bool) -> Bool {
        guard confirmed != nil, displayed != value else { return false }
        requested = value
        return true
    }

    /// Starts only the latest requested value once the audio stream is ready.
    /// If the user reverted before anything was sent, no BLE write is needed.
    mutating func beginWrite() -> Bool? {
        guard inFlight == nil, let requested else { return nil }
        guard requested != confirmed else {
            self.requested = nil
            return nil
        }
        inFlight = requested
        return requested
    }

    /// Completes the actual command, not necessarily the latest UI intent.
    /// A changed intent is reconciled with at most one more write.
    mutating func completeWrite(
        sent: Bool, verified: Bool, readback: Bool?
    ) -> Completion {
        guard inFlight == sent else { return .stale }
        inFlight = nil
        if let readback { confirmed = readback } else if verified { confirmed = sent }

        guard let requested else { return .stale }
        if requested != sent {
            // The user changed their mind while the first command was running.
            // An unknown readback cannot prove that reverting needs no write.
            if let readback, requested == readback {
                self.requested = nil
                return .settled
            }
            inFlight = requested
            return .send(requested)
        }

        self.requested = nil
        return verified ? .settled : .failed
    }

    mutating func cancel() {
        requested = nil
        inFlight = nil
    }

    mutating func reset() {
        confirmed = nil
        cancel()
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
    @Published private(set) var supportedNoiseModes: [HeadphoneNoiseMode] = []
    @Published private(set) var equalizer: HatorEqualizerState?
    @Published private(set) var equalizerPresets: [HatorEqualizerPreset] = []
    @Published private(set) var deviceVolumeRaw: Int?
    @Published private(set) var capabilities: HeadphoneCapabilities = []
    @Published private var spatialState = HatorSpatialSwitchState()

    /// The switch immediately displays the requested value; confirmation and
    /// rollback are handled independently of periodic BLE snapshots.
    var spatialEnabled: Bool? { spatialState.displayed }
    var spatialUpdatePending: Bool { spatialState.isPending }
    var canChangeSpatialAudio: Bool {
        connectionState == .ready && audioRoute == .bluetooth
            && capabilities.contains(.spatialAudio) && spatialState.confirmed != nil
    }
    @Published private(set) var spatialControlError: String?
    @Published private(set) var rgbEnabled: Bool?
    @Published private(set) var microphoneMuted: Bool?
    @Published private(set) var audioRoute: HatorAudioRoute = .none
    @Published private(set) var confirmedRadioMode: HatorRadioMode?
    @Published private(set) var requestedRadioMode: HatorRadioMode?
    @Published private(set) var radioSwitchError: String?
    @Published private(set) var restoreOnConnectEnabled = false

    var displayedRadioMode: HatorRadioMode? { requestedRadioMode ?? confirmedRadioMode }
    var canChangeRadioMode: Bool {
        connectionState == .ready && confirmedRadioMode != nil && requestedRadioMode == nil
    }

    func isRadioModeAvailable(_ mode: HatorRadioMode) -> Bool {
        guard let systemAudio else { return false }
        return mode.isAvailable(with: systemAudio.devices)
    }

    var connectedDeviceID: String? { deviceUUID?.uuidString }
    var connectionStatePublisher: AnyPublisher<HeadphoneConnectionState, Never> {
        $connectionState.eraseToAnyPublisher()
    }

    private let client = HatorBLEClient()
    private let playbackMonitor = HatorPlaybackActivityMonitor()
    private let silentAudio = HatorSilentAudioStream()
    private var bluetoothAudioPlaying = false
    private weak var systemAudio: SystemAudioController?
    private var audioHandoffSubscription: AnyCancellable?
    private struct RadioHandoff {
        let target: HatorRadioMode
        let originalOutputUID: String?
        let startedWithHator: Bool
        var verified = false
        var verifiedAt: Date?
        var reconnectObserved = false
    }
    private var radioHandoff: RadioHandoff?
    private var radioSwitchGeneration = 0
    private var bluetoothOutputUID: String?
    private var waitingForSilentPlayback = false
    private var spatialOperationGeneration = 0
    private var spatialTimeoutRevision = 0
    private let logger = Logger(subsystem: "io.github.herenickname.HeadBridge", category: "Hator")
    private var hasAudioOutput = false
    private var hasPairedBluetoothDevice = false
    private var deviceUUID: UUID?
    private var hardwareCapabilities: HeadphoneCapabilities = []
    private var storedProfile: HatorRestoreProfile = .init()
    private var pendingRestoreCodes: Set<UInt8> = []
    private var pendingRestoreSystem: Set<UInt8> = []

    init() {
        restoreOnConnectEnabled = HeadphoneProfileStore.isRestoreEnabled(for: providerID)
        playbackMonitor.onChange = { [weak self] isRunning in
            guard let self else { return }
            if self.bluetoothAudioPlaying != isRunning { self.bluetoothAudioPlaying = isRunning }
            if isRunning, self.waitingForSilentPlayback {
                self.waitingForSilentPlayback = false
                if self.spatialState.inFlight != nil {
                    self.transmitInFlightSpatialAudio()
                } else {
                    self.sendSpatialAudio()
                }
            } else if !isRunning, self.spatialUpdatePending,
                !self.waitingForSilentPlayback, !self.silentAudio.isRunning,
                let bluetoothOutputUID = self.bluetoothOutputUID
            {
                // The user may pause the player while RCSP readback is still
                // pending. Keep the Bluetooth audio path open until completion.
                if !self.silentAudio.start(deviceUID: bluetoothOutputUID) {
                    self.logger.warning("Unable to maintain silent output during Spatial update")
                }
            }
        }
        client.onConnection = { [weak self] state in
            Task { @MainActor [weak self] in self?.applyConnection(state) }
        }
        client.onSnapshot = { [weak self] snapshot in
            Task { @MainActor [weak self] in self?.applySnapshot(snapshot) }
        }
        client.onVerifiedWrite = { [weak self] code, value, verified, readback in
            Task { @MainActor [weak self] in
                self?.didVerifyWrite(code: code, value: value, verified: verified, readback: readback)
            }
        }
        client.onVerifiedSystemWrite = { [weak self] command, verified in
            Task { @MainActor [weak self] in self?.didVerifySystemWrite(command, verified: verified) }
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
        let route = HatorAudioRoute.forDevice(device)
        return route == .usbDongle || route == .wiredUSB
    }

    func updateBluetoothPairedDevices(_ devices: [BluetoothPairedDevice]) {
        let paired = devices.contains(where: { Self.recognizesName($0.name) })
        guard paired != hasPairedBluetoothDevice else { return }
        hasPairedBluetoothDevice = paired
        updateTransportAvailability()
    }

    func installAudioHandoff(systemAudio: SystemAudioController) {
        self.systemAudio = systemAudio
        audioHandoffSubscription = systemAudio.$devices
            .combineLatest(systemAudio.$defaultDeviceID)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                self?.reconcileRadioAudioHandoff()
            }
    }

    func updateAudioConnectedDevices(_ devices: [SystemAudioDevice]) {
        let nowPresent = devices.contains(where: matches(audioDevice:))
        guard nowPresent != hasAudioOutput else { return }
        hasAudioOutput = nowPresent
        updateTransportAvailability()
    }

    func updateActiveAudioDevice(_ device: SystemAudioDevice?) {
        let next = device.map(HatorAudioRoute.forDevice) ?? .none
        let nextUID = next == .bluetooth ? device?.uid : nil
        if next != audioRoute || nextUID != bluetoothOutputUID {
            cancelSpatialAudioOperation()
            spatialControlError = nil
        }
        bluetoothOutputUID = nextUID
        playbackMonitor.observe(deviceID: next == .bluetooth ? device?.id : nil)
        guard next != audioRoute else { return }
        audioRoute = next
        client.spatialWritesAllowed = next == .bluetooth
        if next != .bluetooth { client.cancelQueuedVendor(0x02) }
        updateEffectiveCapabilities()
        if next == .bluetooth, connectionState == .ready, restoreOnConnectEnabled,
            let spatial = storedProfile.spatial, spatialState.confirmed != nil,
            spatialState.confirmed != spatial
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
        radioSwitchGeneration &+= 1
        radioHandoff = nil
        requestedRadioMode = nil
        audioHandoffSubscription?.cancel()
        audioHandoffSubscription = nil
        cancelSpatialAudioOperation()
        playbackMonitor.stop()
        client.shutdown()
        client.onConnection = nil
        client.onSnapshot = nil
        client.onVerifiedWrite = nil
        client.onVerifiedSystemWrite = nil
        clearState()
    }

    /// Request a hardware radio switch. This is independent of the macOS
    /// default output: only an in-app request may start an audio handoff.
    func setRadioMode(_ target: HatorRadioMode) {
        guard canChangeRadioMode, let confirmedRadioMode,
            let systemAudio
        else { return }
        guard confirmedRadioMode != target else { return }

        // It is possible to enter dongle mode without the receiver present,
        // but the Mac could then lose headset audio entirely.
        if !target.isAvailable(with: systemAudio.devices) {
            radioSwitchError = "Connect the 2.4 GHz USB dongle first."
            return
        }

        let previous = systemAudio.devices.first { $0.id == systemAudio.defaultDeviceID }
        radioHandoff = RadioHandoff(
            target: target,
            originalOutputUID: previous?.uid,
            startedWithHator: previous.map {
                HatorAudioRoute.forDevice($0).isWireless
            } ?? false
        )
        requestedRadioMode = target
        radioSwitchError = nil
        radioSwitchGeneration &+= 1
        let token = radioSwitchGeneration
        client.setVendor(0x07, value: target.rawValue)

        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.radioSwitchGeneration == token,
                self.requestedRadioMode != nil
            else { return }
            let message =
                self.radioHandoff?.verified == true
                ? "Wireless mode changed, but the requested macOS audio output did not appear."
                : "Wireless mode could not be confirmed. Check the headset before retrying."
            self.finishRadioSwitch(error: message)
        }
    }

    /// macOS may automatically redirect audio when an A2DP device disappears
    /// or reappears — even if the previous default was a Mac speaker. Guard
    /// the original non-HATOR selection and explicitly select the new HATOR
    /// endpoint only when HATOR had been the original output.
    private func reconcileRadioAudioHandoff() {
        guard var handoff = radioHandoff, handoff.verified,
            let systemAudio
        else { return }
        if handoff.startedWithHator,
            !systemAudio.devices.contains(where: {
                HatorAudioRoute.forDevice($0) == handoff.target.audioRoute
            })
        {
            return
        }

        if let desiredOutput = HatorAudioHandoffPolicy.preferredOutput(
            startedWithHator: handoff.startedWithHator,
            target: handoff.target,
            originalOutputUID: handoff.originalOutputUID,
            devices: systemAudio.devices,
            currentID: systemAudio.defaultDeviceID
        ) {
            systemAudio.select(desiredOutput)
            if handoff.startedWithHator { return }
        }

        if handoff.startedWithHator {
            finishRadioSwitch(error: nil)
        } else {
            // macOS can auto-select the reconnecting Bluetooth output
            // seconds after readback; keep guarding the earlier choice.
            if handoff.verifiedAt == nil {
                handoff.verifiedAt = Date()
                radioHandoff = handoff
                let token = radioSwitchGeneration
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                    guard let self, self.radioSwitchGeneration == token else { return }
                    self.reconcileRadioAudioHandoff()
                }
            } else if let verifiedAt = handoff.verifiedAt,
                Date().timeIntervalSince(verifiedAt) >= 5
            {
                finishRadioSwitch(error: nil)
            }
        }
    }

    private func finishRadioSwitch(error: String?) {
        radioSwitchGeneration &+= 1
        requestedRadioMode = nil
        radioHandoff = nil
        radioSwitchError = error
    }

    func setNoiseMode(_ mode: HeadphoneNoiseMode) {
        guard connectionState == .ready, capabilities.contains(.noiseControl),
            supportedNoiseModes.contains(mode), noiseMode != nil
        else { return }
        client.setSystem(.noise(mode))
    }

    func setEqualizerPreset(_ mode: UInt8) {
        guard connectionState == .ready, capabilities.contains(.equalizer),
            equalizerPresets.contains(where: { $0.id == mode })
        else { return }
        if mode == 8 {
            // A preset switch must not silently overwrite the saved Custom bands.
            guard let customPreset = equalizerPresets.first(where: { $0.id == 8 }) else { return }
            let gains = customPreset.gains
            guard gains.count == 10, gains.allSatisfy(HatorDSP.editableRange.contains) else { return }
            client.setSystem(.customEQ(gains))
        } else {
            client.setSystem(.preset(mode))
        }
    }

    func setCustomEqualizer(_ values: [Int]) {
        guard connectionState == .ready, capabilities.contains(.equalizer),
            equalizerPresets.contains(where: { $0.id == 8 }), values.count == 10,
            values.allSatisfy(HatorDSP.editableRange.contains)
        else { return }
        client.setSystem(.customEQ(values))
    }

    func setDeviceVolume(normalized: Float) {}

    func setRestoreOnConnectEnabled(_ enabled: Bool) {
        restoreOnConnectEnabled = enabled
        HeadphoneProfileStore.setRestoreEnabled(enabled, for: providerID)
    }

    func setSpatialAudio(_ enabled: Bool) {
        guard canChangeSpatialAudio, spatialState.select(enabled) else { return }
        // Accept every user intent immediately, even during a long RCSP
        // calibration/readback. Only the latest requested value is retained.
        spatialControlError = nil
        scheduleSpatialTimeout()

        // ON → OFF before the first BLE packet was sent requires no write.
        // Cancel the startup timer and release temporary playback immediately.
        if spatialState.inFlight == nil, spatialState.requested == spatialState.confirmed {
            finishSpatialAudioOperation(error: nil)
            return
        }

        // Keep one silent stream and one BLE transaction running until the
        // final requested value is confirmed. The current write must finish
        // before a newer target can be sent.
        if spatialState.inFlight != nil || waitingForSilentPlayback { return }

        spatialOperationGeneration &+= 1
        let token = spatialOperationGeneration
        if bluetoothAudioPlaying {
            sendSpatialAudio()
        } else {
            // Activate all-zero PCM on the explicit Bluetooth output, without
            // changing the Mac's default audio device.
            guard let bluetoothOutputUID, silentAudio.start(deviceUID: bluetoothOutputUID) else {
                finishSpatialAudioOperation(error: "Cannot start Bluetooth audio for Spatial Audio.")
                return
            }
            waitingForSilentPlayback = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, self.spatialOperationGeneration == token,
                    self.waitingForSilentPlayback
                else { return }
                self.playbackMonitor.refresh()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, self.spatialOperationGeneration == token,
                    self.waitingForSilentPlayback
                else { return }
                self.finishSpatialAudioOperation(error: "Bluetooth audio did not start.")
            }
        }
    }

    private func scheduleSpatialTimeout() {
        spatialTimeoutRevision &+= 1
        let revision = spatialTimeoutRevision
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.spatialTimeoutRevision == revision,
                self.spatialUpdatePending
            else { return }
            self.client.cancelQueuedVendor(0x02)
            self.finishSpatialAudioOperation(error: "Spatial Audio change timed out.")
        }
    }

    private func sendSpatialAudio() {
        guard audioRoute == .bluetooth, connectionState == .ready else {
            finishSpatialAudioOperation(error: nil)
            return
        }
        guard spatialState.beginWrite() != nil else {
            // The user may have switched ON and back OFF before audio began.
            if !spatialState.isPending { finishSpatialAudioOperation(error: nil) }
            return
        }
        transmitInFlightSpatialAudio()
    }

    private func transmitInFlightSpatialAudio() {
        guard let inFlight = spatialState.inFlight else { return }
        client.setVendor(0x02, value: inFlight ? 2 : 0)
    }

    private func startSilentAudioForSpatial() {
        // Keep the same queue between consecutive user intents and verified
        // writes. Do not change the system default output.
        guard let bluetoothOutputUID,
            silentAudio.isRunning || silentAudio.start(deviceUID: bluetoothOutputUID)
        else {
            finishSpatialAudioOperation(error: "Cannot start Bluetooth audio for Spatial Audio.")
            return
        }
        waitingForSilentPlayback = true
        let token = spatialOperationGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.spatialOperationGeneration == token,
                self.waitingForSilentPlayback
            else { return }
            self.playbackMonitor.refresh()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.spatialOperationGeneration == token,
                self.waitingForSilentPlayback
            else { return }
            self.finishSpatialAudioOperation(error: "Bluetooth audio did not start.")
        }
    }

    private func finishSpatialAudioOperation(error: String?) {
        if spatialState.isPending { spatialState.cancel() }
        if error != nil { pendingRestoreCodes.remove(0x02) }
        silentAudio.stop()
        waitingForSilentPlayback = false
        spatialOperationGeneration &+= 1
        spatialTimeoutRevision &+= 1
        spatialControlError = error
    }

    private func cancelSpatialAudioOperation() {
        guard spatialUpdatePending || silentAudio.isRunning || waitingForSilentPlayback else { return }
        if spatialUpdatePending { client.cancelQueuedVendor(0x02) }
        finishSpatialAudioOperation(error: nil)
    }

    func setRGB(_ enabled: Bool) {
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
            if radioHandoff != nil { radioHandoff?.reconnectObserved = true }
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
            if audioRoute == .bluetooth, let spatial = storedProfile.spatial,
                spatialState.confirmed != nil, spatialState.confirmed != spatial
            {
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
            if let raw = storedProfile.noiseMode, let mode = HeadphoneNoiseMode(rawValue: raw),
                supportedNoiseModes.contains(mode)
            {
                pendingRestoreSystem.insert(0x0D)
                setNoiseMode(mode)
            }
            if let mode = storedProfile.equalizerPreset, equalizer != nil,
                equalizerPresets.contains(where: { $0.id == mode })
            {
                if mode == 8, let values = storedProfile.customEqualizer {
                    pendingRestoreSystem.insert(0x04)
                    setCustomEqualizer(values)
                } else if mode != 8 {
                    pendingRestoreSystem.insert(0x04)
                    setEqualizerPreset(mode)
                }
            }
        }
    }

    private func applySnapshot(_ snapshot: HatorDeviceSnapshot) {
        guard hasAudioOutput, client.connectedIdentifier != nil else { return }
        batteryPercent = snapshot.batteryPercent
        noiseMode = snapshot.noiseMode
        supportedNoiseModes = snapshot.supportedNoiseModes
        equalizer = snapshot.equalizer
        equalizerPresets = snapshot.equalizerPresets
        deviceVolumeRaw = snapshot.rawVolume
        spatialState.receiveDevice(snapshot.vendorBool(0x02))
        if let raw = snapshot.vendor[0x07],
            let mode = HatorRadioMode(rawValue: raw)
        {
            confirmedRadioMode = mode
            // A completely new authenticated session supplies a fresh radio
            // readback even if the original SET callback was interrupted.
            if radioHandoff?.reconnectObserved == true, requestedRadioMode == mode {
                radioHandoff?.verified = true
                reconcileRadioAudioHandoff()
            }
        }
        rgbEnabled = snapshot.vendorBool(0x05)
        microphoneMuted = snapshot.vendorBool(0x08)
        hardwareCapabilities = []
        if batteryPercent != nil { hardwareCapabilities.insert(.battery) }
        if spatialEnabled != nil { hardwareCapabilities.insert(.spatialAudio) }
        if noiseMode != nil && !supportedNoiseModes.isEmpty { hardwareCapabilities.insert(.noiseControl) }
        if equalizer != nil && equalizerPresets.count == 9 { hardwareCapabilities.insert(.equalizer) }
        updateEffectiveCapabilities()
        logger.notice(
            "BLE state read batteryAvailable=\(self.batteryPercent != nil) spatialAvailable=\(self.spatialEnabled != nil) rgb=\(String(describing: self.rgbEnabled), privacy: .public) micAvailable=\(self.microphoneMuted != nil)"
        )
    }

    private func didVerifyWrite(
        code: UInt8, value: UInt8, verified: Bool, readback: UInt8?
    ) {
        logger.notice("BLE write verification code=\(code) value=\(value) confirmed=\(verified)")
        if code == 0x07 {
            guard let target = HatorRadioMode(rawValue: value),
                requestedRadioMode == target, radioHandoff != nil
            else { return }
            if verified {
                confirmedRadioMode = target
                radioHandoff?.verified = true
                reconcileRadioAudioHandoff()
            } else {
                finishRadioSwitch(
                    error: "Headset did not confirm the wireless mode change."
                )
            }
            return
        }
        if code == 0x02 {
            let actual = readback.flatMap { raw -> Bool? in
                switch raw {
                case 0: return false
                case 2: return true
                default: return nil
                }
            }
            let result = spatialState.completeWrite(
                sent: value == 2, verified: verified, readback: actual
            )
            switch result {
            case .stale:
                return
            case .send:
                // The user changed the toggle while this command was being
                // verified. Reuse the audio stream and send only the latest
                // target once Core Audio confirms playback is still active.
                playbackMonitor.refresh()
                if bluetoothAudioPlaying {
                    transmitInFlightSpatialAudio()
                } else {
                    startSilentAudioForSpatial()
                }
                return
            case .failed:
                finishSpatialAudioOperation(error: "Headset did not confirm the Spatial Audio change.")
                return
            case .settled:
                let wasRestore = pendingRestoreCodes.remove(0x02) != nil
                finishSpatialAudioOperation(error: nil)
                guard !wasRestore, let confirmed = spatialState.confirmed,
                    let connectedDeviceID
                else { return }
                storedProfile.spatial = confirmed
                HeadphoneProfileStore.save(
                    storedProfile, providerID: providerID, deviceID: connectedDeviceID
                )
                return
            }
        }

        let wasRestore = pendingRestoreCodes.remove(code) != nil
        guard verified, !wasRestore, let connectedDeviceID else { return }
        switch code {
        case 0x05: storedProfile.rgb = value == 1
        case 0x08: storedProfile.microphoneMuted = value == 1
        default: return
        }
        HeadphoneProfileStore.save(storedProfile, providerID: providerID, deviceID: connectedDeviceID)
    }

    private func didVerifySystemWrite(_ command: HatorSystemWrite, verified: Bool) {
        logger.notice("BLE system write verification type=\(command.key) confirmed=\(verified)")
        let wasRestore = pendingRestoreSystem.remove(command.key) != nil
        guard verified, !wasRestore, let connectedDeviceID else { return }
        switch command {
        case .noise(let mode): storedProfile.noiseMode = mode.rawValue
        case .preset(let mode):
            storedProfile.equalizerPreset = mode
        case .customEQ(let gains):
            storedProfile.equalizerPreset = 8
            storedProfile.customEqualizer = gains
        }
        HeadphoneProfileStore.save(storedProfile, providerID: providerID, deviceID: connectedDeviceID)
    }

    private func updateEffectiveCapabilities() {
        capabilities = HatorAudioRoute.effectiveCapabilities(hardwareCapabilities, route: audioRoute)
    }

    private func clearPublishedValues() {
        cancelSpatialAudioOperation()
        batteryPercent = nil
        isCharging = nil
        codecName = nil
        noiseMode = nil
        supportedNoiseModes = []
        equalizer = nil
        equalizerPresets = []
        deviceVolumeRaw = nil
        spatialState.reset()
        spatialControlError = nil
        rgbEnabled = nil
        microphoneMuted = nil
        confirmedRadioMode = nil
        hardwareCapabilities = []
        capabilities = []
        deviceUUID = nil
        pendingRestoreCodes.removeAll()
        pendingRestoreSystem.removeAll()
    }

    private func clearState() {
        radioSwitchGeneration &+= 1
        radioHandoff = nil
        requestedRadioMode = nil
        radioSwitchError = nil
        connectionState = .idle
        clearPublishedValues()
        storedProfile = .init()
    }
}
