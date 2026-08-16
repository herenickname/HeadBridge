import Combine
import Foundation
import OSLog

private struct SonyRestorableProfile: Codable, Equatable {
    var noiseMode: Int
    var ambientLevel: Int
    var equalizerPreset: UInt8?
    var equalizerBands: [Int]?
    var surroundMode: UInt8?
    var soundPosition: UInt8?
    var dseeEnabled: Bool?
    var soundQualityMode: UInt8?
    var touchSensorEnabled: Bool?
    var automaticPowerOff: String?
}

@MainActor
final class SonyMDRProvider: ObservableObject, HeadphoneProvider {
    let providerID = "sony-mdr"
    let vendorName = "Sony"
    let supportsSystemVolumeSynchronization = true
    let defaultSystemVolumeSynchronizationEnabled = true

    @Published private(set) var connectionState: HeadphoneConnectionState = .idle
    @Published private(set) var connectedName = "Sony MDR Headphones"
    @Published private(set) var batteryPercent: Int?
    @Published private(set) var isCharging: Bool?
    @Published private(set) var codecName: String?
    @Published private(set) var noiseMode: HeadphoneNoiseMode?
    @Published private(set) var capabilities: HeadphoneCapabilities = []
    @Published private(set) var ambientLevel = 20
    @Published private(set) var deviceVolume: Int?
    @Published private(set) var equalizerPreset: SonyV1EqualizerPreset?
    @Published private(set) var equalizerBands = Array(repeating: 0, count: 6)
    @Published private(set) var surroundMode: SonyV1SurroundMode?
    @Published private(set) var soundPosition: SonyV1SoundPosition?
    @Published private(set) var dseeEnabled: Bool?
    @Published private(set) var soundQualityMode: SonyV1SoundQualityMode?
    @Published private(set) var touchSensorEnabled: Bool?
    @Published private(set) var automaticPowerOff: SonyV1AutomaticPowerOff?
    @Published private(set) var optimizerStatus: SonyV1OptimizerStatus?
    @Published private(set) var atmosphericPressure: Double?
    @Published private(set) var devices: [BluetoothPairedDevice] = []
    @Published private(set) var restoreOnConnectEnabled = false
    @Published private(set) var log: [TransportLogEntry] = []

    var supportedNoiseModes: [HeadphoneNoiseMode] {
        var modes: [HeadphoneNoiseMode] = [.off]
        if capabilities.contains(.ambientLevel) { modes.append(.ambient) }
        if capabilities.contains(.windReduction) { modes.append(.windReduction) }
        if capabilities.contains(.noiseControl) { modes.append(.noiseCancellation) }
        return modes
    }

    var connectionStatePublisher: AnyPublisher<HeadphoneConnectionState, Never> {
        $connectionState.eraseToAnyPublisher()
    }

    var connectedDeviceID: String? { selectedAddress }

    private let client: SonyV1Client
    private var audioConnectedDeviceNames: [String] = []
    private var selectedAddress: String?
    private var pendingRestorableProfile: SonyRestorableProfile?
    private var isRefreshingDevices = false
    private var needsDeviceRefresh = false
    private var inventoryQuery: BluetoothInventoryQuery?
    private var inventoryGeneration = 0
    private var diagnosticsEnabled = false
    private let logger = Logger(subsystem: "io.github.herenickname.HeadBridge", category: "Sony")

    private static let deviceDiscoveryQueue = DispatchQueue(
        label: "io.github.herenickname.HeadBridge.sony-device-discovery",
        qos: .utility
    )

    init() {
        let client = SonyV1Client()
        self.client = client
        restoreOnConnectEnabled = HeadphoneProfileStore.isRestoreEnabled(for: "sony-mdr")

        client.onConnectionStateChange = { [weak self] state in
            self?.applyConnectionState(state)
        }
        client.onStateChange = { [weak self] state in
            self?.applyDeviceState(state)
        }
        client.onTransportLog = { [weak self] direction, text in
            self?.addLog(direction, text)
        }
    }

    func matches(audioDevice: SystemAudioDevice) -> Bool {
        Self.isSupportedHeadphoneName(audioDevice.name)
    }

    func recognizesBluetoothDevice(named name: String) -> Bool {
        Self.isSupportedHeadphoneName(name)
    }

    func updateBluetoothPairedDevices(_ devices: [BluetoothPairedDevice]) {
        let supported = devices.filter { Self.isSupportedHeadphoneName($0.name) }
        if self.devices != supported {
            self.devices = supported
        }
        connectToMatchingAudioDeviceIfNeeded()
    }

    func updateAudioConnectedDevices(_ devices: [SystemAudioDevice]) {
        let names =
            devices
            .filter(\.isBluetooth)
            .map(\.name)
            .filter(Self.isSupportedHeadphoneName)

        guard names != audioConnectedDeviceNames else { return }
        audioConnectedDeviceNames = names

        guard !names.isEmpty else {
            disconnect()
            return
        }
        refreshDevices()
    }

    func refresh() {
        if connectionState == .ready {
            client.refresh()
        }
        refreshDevices()
    }

    func refreshBatteryStatus() {
        guard connectionState == .ready else { return }
        client.refreshBattery()
    }

    func setDiagnosticsEnabled(_ enabled: Bool) {
        guard diagnosticsEnabled != enabled else { return }
        diagnosticsEnabled = enabled
        if enabled {
            addLog(
                .info,
                connectionState == .ready
                    ? "Protocol diagnostics enabled; refreshing current values"
                    : "Protocol diagnostics enabled; waiting for an RFCOMM connection"
            )
            if connectionState == .ready { client.refresh() }
        } else {
            log.removeAll()
        }
    }

    func refreshDevices() {
        guard !isRefreshingDevices else {
            needsDeviceRefresh = true
            return
        }
        isRefreshingDevices = true
        inventoryGeneration &+= 1
        let expectedGeneration = inventoryGeneration
        let query = BluetoothInventoryQuery()
        inventoryQuery = query

        // `IOBluetoothDevice.pairedDevices()` can block on macOS 26. Reading
        // the same inventory in a bounded child process keeps AppKit and the
        // menu-bar extra responsive.
        Self.deviceDiscoveryQueue.async {
            let discovered = Self.readBluetoothInventory(using: query)

            DispatchQueue.main.async { [weak self] in
                guard let self,
                    self.inventoryGeneration == expectedGeneration,
                    self.inventoryQuery === query
                else { return }
                self.inventoryQuery = nil
                self.isRefreshingDevices = false
                if let discovered {
                    self.devices = discovered
                }
                self.connectToMatchingAudioDeviceIfNeeded()

                if self.needsDeviceRefresh {
                    self.needsDeviceRefresh = false
                    self.refreshDevices()
                }
            }
        }
    }

    func connect(to device: BluetoothPairedDevice) {
        guard connectionState != .ready, !connectionState.isConnecting else { return }
        connectedName = device.name
        selectedAddress = device.address
        clearPublishedDeviceState()
        logger.info("Connecting the Swift Sony V1 client to \(device.name, privacy: .public)")
        client.connect(address: device.address, deviceName: device.name)
    }

    func disconnect() {
        cancelDeviceRefresh()
        selectedAddress = nil
        pendingRestorableProfile = nil
        client.disconnect()
        connectionState = .idle
        clearPublishedDeviceState()
    }

    func shutdown() {
        disconnect()
        client.onConnectionStateChange = nil
        client.onStateChange = nil
        client.onTransportLog = nil
    }

    func setNoiseMode(_ mode: HeadphoneNoiseMode) {
        guard supportedNoiseModes.contains(mode) else { return }
        var desired = desiredProfile()
        desired.noiseMode = mode.rawValue
        commitDesiredProfile(desired)
        let sonyMode: SonyV1NoiseMode =
            switch mode {
            case .off: .off
            case .noiseCancellation: .noiseCancellation
            case .ambient: .ambient
            case .windReduction: .windReduction
            }
        client.setNoiseMode(sonyMode, ambientLevel: desired.ambientLevel)
    }

    func setAmbientLevel(_ level: Int) {
        var desired = desiredProfile()
        desired.noiseMode = HeadphoneNoiseMode.ambient.rawValue
        desired.ambientLevel = min(20, max(1, level))
        commitDesiredProfile(desired)
        client.setAmbientLevel(desired.ambientLevel)
    }

    func setEqualizerPreset(_ preset: SonyV1EqualizerPreset) {
        var desired = desiredProfile()
        desired.equalizerPreset = preset.rawValue
        commitDesiredProfile(desired)
        equalizerPreset = preset
        client.setEqualizerPreset(preset)
    }

    func setEqualizerBand(at index: Int, value: Int) {
        guard equalizerBands.indices.contains(index) else { return }
        var values = equalizerBands
        values[index] = min(10, max(-10, value))
        equalizerBands = values
        equalizerPreset = .manual

        var desired = desiredProfile()
        desired.equalizerPreset = SonyV1EqualizerPreset.manual.rawValue
        desired.equalizerBands = values
        commitDesiredProfile(desired)
        client.setEqualizerBands(values)
    }

    func setSurroundMode(_ mode: SonyV1SurroundMode) {
        var desired = desiredProfile()
        desired.surroundMode = mode.rawValue
        commitDesiredProfile(desired)
        surroundMode = mode
        client.setSurroundMode(mode)
    }

    func setSoundPosition(_ position: SonyV1SoundPosition) {
        var desired = desiredProfile()
        desired.soundPosition = position.rawValue
        commitDesiredProfile(desired)
        soundPosition = position
        client.setSoundPosition(position)
    }

    func setDSEEEnabled(_ enabled: Bool) {
        var desired = desiredProfile()
        desired.dseeEnabled = enabled
        commitDesiredProfile(desired)
        dseeEnabled = enabled
        client.setDSEE(enabled: enabled)
    }

    func setSoundQualityMode(_ mode: SonyV1SoundQualityMode) {
        var desired = desiredProfile()
        desired.soundQualityMode = mode.rawValue
        commitDesiredProfile(desired)
        soundQualityMode = mode
        client.setSoundQualityMode(mode)
    }

    func setTouchSensorEnabled(_ enabled: Bool) {
        var desired = desiredProfile()
        desired.touchSensorEnabled = enabled
        commitDesiredProfile(desired)
        touchSensorEnabled = enabled
        client.setTouchSensor(enabled: enabled)
    }

    func setAutomaticPowerOff(_ mode: SonyV1AutomaticPowerOff) {
        var desired = desiredProfile()
        desired.automaticPowerOff = mode.rawValue
        commitDesiredProfile(desired)
        automaticPowerOff = mode
        client.setAutomaticPowerOff(mode)
    }

    func setOptimizerRunning(_ running: Bool) {
        optimizerStatus = running ? .wearingCondition : .notRunning
        client.setOptimizerRunning(running)
    }

    func setRestoreOnConnectEnabled(_ enabled: Bool) {
        guard restoreOnConnectEnabled != enabled else { return }
        restoreOnConnectEnabled = enabled
        HeadphoneProfileStore.setRestoreEnabled(enabled, for: providerID)

        if enabled,
            connectionState == .ready,
            savedProfile() == nil
        {
            saveProfile(currentProfile())
        }
    }

    func setDeviceVolume(normalized: Float) {
        client.setVolume(Self.volumeStep(for: normalized))
    }

    private func connectToMatchingAudioDeviceIfNeeded() {
        guard connectionState != .ready,
            !connectionState.isConnecting,
            let device = Self.automaticConnectionCandidate(
                from: devices,
                coreAudioDeviceNames: audioConnectedDeviceNames
            )
        else { return }
        connect(to: device)
    }

    static func automaticConnectionCandidate(
        from devices: [BluetoothPairedDevice],
        coreAudioDeviceNames: [String]
    ) -> BluetoothPairedDevice? {
        devices.first { candidate in
            guard candidate.isAudioConnected else { return false }
            return coreAudioDeviceNames.isEmpty
                || coreAudioDeviceNames.contains {
                    BluetoothDeviceNameMatcher.matches($0, candidate.name)
                }
        }
    }

    private func cancelDeviceRefresh() {
        inventoryGeneration &+= 1
        inventoryQuery?.cancel()
        inventoryQuery = nil
        isRefreshingDevices = false
        needsDeviceRefresh = false
    }

    private func applyConnectionState(_ state: SonyV1ClientConnectionState) {
        addLog(.info, "Sony control connection: \(String(describing: state))")
        switch state {
        case .disconnected:
            connectionState = .idle
            selectedAddress = nil
            pendingRestorableProfile = nil
            clearPublishedDeviceState()

        case .connecting:
            connectionState = .connecting

        case .ready:
            connectionState = .ready
            applyDeviceState(client.state)
            restoreProfileAfterConnect()
            logger.info("Sony MDR V1 protocol session is ready")

        case .failed(let message):
            connectionState = .failed(message)
            selectedAddress = nil
            pendingRestorableProfile = nil
            clearPublishedDeviceState()
            logger.error("Sony connection failed: \(message, privacy: .public)")
        }
    }

    private func applyDeviceState(_ state: SonyV1State) {
        if let modelName = state.modelName, !modelName.isEmpty {
            connectedName = modelName
        }
        batteryPercent = state.batteryPercent
        isCharging = state.isCharging
        codecName = state.codecName
        ambientLevel = state.ambientLevel
        deviceVolume = state.volume
        equalizerPreset = state.equalizerPreset
        equalizerBands = state.equalizerBands
        surroundMode = state.surroundMode
        soundPosition = state.soundPosition
        dseeEnabled = state.dseeEnabled
        soundQualityMode = state.soundQualityMode
        touchSensorEnabled = state.touchSensorEnabled
        automaticPowerOff = state.automaticPowerOff
        optimizerStatus = state.optimizerStatus
        atmosphericPressure = state.atmosphericPressure
        noiseMode =
            switch state.noiseMode {
            case .off: .off
            case .noiseCancellation: .noiseCancellation
            case .ambient: .ambient
            case .windReduction: .windReduction
            case nil: nil
            }
        capabilities = discoveredCapabilities(from: state)

        if let pendingRestorableProfile,
            profileMatchesState(pendingRestorableProfile, state: state)
        {
            saveProfile(pendingRestorableProfile)
            self.pendingRestorableProfile = nil
        }
    }

    private func discoveredCapabilities(from state: SonyV1State) -> HeadphoneCapabilities {
        var result: HeadphoneCapabilities = []
        if state.batteryPercent != nil { result.insert(.battery) }
        if state.noiseMode != nil {
            result.formUnion([.noiseControl, .ambientLevel])
        }
        if state.windReductionSupported { result.insert(.windReduction) }
        if state.volume != nil { result.insert(.deviceVolume) }
        if state.equalizerPreset != nil { result.insert(.equalizer) }
        if state.surroundMode != nil { result.insert(.surroundSound) }
        if state.soundPosition != nil { result.insert(.soundPosition) }
        if state.dseeEnabled != nil { result.insert(.audioUpsampling) }
        if state.soundQualityMode != nil { result.insert(.soundQualityMode) }
        if state.touchSensorEnabled != nil { result.insert(.touchSensor) }
        if state.automaticPowerOff != nil { result.insert(.automaticPowerOff) }
        if state.optimizerStatus != nil || state.atmosphericPressure != nil {
            result.insert(.noiseOptimizer)
        }
        return result
    }

    private func clearPublishedDeviceState() {
        batteryPercent = nil
        isCharging = nil
        codecName = nil
        noiseMode = nil
        capabilities = []
        ambientLevel = 20
        deviceVolume = nil
        equalizerPreset = nil
        equalizerBands = Array(repeating: 0, count: 6)
        surroundMode = nil
        soundPosition = nil
        dseeEnabled = nil
        soundQualityMode = nil
        touchSensorEnabled = nil
        automaticPowerOff = nil
        optimizerStatus = nil
        atmosphericPressure = nil
    }

    private func addLog(_ direction: TransportLogEntry.Direction, _ text: String) {
        guard diagnosticsEnabled else { return }
        log.append(TransportLogEntry(time: Date(), direction: direction, text: text))
        if log.count > 300 { log.removeFirst(log.count - 300) }
    }

    private func restoreProfileAfterConnect() {
        guard restoreOnConnectEnabled else { return }
        guard let profile = savedProfile() else {
            saveProfile(currentProfile())
            return
        }
        guard !profileMatchesState(profile, state: client.state) else { return }
        pendingRestorableProfile = profile

        if let mode = HeadphoneNoiseMode(rawValue: profile.noiseMode) {
            let sonyMode: SonyV1NoiseMode =
                switch mode {
                case .off: .off
                case .noiseCancellation: .noiseCancellation
                case .ambient: .ambient
                case .windReduction: .windReduction
                }
            client.setNoiseMode(sonyMode, ambientLevel: profile.ambientLevel)
        }
        if let raw = profile.equalizerPreset,
            let preset = SonyV1EqualizerPreset(rawValue: raw)
        {
            client.setEqualizerPreset(preset)
            if preset.acceptsCustomBands, let bands = profile.equalizerBands {
                client.setEqualizerBands(bands)
            }
        }
        if let raw = profile.surroundMode,
            let mode = SonyV1SurroundMode(rawValue: raw)
        {
            client.setSurroundMode(mode)
        }
        if let raw = profile.soundPosition,
            let position = SonyV1SoundPosition(rawValue: raw)
        {
            client.setSoundPosition(position)
        }
        if let enabled = profile.dseeEnabled { client.setDSEE(enabled: enabled) }
        if let enabled = profile.touchSensorEnabled { client.setTouchSensor(enabled: enabled) }
        if let raw = profile.automaticPowerOff,
            let mode = SonyV1AutomaticPowerOff(rawValue: raw)
        {
            client.setAutomaticPowerOff(mode)
        }
        // This may reconnect A2DP, so keep it last in the restore sequence.
        if let raw = profile.soundQualityMode,
            let mode = SonyV1SoundQualityMode(rawValue: raw)
        {
            client.setSoundQualityMode(mode)
        }
        logger.info("Restoring saved Sony settings after connect")
    }

    private func currentProfile() -> SonyRestorableProfile {
        return SonyRestorableProfile(
            noiseMode: (noiseMode ?? .off).rawValue,
            ambientLevel: min(20, max(1, ambientLevel)),
            equalizerPreset: equalizerPreset?.rawValue,
            equalizerBands: equalizerBands,
            surroundMode: surroundMode?.rawValue,
            soundPosition: soundPosition?.rawValue,
            dseeEnabled: dseeEnabled,
            soundQualityMode: soundQualityMode?.rawValue,
            touchSensorEnabled: touchSensorEnabled,
            automaticPowerOff: automaticPowerOff?.rawValue
        )
    }

    private func desiredProfile() -> SonyRestorableProfile {
        let current = currentProfile()
        guard let saved = savedProfile() else { return current }
        return SonyRestorableProfile(
            noiseMode: noiseMode?.rawValue ?? saved.noiseMode,
            ambientLevel: noiseMode == nil ? saved.ambientLevel : current.ambientLevel,
            equalizerPreset: current.equalizerPreset ?? saved.equalizerPreset,
            equalizerBands: equalizerPreset == nil ? saved.equalizerBands : current.equalizerBands,
            surroundMode: current.surroundMode ?? saved.surroundMode,
            soundPosition: current.soundPosition ?? saved.soundPosition,
            dseeEnabled: current.dseeEnabled ?? saved.dseeEnabled,
            soundQualityMode: current.soundQualityMode ?? saved.soundQualityMode,
            touchSensorEnabled: current.touchSensorEnabled ?? saved.touchSensorEnabled,
            automaticPowerOff: current.automaticPowerOff ?? saved.automaticPowerOff
        )
    }

    private func commitDesiredProfile(_ profile: SonyRestorableProfile) {
        pendingRestorableProfile = profile
        saveProfile(profile)
    }

    private func savedProfile() -> SonyRestorableProfile? {
        guard let deviceID = selectedAddress else { return nil }
        return HeadphoneProfileStore.load(
            SonyRestorableProfile.self,
            providerID: providerID,
            deviceID: deviceID
        )
    }

    private func saveProfile(_ profile: SonyRestorableProfile) {
        guard let deviceID = selectedAddress else { return }
        HeadphoneProfileStore.save(profile, providerID: providerID, deviceID: deviceID)
    }

    private func profileMatchesState(_ profile: SonyRestorableProfile, state: SonyV1State) -> Bool {
        let modeMatches: Bool =
            switch (profile.noiseMode, state.noiseMode) {
            case (HeadphoneNoiseMode.off.rawValue, .off),
                (HeadphoneNoiseMode.noiseCancellation.rawValue, .noiseCancellation),
                (HeadphoneNoiseMode.ambient.rawValue, .ambient),
                (HeadphoneNoiseMode.windReduction.rawValue, .windReduction):
                true
            default: false
            }
        guard modeMatches else { return false }
        guard state.noiseMode != .ambient || state.ambientLevel == profile.ambientLevel else { return false }
        if let raw = profile.equalizerPreset,
            state.equalizerPreset?.rawValue != raw
        {
            return false
        }
        if let bands = profile.equalizerBands,
            profile.equalizerPreset.flatMap(SonyV1EqualizerPreset.init(rawValue:))?.acceptsCustomBands == true,
            state.equalizerBands != bands
        {
            return false
        }
        if let raw = profile.surroundMode,
            state.surroundMode?.rawValue != raw
        {
            return false
        }
        if let raw = profile.soundPosition,
            state.soundPosition?.rawValue != raw
        {
            return false
        }
        if let enabled = profile.dseeEnabled,
            state.dseeEnabled != enabled
        {
            return false
        }
        if let raw = profile.soundQualityMode,
            state.soundQualityMode?.rawValue != raw
        {
            return false
        }
        if let enabled = profile.touchSensorEnabled,
            state.touchSensorEnabled != enabled
        {
            return false
        }
        if let raw = profile.automaticPowerOff,
            state.automaticPowerOff?.rawValue != raw
        {
            return false
        }
        return true
    }

    private nonisolated static func readBluetoothInventory(
        using query: BluetoothInventoryQuery
    ) -> [BluetoothPairedDevice]? {
        guard let data = query.run(),
            let devices = BluetoothDeviceInventory.decode(data)
        else { return nil }
        return devices.filter { isSupportedHeadphoneName($0.name) }
    }

    static func volumeStep(for normalized: Float) -> Int {
        min(30, max(0, Int((normalized * 30).rounded())))
    }

    nonisolated static func isSupportedHeadphoneName(_ name: String) -> Bool {
        let normalized = name.lowercased()
        let sonyModelFamilies = [
            "wh-", "wf-", "wi-", "mdr-", "linkbuds", "ult wear", "ultwear",
        ]
        return sonyModelFamilies.contains(where: normalized.contains)
            || normalized.contains("sony") && (normalized.contains("headphone") || normalized.contains("headset"))
    }

}
