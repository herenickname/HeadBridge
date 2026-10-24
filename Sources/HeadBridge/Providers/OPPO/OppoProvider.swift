import Combine
import Foundation

private struct OppoRestorableProfile: Codable, Equatable {
    var noiseMode: Int
}

@MainActor
final class OppoProvider: ObservableObject, HeadphoneProvider {
    let providerID = "oppo-enco"
    let vendorName = "OPPO"

    @Published private(set) var connectionState: HeadphoneConnectionState = .idle
    @Published private(set) var connectedName = "OPPO Enco"
    @Published private(set) var batteryPercent: Int?
    @Published private(set) var isCharging: Bool?
    @Published private(set) var codecName: String?
    @Published private(set) var noiseMode: HeadphoneNoiseMode?
    @Published private(set) var noiseLevel: OppoNoiseLevel?
    @Published private(set) var smartNoiseLevel: OppoNoiseLevel?
    @Published private(set) var holdCycleMask: UInt16 = 0
    @Published private(set) var capabilities: HeadphoneCapabilities = []
    @Published private(set) var restoreOnConnectEnabled = false

    @Published private(set) var leftBatteryPercent: Int?
    @Published private(set) var rightBatteryPercent: Int?
    @Published private(set) var caseBatteryPercent: Int?
    @Published private(set) var firmwareVersion: String?
    @Published private(set) var productID: UInt32?
    @Published private(set) var currentCodec: Int?
    @Published private(set) var featureStates: [UInt8: UInt8] = [:]
    @Published private(set) var spatialEnabled: Bool?
    @Published private(set) var spatialType: Int?
    @Published private(set) var gameModeEnabled: Bool?
    @Published private(set) var gameSound: OppoGameSoundState?
    @Published private(set) var eqCurrentID: UInt8?
    @Published private(set) var customEQPresets: [OppoEQPreset] = []
    @Published private(set) var wearing: OppoWearingState?
    @Published private(set) var wearingUpdatedAt: Date?
    @Published private(set) var dualDevices: [OppoDualDevice] = []
    @Published private(set) var preferredDeviceMAC: String?
    @Published private(set) var gestures: [OppoGestureBinding] = []
    @Published private(set) var alertVolume: Int?
    @Published private(set) var isRinging = false
    @Published private(set) var availableCodecs: [Int] = []

    var eqPresets: [OppoEQPreset] {
        let builtIns =
            profile?.builtInEQPresets.map {
                OppoEQPreset(id: $0.id, name: $0.name, isSelected: eqCurrentID == $0.id, bands: [])
            } ?? []
        let custom = customEQPresets.map {
            OppoEQPreset(id: $0.id, name: $0.name, isSelected: eqCurrentID == $0.id, bands: $0.bands)
        }
        return builtIns + custom
    }

    var spatialAudioSupported: Bool {
        profile != nil && featureStates[0x1B] != nil
    }

    var gameModeSupported: Bool {
        profile != nil && featureStates[0x06] != nil
    }

    var supportedNoiseModes: [HeadphoneNoiseMode] {
        profile == nil ? [] : [.off, .noiseCancellation, .ambient]
    }

    var supportedNoiseLevels: [OppoNoiseLevel] {
        profile == nil ? [] : OppoNoiseLevel.allCases
    }

    var connectedDeviceID: String? { selectedAddress }

    var connectionStatePublisher: AnyPublisher<HeadphoneConnectionState, Never> {
        $connectionState.eraseToAnyPublisher()
    }

    private let transport = OppoRFCOMMTransport()
    private var parser = OppoFrameParser()
    private var devices: [BluetoothPairedDevice] = []
    private var audioConnectedDeviceNames: [String] = []
    private var selectedAddress: String?
    private var sequence: UInt8 = 1
    private var profile: OppoModelProfile?
    private var pendingNoiseMode: HeadphoneNoiseMode?
    private var sessionGeneration = 0
    private var handshakeTask: Task<Void, Never>?
    private var restoreTask: Task<Void, Never>?
    private var extendedStatusTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var ringTask: Task<Void, Never>?
    private var codecRefreshTask: Task<Void, Never>?
    private var pendingSpatialType: Int?
    private var lastEQWriteAction: UInt8?
    private var pendingNewEQ = false
    private var wearingRefreshTask: Task<Void, Never>?
    private var failureCount = 0
    private var didRequestExtendedStatus = false
    private var receivedProductID = false
    private var receivedBattery = false
    private var receivedNoise = false

    init() {
        restoreOnConnectEnabled = HeadphoneProfileStore.isRestoreEnabled(for: providerID)
        transport.onStatusChange = { [weak self] status in
            self?.applyTransportStatus(status)
        }
        transport.onData = { [weak self] data in
            self?.handleIncoming(data)
        }
    }

    // MARK: - HeadphoneProvider

    func recognizesBluetoothDevice(named name: String) -> Bool {
        Self.isSupportedHeadphoneName(name)
    }

    func matches(audioDevice: SystemAudioDevice) -> Bool {
        Self.isSupportedHeadphoneName(audioDevice.name)
    }

    func updateBluetoothPairedDevices(_ devices: [BluetoothPairedDevice]) {
        let supported = devices.filter { Self.isSupportedHeadphoneName($0.name) }
        if self.devices != supported {
            self.devices = supported
        }
        connectIfPossible()
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
        connectIfPossible()
    }

    func refresh() {
        failureCount = 0
        switch connectionState {
        case .ready:
            send(.battery)
            send(.noiseControl, [0x01, 0x01])
            requestExtendedStatus(force: true)
        case .failed:
            disconnect()
            connectIfPossible()
        default:
            connectIfPossible()
        }
    }

    func refreshBatteryStatus() {
        guard connectionState == .ready else { return }
        send(.battery)
    }

    func disconnect() {
        sessionGeneration &+= 1
        handshakeTask?.cancel()
        handshakeTask = nil
        restoreTask?.cancel()
        restoreTask = nil
        extendedStatusTask?.cancel()
        extendedStatusTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        ringTask?.cancel()
        ringTask = nil
        isRinging = false
        codecRefreshTask?.cancel()
        codecRefreshTask = nil
        pendingSpatialType = nil
        failureCount = 0
        transport.disconnect()
        connectionState = .idle
        selectedAddress = nil
        connectedName = "OPPO Enco"
        clearPublishedDeviceState()
    }

    func shutdown() {
        disconnect()
        transport.onStatusChange = nil
        transport.onData = nil
    }

    func setNoiseMode(_ mode: HeadphoneNoiseMode) {
        applyNoiseMode(mode, persist: true)
    }

    func setHoldCycleMask(_ mask: UInt16) {
        guard connectionState == .ready, profile != nil else { return }
        guard mask.nonzeroBitCount >= 2 else { return }
        holdCycleMask = mask
        _ = sendRaw(OppoNoiseCodec.encodeHoldCycle(mask, sequence: takeSequence()))
        send(.noiseControl, [0x02, 0x01])
    }

    func setNoiseLevel(_ level: OppoNoiseLevel) {
        guard connectionState == .ready, profile != nil else { return }
        noiseLevel = level
        noiseMode = .noiseCancellation
        _ = sendRaw(OppoNoiseCodec.encodeSetLevel(level, sequence: takeSequence()))
        send(.noiseControl, [0x01, 0x01])
        send(.noiseControl, [0x04, 0x01])
    }

    func setSpatialEnabled(_ enabled: Bool) {
        setSpatialType(enabled ? 1 : 0)
    }

    func setAutoPauseEnabled(_ enabled: Bool) {
        setFeature(0x04, enabled: enabled)
    }

    func setDualConnectionEnabled(_ enabled: Bool) {
        setFeature(0x11, enabled: enabled)
    }

    func setSwiftPairEnabled(_ enabled: Bool) {
        setFeature(0x37, enabled: enabled)
    }

    func setSpatialType(_ type: Int) {
        guard connectionState == .ready, spatialAudioSupported, (0...2).contains(type) else { return }

        // Hi-Res and spatial are mutually exclusive. `0x0403 18 00` is the
        // only write that actually clears the Hi-Res flag; it also restarts
        // the link, so remember the requested type and apply it on reconnect.
        if type != 0, featureStates[0x18] == 0x01 {
            pendingSpatialType = type
            featureStates[0x18] = 0
            spatialEnabled = false
            spatialType = 0
            send(.setFeature, [0x18, 0x00])
            return
        }

        pendingSpatialType = nil
        spatialType = type
        spatialEnabled = type != 0
        featureStates[0x1B] = UInt8(type)
        send(.setSpatialType, [UInt8(type)])
        send(.spatialType)
        send(.features, [0x02, 0x18, 0x1B])
    }

    /// Hi-Res only works on the LHDC path. Enabling forces LHDC V5 and turns
    /// spatial audio off first; disabling selects LHDC without Hi-Res. Both
    /// writes restart the Bluetooth link, so the provider reconnects and then
    /// re-reads the real state.
    func setHiResEnabled(_ enabled: Bool) {
        guard connectionState == .ready else { return }
        pendingSpatialType = nil
        if enabled {
            spatialEnabled = false
            spatialType = 0
            featureStates[0x1B] = 0
            send(.setSpatialType, [0x00])
            featureStates[0x18] = 1
            send(.setCodec, [0x08, 0x01, 0x00])
        } else {
            // The codec command does not clear the flag; the feature write
            // does, at the cost of a link restart.
            featureStates[0x18] = 0
            send(.setFeature, [0x18, 0x00])
        }
    }

    // MARK: - Custom EQ

    func createCustomEQ(name: String, bands: [OppoEQBand]) {
        guard connectionState == .ready else { return }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        lastEQWriteAction = 0x01
        pendingNewEQ = true
        _ = sendRaw(
            OppoEQWrite.frame(
                action: 0x01,
                id: 0,
                name: cleanName.isEmpty ? "Custom" : cleanName,
                bands: bands,
                sequence: takeSequence()
            )
        )
    }

    func updateCustomEQ(id: UInt8, name: String, bands: [OppoEQBand]) {
        guard connectionState == .ready else { return }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        lastEQWriteAction = 0x02
        eqCurrentID = id
        _ = sendRaw(
            OppoEQWrite.frame(
                action: 0x02,
                id: id,
                name: cleanName.isEmpty ? "Custom" : cleanName,
                bands: bands,
                sequence: takeSequence()
            )
        )
    }

    func deleteCustomEQ(id: UInt8) {
        guard connectionState == .ready,
            let preset = customEQPresets.first(where: { $0.id == id })
        else { return }
        lastEQWriteAction = 0x03
        _ = sendRaw(
            OppoEQWrite.frame(
                action: 0x03,
                id: id,
                name: preset.name,
                bands: preset.bands,
                sequence: takeSequence()
            )
        )
        send(.customEqualizer)
        send(.equalizer)
    }

    func setCodec(_ codec: Int) {
        guard connectionState == .ready, (1...8).contains(codec) else { return }
        let hiRes = codec == 8 && featureStates[0x18] == 0x01
        currentCodec = codec
        codecName = OppoCodecName.name(for: codec)
        send(.setCodec, [UInt8(codec), hiRes ? 0x01 : 0x00, 0x00])
    }

    func setAlertVolume(_ volume: Int) {
        guard connectionState == .ready, (1...10).contains(volume) else { return }
        alertVolume = volume
        send(.setAlertVolume, [UInt8(volume)])
        send(.alertVolume)
    }

    var wearingIsFresh: Bool {
        OppoRingSafety.canRing(wearing: wearing, updatedAt: wearingUpdatedAt)
    }

    var canRingEarbuds: Bool {
        connectionState == .ready && wearingIsFresh
    }

    var ringBlockedByWearing: Bool {
        guard let wearing else { return false }
        return wearing.leftInEar || wearing.rightInEar
    }

    func ringEarbuds() {
        guard connectionState == .ready else { return }
        // Ringing a bud that is still in an ear can be dangerously loud.
        // Require an explicit "both out of ear" report; unknown also refuses.
        guard wearingIsFresh else { return }
        ringTask?.cancel()
        isRinging = true
        send(.findEarbuds, [0x01])
        ringTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled else { return }
            self.send(.findEarbuds, [0x00])
            self.isRinging = false
            self.ringTask = nil
        }
    }

    private func applyWearing(_ state: OppoWearingState?) {
        wearing = state
        wearingUpdatedAt = state == nil ? nil : Date()
        guard isRinging else { return }
        guard let state, state.bothOutOfEar else {
            ringTask?.cancel()
            ringTask = nil
            isRinging = false
            send(.findEarbuds, [0x00])
            return
        }
    }

    func setGestureFunction(bindingID: String, function: UInt8) {
        setGestureFunction(bindingIDs: [bindingID], function: function)
    }

    /// A logical gesture can own more than one table entry (the slide is split
    /// into button groups on some firmware). Write every entry in one table.
    func setGestureFunction(bindingIDs: [String], function: UInt8) {
        guard connectionState == .ready, !bindingIDs.isEmpty else { return }
        let targets = Set(bindingIDs)
        guard gestures.contains(where: { targets.contains($0.id) }) else { return }

        var table = gestures
        for index in table.indices where targets.contains(table[index].id) {
            let binding = table[index]
            table[index] = OppoGestureBinding(
                device: binding.device,
                button: binding.button,
                action: binding.action,
                function: function
            )
        }
        gestures = table

        var payload: [UInt8] = [UInt8(table.count)]
        for entry in table {
            payload += [entry.device, entry.button, entry.action, entry.function]
        }
        send(.setGestures, payload)
        send(.gestures)
    }

    func connectDualDevice(_ address: String) {
        sendDualAction(0x01, address)
    }

    func disconnectDualDevice(_ address: String) {
        sendDualAction(0x02, address)
    }

    func setPreferredDevice(_ address: String) {
        sendDualAction(0x04, address, extra: [0x01])
    }

    func clearPreferredDevice() {
        guard connectionState == .ready else { return }
        send(.dualDeviceAction, [0x04, 0x00])
        send(.preferredDevice, [0x02])
    }

    private func sendDualAction(_ action: UInt8, _ address: String, extra: [UInt8] = []) {
        guard connectionState == .ready,
            let mac = OppoWire.macBytes(from: address)
        else { return }
        send(.dualDeviceAction, [action] + extra + mac)
        send(.dualDevices)
        send(.preferredDevice, [0x02])
    }

    private func setFeature(_ identifier: UInt8, enabled: Bool) {
        guard connectionState == .ready, featureStates[identifier] != nil else { return }
        featureStates[identifier] = enabled ? 1 : 0
        send(.setFeature, [identifier, enabled ? 0x01 : 0x00])
        send(.features, [0x01, identifier])
    }

    func setGameModeEnabled(_ enabled: Bool) {
        guard connectionState == .ready, gameModeSupported else { return }
        gameModeEnabled = enabled
        send(.setFeature, [0x06, enabled ? 0x01 : 0x00])
        requestFeatureStates()
    }

    func setGameSoundType(_ type: Int) {
        guard connectionState == .ready, let gameSound, gameSound.options.contains(type) else { return }
        self.gameSound = OppoGameSoundState(selected: type, options: gameSound.options)
        send(.setGameSound, [UInt8(type), 0x01])
        send(.gameSound)
        send(.features, [0x01, 0x27])
    }

    func setEQPreset(id: UInt8) {
        guard connectionState == .ready, eqPresets.contains(where: { $0.id == id }) else { return }
        eqCurrentID = id
        send(.selectEqualizer, [id])
        send(.equalizer)
    }

    func setRestoreOnConnectEnabled(_ enabled: Bool) {
        guard restoreOnConnectEnabled != enabled else { return }
        restoreOnConnectEnabled = enabled
        HeadphoneProfileStore.setRestoreEnabled(enabled, for: providerID)

        if !enabled {
            restoreTask?.cancel()
            restoreTask = nil
            return
        }

        if connectionState == .ready,
            let deviceID = selectedAddress,
            HeadphoneProfileStore.load(
                OppoRestorableProfile.self,
                providerID: providerID,
                deviceID: deviceID
            ) == nil,
            let mode = noiseMode
        {
            saveProfile(mode: mode, deviceID: deviceID)
        }
        scheduleRestore()
    }

    // MARK: - Connection lifecycle

    private func connectIfPossible() {
        guard connectionState == .idle || isFailedState else { return }
        guard
            let device = devices.first(where: { candidate in
                guard candidate.isAudioConnected else { return false }
                guard Self.isSupportedHeadphoneName(candidate.name) else { return false }
                return audioConnectedDeviceNames.isEmpty
                    || audioConnectedDeviceNames.contains {
                        BluetoothDeviceNameMatcher.matches($0, candidate.name)
                    }
            })
        else { return }

        selectedAddress = device.address
        connectedName = device.name
        clearPublishedDeviceState()
        connectionState = .connecting
        transport.connect(address: device.address)
    }

    private func applyTransportStatus(_ status: OppoRFCOMMStatus) {
        switch status {
        case .idle:
            connectionState = .idle
            selectedAddress = nil
            clearPublishedDeviceState()

        case .connecting:
            if connectionState != .ready {
                connectionState = .connecting
            }

        case .connected:
            reconnectTask?.cancel()
            reconnectTask = nil
            beginHandshake()

        case .failed(let message):
            handshakeTask?.cancel()
            handshakeTask = nil
            restoreTask?.cancel()
            restoreTask = nil
            extendedStatusTask?.cancel()
            extendedStatusTask = nil
            connectionState = .failed(message)
            selectedAddress = nil
            clearPublishedDeviceState()
            scheduleReconnect()
        }
    }

    private func beginHandshake() {
        sessionGeneration &+= 1
        let generation = sessionGeneration
        parser.reset()
        sequence = 1
        receivedProductID = false
        receivedBattery = false
        receivedNoise = false
        pendingNoiseMode = nil
        didRequestExtendedStatus = false

        send(.productID)
        send(.battery)
        send(.noiseControl, [0x01, 0x01])

        handshakeTask?.cancel()
        handshakeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(2_500))
            guard let self,
                !Task.isCancelled,
                self.sessionGeneration == generation,
                self.connectionState == .connecting
            else { return }
            self.finishHandshake()
        }
    }

    private func finishHandshake() {
        guard connectionState == .connecting else { return }
        guard receivedProductID || receivedBattery || receivedNoise else {
            transport.disconnect()
            connectionState = .failed("OPPO headphones did not reply")
            selectedAddress = nil
            clearPublishedDeviceState()
            scheduleReconnect()
            return
        }

        handshakeTask?.cancel()
        handshakeTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        failureCount = 0
        connectionState = .ready
        updateCapabilities()
        requestExtendedStatus()
        startCodecRefresh()
        startWearingRefresh()
        applyPendingSpatialType()

        if restoreOnConnectEnabled {
            scheduleRestore()
        }
    }

    private var isFailedState: Bool {
        if case .failed = connectionState { return true }
        return false
    }

    /// A denied permission prompt or a stale RFCOMM session can fail the first
    /// attempt. Retry a few times with backoff; a user disconnect does not
    /// schedule this path.
    private func scheduleReconnect() {
        guard failureCount < 6 else { return }
        guard
            devices.contains(where: { device in
                device.isAudioConnected && Self.isSupportedHeadphoneName(device.name)
            })
        else { return }

        reconnectTask?.cancel()
        let attempt = failureCount
        failureCount += 1
        let delay = min(30, 2 << attempt)
        let generation = sessionGeneration

        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self,
                !Task.isCancelled,
                self.sessionGeneration == generation,
                self.connectionState != .ready
            else { return }
            self.connectionState = .idle
            self.connectIfPossible()
        }
    }

    private func applyPendingSpatialType() {
        guard pendingSpatialType != nil else { return }
        let generation = sessionGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self,
                !Task.isCancelled,
                self.sessionGeneration == generation,
                self.connectionState == .ready,
                let type = self.pendingSpatialType,
                self.featureStates[0x1B] != nil
            else { return }
            self.pendingSpatialType = nil
            self.setSpatialType(type)
        }
    }

    private func startWearingRefresh() {
        wearingRefreshTask?.cancel()
        let generation = sessionGeneration
        wearingRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                guard let self,
                    !Task.isCancelled,
                    self.sessionGeneration == generation,
                    self.connectionState == .ready
                else { return }
                self.send(.wearing)
            }
        }
    }

    private func startCodecRefresh() {
        codecRefreshTask?.cancel()
        let generation = sessionGeneration
        codecRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self,
                    !Task.isCancelled,
                    self.sessionGeneration == generation,
                    self.connectionState == .ready
                else { return }
                self.send(.codec)
            }
        }
    }

    private func updateCapabilities() {
        guard connectionState == .ready else { return }
        var updated: HeadphoneCapabilities = [.battery]
        if profile != nil {
            updated.insert(.noiseControl)
            updated.insert(.spatialAudio)
            updated.insert(.equalizer)
        }
        if capabilities != updated {
            capabilities = updated
        }
    }

    private func scheduleRestore() {
        guard restoreOnConnectEnabled,
            connectionState == .ready,
            let deviceID = selectedAddress,
            profile != nil
        else { return }

        restoreTask?.cancel()
        let generation = sessionGeneration
        restoreTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self,
                !Task.isCancelled,
                self.sessionGeneration == generation,
                self.connectionState == .ready,
                self.selectedAddress == deviceID
            else { return }

            guard
                let saved = HeadphoneProfileStore.load(
                    OppoRestorableProfile.self,
                    providerID: self.providerID,
                    deviceID: deviceID
                ),
                let mode = HeadphoneNoiseMode(rawValue: saved.noiseMode),
                self.supportedNoiseModes.contains(mode)
            else { return }

            if self.noiseMode != mode {
                self.applyNoiseMode(mode, persist: false)
            }
        }
    }

    // MARK: - Incoming data

    private func handleIncoming(_ data: Data) {
        for message in parser.append(data) {
            handle(message)
        }
    }

    private func handle(_ message: OppoMessage) {
        switch message.command {
        case 0x8103:
            guard let productID = OppoModelProfile.productID(from: message.payload) else { return }
            receivedProductID = true
            self.productID = productID
            if let profile = OppoModelProfile.profile(for: productID) {
                self.profile = profile
                connectedName = profile.displayName
                if let pendingNoiseMode {
                    noiseMode = pendingNoiseMode
                }
                updateCapabilities()
                if connectionState == .ready {
                    requestExtendedStatus()
                }
            }
            completeHandshakeIfReady()

        case 0x8106:
            guard let battery = OppoBatteryCodec.decode(message.payload) else { return }
            receivedBattery = true
            apply(battery)
            completeHandshakeIfReady()

        case 0x810C:
            if let raw = OppoNoiseCodec.reportRawValue(message.payload) {
                noiseLevel = OppoNoiseCodec.level(forRawValue: raw)
                if let mode = OppoNoiseCodec.mode(forRawValue: raw) {
                    receivedNoise = true
                    apply(noiseMode: mode)
                    completeHandshakeIfReady()
                }
            } else if let smart = OppoNoiseCodec.decodeSmartLevel(message.payload) {
                smartNoiseLevel = smart
            } else if let mask = OppoNoiseCodec.decodeHoldCycle(message.payload) {
                holdCycleMask = mask
            }

        case 0x8105:
            if let version = OppoStatusCodec.firmware(message.payload) {
                firmwareVersion = version
            }

        case 0x8108:
            if let bindings = OppoStatusCodec.gestures(message.payload) {
                gestures = bindings
            }

        case 0x8109:
            applyWearing(OppoStatusCodec.wearing(message.payload))

        case 0x810D:
            if let states = OppoStatusCodec.featureSwitches(message.payload) {
                apply(featureStates: states)
                if pendingSpatialType != nil {
                    applyPendingSpatialType()
                }
            }

        case 0x810F:
            if let identifier = OppoStatusCodec.currentEQ(message.payload) {
                eqCurrentID = identifier
            }

        case 0x8112:
            if let devices = OppoStatusCodec.dualDevices(message.payload) {
                dualDevices = devices
            }

        case 0x8114:
            if let codec = OppoStatusCodec.codec(message.payload) {
                currentCodec = codec
                codecName = OppoCodecName.name(for: codec)
            }

        case 0x8123:
            if let codecs = OppoStatusCodec.codecMask(message.payload) {
                availableCodecs = codecs
            }

        case 0x8122:
            if let presets = OppoStatusCodec.eqPresets(message.payload) {
                customEQPresets = presets
            }

        case 0x812A:
            if let type = OppoStatusCodec.spatialType(message.payload) {
                spatialType = type
                if spatialEnabled == nil {
                    spatialEnabled = type != 0
                }
            }

        case 0x812B:
            if let state = OppoStatusCodec.gameSound(message.payload) {
                gameSound = state
            }

        case 0x8418:
            if let identifier = message.payload.dropFirst().first {
                if pendingNewEQ {
                    pendingNewEQ = false
                    eqCurrentID = identifier
                    send(.selectEqualizer, [identifier])
                } else if lastEQWriteAction == 0x02 {
                    eqCurrentID = identifier
                }
            }
            lastEQWriteAction = nil
            send(.customEqualizer)
            send(.equalizer)

        case 0x8130:
            if let volume = OppoStatusCodec.alertVolume(message.payload) {
                alertVolume = volume
            }

        case 0x8132:
            preferredDeviceMAC = OppoStatusCodec.preferredDevice(message.payload)

        case 0x0504:
            if let identifier = message.payload.first {
                eqCurrentID = identifier
            }

        case 0x0204:
            if message.payload.first == 0x02 {
                let body = Array([0x00] + message.payload.dropFirst())
                applyWearing(OppoStatusCodec.wearing(body))
            }
            if message.payload.first == 0x06 {
                // The multipoint list changed (another host joined or left);
                // the per-link codec may have changed too.
                send(.codec)
                send(.dualDevices)
                send(.preferredDevice, [0x02])
                send(.features, [0x02, 0x18, 0x1B])
            }
            switch OppoEventCodec.decode(message) {
            case .battery(let battery):
                apply(battery)
            case .noiseMode(let mode):
                apply(noiseMode: mode)
            case nil:
                break
            }

        default:
            break
        }
    }

    private func apply(featureStates states: [UInt8: UInt8]) {
        for (identifier, value) in states {
            featureStates[identifier] = value
        }
        spatialEnabled = (featureStates[0x1B] ?? 0) != 0
        gameModeEnabled = featureStates[0x06] == 0x01
    }

    private func requestFeatureStates() {
        guard let profile else { return }
        send(.features, [UInt8(profile.featureQuery.count)] + profile.featureQuery)
    }

    private func requestExtendedStatus(force: Bool = false) {
        guard let profile, connectionState == .ready else { return }
        if didRequestExtendedStatus && !force { return }
        didRequestExtendedStatus = true

        let generation = sessionGeneration
        let requests: [(OppoCommand, [UInt8])] = [
            (.firmware, []),
            (.features, [UInt8(profile.featureQuery.count)] + profile.featureQuery),
            (.equalizer, []),
            (.customEqualizer, []),
            (.gameSound, []),
            (.spatialType, []),
            (.noiseControl, [0x04, 0x01]),
            (.noiseControl, [0x02, 0x01]),
            (.dualDevices, []),
            (.preferredDevice, [0x02]),
            (.gestures, []),
            (.codec, []),
            (.codecList, []),
            (.alertVolume, []),
            (.wearing, []),
        ]

        extendedStatusTask?.cancel()
        extendedStatusTask = Task { @MainActor [weak self] in
            for (command, payload) in requests {
                guard let self,
                    !Task.isCancelled,
                    self.sessionGeneration == generation,
                    self.connectionState == .ready
                else { return }
                self.send(command, payload)
                try? await Task.sleep(for: .milliseconds(220))
            }
        }
    }

    private func completeHandshakeIfReady() {
        guard receivedBattery, receivedProductID || receivedNoise else { return }
        finishHandshake()
    }

    private func apply(_ battery: OppoBattery) {
        leftBatteryPercent = battery.left
        rightBatteryPercent = battery.right
        caseBatteryPercent = battery.caseLevel
        if let level = battery.lowestEarbudLevel {
            batteryPercent = min(100, max(0, level))
        }
        isCharging = battery.isCharging
    }

    private func apply(noiseMode mode: HeadphoneNoiseMode) {
        pendingNoiseMode = mode
        guard profile != nil, supportedNoiseModes.contains(mode) else { return }
        noiseMode = mode
    }

    private func applyNoiseMode(_ mode: HeadphoneNoiseMode, persist: Bool) {
        guard let profile, supportedNoiseModes.contains(mode) else { return }

        let frame: Data
        if mode == .noiseCancellation {
            let level = noiseLevel ?? .deep
            noiseLevel = level
            frame = OppoNoiseCodec.encodeSetLevel(level, sequence: takeSequence())
        } else if let encoded = OppoNoiseCodec.encodeSet(
            mode: mode,
            profile: profile,
            sequence: takeSequence()
        ) {
            frame = encoded
        } else {
            return
        }

        guard transport.send(frame) == 0 else { return }
        noiseMode = mode
        if persist {
            persistDesiredProfile()
        }
        // An accepted write is not proof the buds changed mode (a set can be
        // refused, for example when neither bud is worn). Read it back.
        send(.noiseControl, [0x01, 0x01])
    }

    // MARK: - Outgoing data

    @discardableResult
    private func send(_ command: OppoCommand, _ payload: [UInt8] = []) -> Bool {
        let frame = OppoWire.encode(
            command: command.rawValue,
            sequence: takeSequence(),
            payload: payload
        )
        return transport.send(frame) == 0
    }

    @discardableResult
    private func sendRaw(_ frame: Data) -> Bool {
        transport.send(frame) == 0
    }

    private func takeSequence() -> UInt8 {
        let value = sequence
        sequence = sequence >= 254 ? 1 : sequence + 1
        return value
    }

    // MARK: - Persistence

    private func persistDesiredProfile() {
        guard let deviceID = selectedAddress, let mode = noiseMode else { return }
        saveProfile(mode: mode, deviceID: deviceID)
    }

    private func saveProfile(mode: HeadphoneNoiseMode, deviceID: String) {
        HeadphoneProfileStore.save(
            OppoRestorableProfile(noiseMode: mode.rawValue),
            providerID: providerID,
            deviceID: deviceID
        )
    }

    // MARK: - State

    private func clearPublishedDeviceState() {
        batteryPercent = nil
        isCharging = nil
        noiseMode = nil
        noiseLevel = nil
        smartNoiseLevel = nil
        holdCycleMask = 0
        capabilities = []
        profile = nil
        pendingNoiseMode = nil
        receivedProductID = false
        receivedBattery = false
        receivedNoise = false
        parser.reset()
        leftBatteryPercent = nil
        rightBatteryPercent = nil
        caseBatteryPercent = nil
        firmwareVersion = nil
        productID = nil
        currentCodec = nil
        codecName = nil
        featureStates = [:]
        spatialEnabled = nil
        spatialType = nil
        gameModeEnabled = nil
        gameSound = nil
        eqCurrentID = nil
        customEQPresets = []
        wearing = nil
        wearingUpdatedAt = nil
        dualDevices = []
        preferredDeviceMAC = nil
        gestures = []
        alertVolume = nil
        wearingRefreshTask?.cancel()
        wearingRefreshTask = nil
        availableCodecs = []
        extendedStatusTask?.cancel()
        extendedStatusTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        ringTask?.cancel()
        ringTask = nil
        isRinging = false
        codecRefreshTask?.cancel()
        codecRefreshTask = nil
        didRequestExtendedStatus = false
    }

    static func isSupportedHeadphoneName(_ name: String) -> Bool {
        let normalized = BluetoothDeviceNameMatcher.normalized(name)
        return normalized.contains("oppo") && normalized.contains("enco")
    }
}
