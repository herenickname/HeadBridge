import Foundation
import IOBluetooth
import OSLog

enum SonyV1ClientConnectionState: Equatable {
    case disconnected
    case connecting
    case ready
    case failed(String)
}

/// Pure Swift Sony MDR V1 client.
///
/// The client is deliberately event-driven. RFCOMM callbacks feed the parser,
/// every device packet is acknowledged immediately, and outgoing commands use
/// one stop-and-wait queue. There is no background polling loop.
@MainActor
final class SonyV1Client {
    var onConnectionStateChange: ((SonyV1ClientConnectionState) -> Void)?
    var onStateChange: ((SonyV1State) -> Void)?

    private struct QueuedCommand {
        let dataType: UInt8
        let payload: [UInt8]
        let label: String
        let coalescingKey: String?
        let isCritical: Bool
        let completion: (() -> Void)?
    }

    private struct InFlightCommand {
        let command: QueuedCommand
        let sequence: UInt8
        var attempt: Int
    }

    private let transport: SonyRFCOMMTransport
    private let parser = SonyMDRFrameParser()
    private let logger = Logger(subsystem: "io.github.herenickname.HeadBridge", category: "SonyV1")

    private(set) var connectionState: SonyV1ClientConnectionState = .disconnected
    private(set) var state = SonyV1State()

    private var deviceName = "Sony Headphones"
    private var profile = SonyV1DeviceProfile(deviceName: "Sony Headphones")
    private var commandQueue: [QueuedCommand] = []
    private var inFlight: InFlightCommand?
    private var nextSequence: UInt8 = 0
    private var commandTimeoutTask: Task<Void, Never>?
    private var handshakeFallbackTask: Task<Void, Never>?
    private var readyFallbackTask: Task<Void, Never>?
    private var handshakeComplete = false
    private var initialQueriesQueued = false
    private var reportedNCType: UInt8 = 0x02
    private var reportedASMType: UInt8 = 0x01
    private var reportedASMID: UInt8 = 0x00
    private var lastSubmittedVolume: Int?
    private var generation = 0
    private static let maximumQueuedCommands = 128

    convenience init() {
        self.init(transport: SonyRFCOMMTransport())
    }

    init(transport: SonyRFCOMMTransport) {
        self.transport = transport
        transport.onStatusChange = { [weak self] status in
            self?.handleTransportStatus(status)
        }
        transport.onData = { [weak self] data in
            self?.handleIncoming(data)
        }
    }

    func connect(address: String, deviceName: String) {
        resetSession(keepConnectionState: true)
        generation &+= 1
        self.deviceName = deviceName
        profile = SonyV1DeviceProfile(deviceName: deviceName)
        updateConnectionState(.connecting)
        transport.connect(address: address)
    }

    func disconnect() {
        generation &+= 1
        resetSession(keepConnectionState: true)
        transport.disconnect()
        updateConnectionState(.disconnected)
    }

    func refresh() {
        guard handshakeComplete, transport.status == .connected else { return }
        enqueueStateQueries()
    }

    func refreshBattery() {
        guard handshakeComplete, transport.status == .connected else { return }
        enqueue([SonyV1Opcode.batteryGet, 0x00], label: "Battery sample")
    }

    func setNoiseMode(_ mode: SonyV1NoiseMode, ambientLevel: Int? = nil) {
        guard connectionState == .ready else { return }
        let payload = profile.noisePayload(
            mode: mode,
            ambientLevel: ambientLevel ?? state.ambientLevel,
            reportedNCType: reportedNCType,
            reportedASMType: reportedASMType,
            reportedASMID: reportedASMID
        )

        enqueue(
            payload,
            label: "NCASM set \(String(describing: mode))",
            coalescingKey: "noise-set"
        ) { [weak self] in
            self?.enqueue([SonyV1Opcode.noiseGet, 0x02], label: "NCASM verify")
        }
    }

    func setAmbientLevel(_ level: Int) {
        guard connectionState == .ready else { return }
        let desiredLevel = min(20, max(1, level))

        let payload = profile.noisePayload(
            mode: .ambient,
            ambientLevel: desiredLevel,
            reportedNCType: reportedNCType,
            reportedASMType: reportedASMType,
            reportedASMID: reportedASMID
        )
        enqueue(
            payload,
            label: "NCASM ambient level \(desiredLevel)",
            coalescingKey: "noise-set"
        ) { [weak self] in
            self?.enqueue([SonyV1Opcode.noiseGet, 0x02], label: "NCASM verify")
        }
    }

    func setVolume(_ volume: Int) {
        guard connectionState == .ready else { return }
        let volume = min(30, max(0, volume))
        guard lastSubmittedVolume != volume else { return }
        lastSubmittedVolume = volume
        enqueue(
            [SonyV1Opcode.playbackSet, 0x01, 0x20, UInt8(volume)],
            label: "Volume set \(volume)",
            coalescingKey: "volume-set"
        )
    }

    func setEqualizerPreset(_ preset: SonyV1EqualizerPreset) {
        guard connectionState == .ready else { return }
        enqueue(SonyV1Payloads.equalizerPreset(preset), label: "Equalizer preset \(preset.title)") { [weak self] in
            self?.enqueue([SonyV1Opcode.equalizerGet, 0x01], label: "Equalizer verify")
        }
    }

    func setEqualizerBands(_ values: [Int]) {
        guard connectionState == .ready else { return }
        enqueue(SonyV1Payloads.equalizerBands(values), label: "Equalizer custom bands") { [weak self] in
            self?.enqueue([SonyV1Opcode.equalizerGet, 0x01], label: "Equalizer verify")
        }
    }

    func setSurroundMode(_ mode: SonyV1SurroundMode) {
        guard connectionState == .ready else { return }
        enqueue(SonyV1Payloads.surroundMode(mode), label: "VPT \(mode.title)") { [weak self] in
            self?.enqueue([SonyV1Opcode.virtualSoundGet, 0x01], label: "VPT verify")
        }
    }

    func setSoundPosition(_ position: SonyV1SoundPosition) {
        guard connectionState == .ready else { return }
        enqueue(SonyV1Payloads.soundPosition(position), label: "Sound position \(position.title)") { [weak self] in
            self?.enqueue([SonyV1Opcode.virtualSoundGet, 0x02], label: "Sound position verify")
        }
    }

    func setDSEE(enabled: Bool) {
        guard connectionState == .ready else { return }
        enqueue(SonyV1Payloads.dsee(enabled: enabled), label: "DSEE \(enabled ? "on" : "off")") { [weak self] in
            self?.enqueue([SonyV1Opcode.audioSettingGet, 0x02], label: "DSEE verify")
        }
    }

    func setSoundQualityMode(_ mode: SonyV1SoundQualityMode) {
        guard connectionState == .ready else { return }
        enqueue(SonyV1Payloads.soundQuality(mode), label: "Sound quality \(mode.title)")
    }

    func setTouchSensor(enabled: Bool) {
        guard connectionState == .ready else { return }
        enqueue(SonyV1Payloads.touchSensor(enabled: enabled), label: "Touch sensor \(enabled ? "on" : "off")") {
            [weak self] in
            self?.enqueue([SonyV1Opcode.touchSensorGet, 0xD2], label: "Touch sensor verify")
        }
    }

    func setAutomaticPowerOff(_ mode: SonyV1AutomaticPowerOff) {
        guard connectionState == .ready else { return }
        enqueue(SonyV1Payloads.automaticPowerOff(mode), label: "Automatic power off \(mode.title)") { [weak self] in
            self?.enqueue([SonyV1Opcode.systemSettingGet, 0x04], label: "Automatic power off verify")
        }
    }

    func setOptimizerRunning(_ running: Bool) {
        guard connectionState == .ready else { return }
        enqueue(SonyV1Payloads.optimizer(start: running), label: running ? "NC optimizer start" : "NC optimizer cancel")
    }

    private func handleTransportStatus(_ status: SonyRFCOMMStatus) {
        switch status {
        case .idle:
            if connectionState != .disconnected {
                resetSession(keepConnectionState: true)
                updateConnectionState(.disconnected)
            }

        case .connecting:
            updateConnectionState(.connecting)

        case .connected:
            beginHandshake()

        case .failed(let message):
            resetSession(keepConnectionState: true)
            updateConnectionState(.failed(message))
        }
    }

    private func beginHandshake() {
        resetProtocolState()
        updateConnectionState(.connecting)
        enqueue(
            [SonyV1Opcode.initGet, 0x00],
            label: "Protocol init",
            isCritical: true
        )

        let expectedGeneration = generation
        handshakeFallbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self,
                !Task.isCancelled,
                self.generation == expectedGeneration,
                self.transport.status == .connected,
                !self.handshakeComplete
            else { return }
            self.logger.notice("Sony init reply omitted; continuing with V1 state queries")
            self.completeHandshake()
        }
    }

    private func completeHandshake() {
        guard !handshakeComplete else { return }
        handshakeComplete = true
        handshakeFallbackTask?.cancel()
        handshakeFallbackTask = nil
        enqueueInitialQueries()

        let expectedGeneration = generation
        readyFallbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self,
                !Task.isCancelled,
                self.generation == expectedGeneration,
                self.transport.status == .connected,
                self.connectionState == .connecting
            else { return }
            self.logger.notice("Sony initial state was partial; exposing available controls")
            self.markReady()
        }
    }

    private func enqueueInitialQueries() {
        guard !initialQueriesQueued else { return }
        initialQueriesQueued = true

        enqueue([SonyV1Opcode.modelGet, 0x01], label: "Model get")
        enqueue([SonyV1Opcode.batteryGet, 0x00], label: "Battery get")
        enqueue([SonyV1Opcode.codecGet, 0x00], label: "Codec get")
        enqueue([SonyV1Opcode.noiseCapabilityGet, 0x02], label: "NCASM capability get")
        enqueue([SonyV1Opcode.noiseGet, 0x02], label: "NCASM get")
        enqueue(
            [SonyV1Opcode.playbackGet, 0x01, 0x20],
            label: "Volume get"
        ) { [weak self] in
            self?.markReady()
        }
        enqueueExtendedStateQueriesIfSupported()
    }

    private func enqueueStateQueries() {
        enqueue([SonyV1Opcode.batteryGet, 0x00], label: "Battery refresh")
        enqueue([SonyV1Opcode.codecGet, 0x00], label: "Codec refresh")
        enqueue([SonyV1Opcode.noiseGet, 0x02], label: "NCASM refresh")
        enqueue([SonyV1Opcode.playbackGet, 0x01, 0x20], label: "Volume refresh")
        enqueueExtendedStateQueriesIfSupported()
    }

    private func enqueueExtendedStateQueriesIfSupported() {
        let features = profile.features
        if features.contains(.equalizer) {
            enqueue([SonyV1Opcode.equalizerGet, 0x01], label: "Equalizer get")
        }
        if features.contains(.virtualSound) {
            enqueue([SonyV1Opcode.virtualSoundGet, 0x01], label: "VPT get")
            enqueue([SonyV1Opcode.virtualSoundGet, 0x02], label: "Sound position get")
        }
        if features.contains(.soundQualityMode) {
            enqueue([SonyV1Opcode.audioSettingGet, 0x01], label: "Sound quality get")
        }
        if features.contains(.audioUpsampling) {
            enqueue([SonyV1Opcode.audioSettingGet, 0x02], label: "DSEE get")
        }
        if features.contains(.touchSensor) {
            enqueue([SonyV1Opcode.touchSensorGet, 0xD2], label: "Touch sensor get")
        }
        if features.contains(.noiseOptimizer) {
            enqueue([SonyV1Opcode.optimizerStateGet, 0x01], label: "NC optimizer state get")
        }
        if features.contains(.automaticPowerOff) {
            enqueue([SonyV1Opcode.systemSettingGet, 0x04], label: "Automatic power off get")
        }
    }

    private func markReady() {
        guard transport.status == .connected else { return }
        readyFallbackTask?.cancel()
        readyFallbackTask = nil
        updateConnectionState(.ready)
        publishState()
    }

    private func enqueue(
        _ payload: [UInt8],
        dataType: UInt8 = SonyMDRPacket.commandType,
        label: String,
        coalescingKey: String? = nil,
        isCritical: Bool = false,
        completion: (() -> Void)? = nil
    ) {
        guard transport.status == .connected else { return }
        let command = QueuedCommand(
            dataType: dataType,
            payload: payload,
            label: label,
            coalescingKey: coalescingKey,
            isCritical: isCritical,
            completion: completion
        )

        if let coalescingKey,
            let existing = commandQueue.lastIndex(where: { $0.coalescingKey == coalescingKey })
        {
            commandQueue[existing] = command
        } else if commandQueue.count < Self.maximumQueuedCommands {
            commandQueue.append(command)
        } else {
            logger.error("Dropping Sony command because the queue is full: \(label, privacy: .public)")
            return
        }
        sendNextCommandIfPossible()
    }

    private func sendNextCommandIfPossible() {
        guard transport.status == .connected,
            inFlight == nil,
            !commandQueue.isEmpty
        else { return }

        let command = commandQueue.removeFirst()
        let sequence = nextSequence
        nextSequence ^= 1
        inFlight = InFlightCommand(command: command, sequence: sequence, attempt: 1)
        sendInFlight()
    }

    private func sendInFlight() {
        guard let inFlight else { return }
        let packet = SonyMDRPacket(
            dataType: inFlight.command.dataType,
            sequence: inFlight.sequence,
            payload: inFlight.command.payload
        )
        let result = transport.send(SonyMDRFraming.encode(packet))
        guard result == kIOReturnSuccess else {
            fail("Sony command write failed (\(result))")
            return
        }

        logger.debug("TX \(inFlight.command.label, privacy: .public)")
        scheduleCommandTimeout()
    }

    private func scheduleCommandTimeout() {
        commandTimeoutTask?.cancel()
        let expectedGeneration = generation
        commandTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1_500))
            guard let self,
                !Task.isCancelled,
                self.generation == expectedGeneration,
                var inFlight = self.inFlight
            else { return }

            if inFlight.attempt < 2 {
                inFlight.attempt += 1
                self.inFlight = inFlight
                self.logger.notice("Retrying Sony command \(inFlight.command.label, privacy: .public)")
                self.sendInFlight()
                return
            }

            self.logger.error("Sony command timed out: \(inFlight.command.label, privacy: .public)")
            self.inFlight = nil
            if inFlight.command.isCritical {
                self.fail("Sony protocol handshake timed out")
            } else {
                self.sendNextCommandIfPossible()
            }
        }
    }

    private func handleIncoming(_ data: Data) {
        for packet in parser.append(data) {
            if packet.dataType == SonyMDRPacket.ackType {
                handleAcknowledgement(packet)
                continue
            }

            acknowledge(packet)
            if !handshakeComplete, packet.payload.first != SonyV1Opcode.initReturn {
                completeHandshake()
            }
            interpret(packet.payload)
        }
    }

    private func acknowledge(_ packet: SonyMDRPacket) {
        let acknowledgement = SonyMDRPacket(
            dataType: SonyMDRPacket.ackType,
            sequence: packet.sequence ^ 1,
            payload: []
        )
        let result = transport.send(SonyMDRFraming.encode(acknowledgement))
        if result != kIOReturnSuccess {
            logger.error("Could not ACK Sony packet: \(result)")
        }
    }

    private func handleAcknowledgement(_ packet: SonyMDRPacket) {
        guard let inFlight,
            packet.sequence == (inFlight.sequence ^ 1)
        else { return }
        commandTimeoutTask?.cancel()
        commandTimeoutTask = nil
        self.inFlight = nil
        inFlight.command.completion?()
        sendNextCommandIfPossible()
    }

    private func interpret(_ payload: [UInt8]) {
        guard let opcode = payload.first else { return }

        switch opcode {
        case SonyV1Opcode.initReturn:
            guard let version = SonyMDRProtocolVersion.detect(fromInitReply: payload) else {
                fail("Unrecognized Sony MDR init reply")
                return
            }
            guard version == .v1 else {
                fail("Sony MDR V2 requires the V2 protocol adapter")
                return
            }
            completeHandshake()

        case SonyV1Opcode.modelReturn:
            parseModel(payload)

        case SonyV1Opcode.batteryReturn, SonyV1Opcode.batteryNotify:
            parseBattery(payload)

        case SonyV1Opcode.codecReturn, SonyV1Opcode.codecNotify:
            parseCodec(payload)

        case SonyV1Opcode.noiseReturn, SonyV1Opcode.noiseNotify:
            parseNoiseControl(payload)

        case SonyV1Opcode.playbackReturn, SonyV1Opcode.playbackNotify:
            parsePlayback(payload)

        case SonyV1Opcode.equalizerReturn, SonyV1Opcode.equalizerNotify:
            parseEqualizer(payload)

        case SonyV1Opcode.virtualSoundReturn, SonyV1Opcode.virtualSoundNotify:
            parseVirtualSound(payload)

        case SonyV1Opcode.audioSettingReturn, SonyV1Opcode.audioSettingNotify:
            parseAudioSetting(payload)

        case SonyV1Opcode.touchSensorReturn, SonyV1Opcode.touchSensorNotify:
            parseTouchSensor(payload)

        case SonyV1Opcode.optimizerStatus:
            parseOptimizerStatus(payload)

        case SonyV1Opcode.optimizerStateReturn, SonyV1Opcode.optimizerStateNotify:
            parseOptimizerState(payload)

        case SonyV1Opcode.systemSettingReturn, SonyV1Opcode.systemSettingNotify:
            parseSystemSetting(payload)

        default:
            break
        }
    }

    private func parseModel(_ payload: [UInt8]) {
        guard payload.count >= 3, payload[1] == 0x01 else { return }
        let length = Int(payload[2])
        guard length > 0, payload.count >= length + 3 else { return }
        let name = String(bytes: payload[3..<(3 + length)], encoding: .utf8)
        guard let name, !name.isEmpty else { return }
        state.modelName = name
        profile = SonyV1DeviceProfile(deviceName: name)
        publishState()
    }

    private func parseBattery(_ payload: [UInt8]) {
        guard payload.count >= 4, payload[1] == 0x00 else { return }
        state.batteryPercent = min(100, Int(payload[2]))
        state.isCharging = payload[3] == 0x01 || payload[3] == 0x02
        publishState()
    }

    private func parseCodec(_ payload: [UInt8]) {
        guard payload.count >= 3, payload[1] == 0x00 else { return }
        state.codecName =
            switch payload[2] {
            case 0x01: "SBC"
            case 0x02: "AAC"
            case 0x10: "LDAC"
            case 0x20: "aptX"
            case 0x21: "aptX HD"
            default: nil
            }
        publishState()
    }

    private func parseNoiseControl(_ payload: [UInt8]) {
        guard payload.count >= 8, payload[1] == 0x02 else { return }
        let effect = payload[2]
        reportedNCType = payload[3]
        state.windReductionSupported = reportedNCType == 0x02
        let ncValue = payload[4]
        reportedASMType = payload[5]
        reportedASMID = payload[6]
        let level = Int(payload[7])

        state.noiseMode = SonyV1NoiseMode.decode(
            effect: effect,
            ncSettingType: reportedNCType,
            ncValue: ncValue,
            ambientLevel: level
        )
        if state.noiseMode == .ambient {
            state.ambientLevel = level
        }
        publishState()
    }

    private func parsePlayback(_ payload: [UInt8]) {
        guard payload.count >= 4,
            payload[1] == 0x01,
            payload[2] == 0x20
        else { return }
        let volume = min(30, Int(payload[3]))
        state.volume = volume
        lastSubmittedVolume = volume
        publishState()
    }

    private func parseEqualizer(_ payload: [UInt8]) {
        guard payload.count >= 10, payload[1] == 0x01 else { return }
        state.equalizerPreset =
            SonyV1EqualizerPreset(rawValue: payload[2])
            ?? (payload[2] == 0xFF ? .manual : nil)
        state.equalizerBands = (0..<5).map { min(10, max(-10, Int(payload[5 + $0]) - 10)) }
        state.equalizerBands.append(min(10, max(-10, Int(payload[4]) - 10)))
        publishState()
    }

    private func parseVirtualSound(_ payload: [UInt8]) {
        guard payload.count >= 3 else { return }
        switch payload[1] {
        case 0x01:
            state.surroundMode = SonyV1SurroundMode(rawValue: payload[2])
        case 0x02:
            state.soundPosition = SonyV1SoundPosition(rawValue: payload[2])
        default:
            return
        }
        publishState()
    }

    private func parseAudioSetting(_ payload: [UInt8]) {
        guard payload.count >= 4 else { return }
        switch payload[1] {
        case 0x01:
            state.soundQualityMode = SonyV1SoundQualityMode(rawValue: payload[3])
        case 0x02:
            guard payload[3] <= 0x01 else { return }
            state.dseeEnabled = payload[3] == 0x01
        default:
            return
        }
        publishState()
    }

    private func parseTouchSensor(_ payload: [UInt8]) {
        guard payload.count >= 4,
            payload[1] == 0xD2,
            payload[3] <= 0x01
        else { return }
        state.touchSensorEnabled = payload[3] == 0x01
        publishState()
    }

    private func parseOptimizerStatus(_ payload: [UInt8]) {
        guard payload.count >= 4,
            let status = SonyV1OptimizerStatus(rawValue: payload[3])
        else { return }
        state.optimizerStatus = status
        publishState()
        if status == .finished {
            enqueue([SonyV1Opcode.optimizerStateGet, 0x01], label: "NC optimizer result get")
        }
    }

    private func parseOptimizerState(_ payload: [UInt8]) {
        guard payload.count >= 6 else { return }
        let pressure = Double(payload[5]) / 10.0
        guard pressure > 0, pressure <= 1.0 else { return }
        state.atmosphericPressure = pressure
        publishState()
    }

    private func parseSystemSetting(_ payload: [UInt8]) {
        guard payload.count >= 5,
            payload[1] == 0x04,
            let mode = SonyV1AutomaticPowerOff(first: payload[3], second: payload[4])
        else { return }
        state.automaticPowerOff = mode
        publishState()
    }

    private func publishState() {
        onStateChange?(state)
    }

    private func updateConnectionState(_ newState: SonyV1ClientConnectionState) {
        guard connectionState != newState else { return }
        connectionState = newState
        onConnectionStateChange?(newState)
    }

    private func fail(_ message: String) {
        logger.error("Sony V1 client failed: \(message, privacy: .public)")
        resetSession(keepConnectionState: true)
        transport.disconnect()
        updateConnectionState(.failed(message))
    }

    private func resetSession(keepConnectionState: Bool) {
        resetProtocolState()
        state = SonyV1State()
        lastSubmittedVolume = nil
        publishState()
        if !keepConnectionState {
            updateConnectionState(.disconnected)
        }
    }

    private func resetProtocolState() {
        commandTimeoutTask?.cancel()
        handshakeFallbackTask?.cancel()
        readyFallbackTask?.cancel()
        commandTimeoutTask = nil
        handshakeFallbackTask = nil
        readyFallbackTask = nil
        commandQueue.removeAll(keepingCapacity: true)
        inFlight = nil
        nextSequence = 0
        parser.reset()
        handshakeComplete = false
        initialQueriesQueued = false
        reportedNCType = 0x02
        reportedASMType = 0x01
        reportedASMID = 0x00
    }
}
