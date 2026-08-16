import Combine
import CoreBluetooth
import Foundation

enum ANCMode: Int, CaseIterable, Identifiable {
    case off = 0
    case noiseCancellation = 1
    case passThrough = 2

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .off: "Off"
        case .noiseCancellation: "ANC"
        case .passThrough: "Pass-Through"
        }
    }
}

enum CustomButtonMode: Int, CaseIterable, Identifiable {
    case anc = 0
    case voiceAssistant = 1

    var id: Int { rawValue }
    var title: String { self == .anc ? "ANC" : "Voice assistant" }
}

struct DiscoveredPeripheral: Identifiable {
    let id: UUID
    let name: String
    let rssi: Int
    fileprivate let peripheral: CBPeripheral
}

struct ProbeReading: Identifiable {
    let id: String
    let name: String
    let value: String
    let errorCode: UInt16
    let updatedAt: Date
}

struct TransportLogEntry: Identifiable {
    enum Direction: String { case outgoing = "TX", incoming = "RX", info = "INFO" }

    let id = UUID()
    let time: Date
    let direction: Direction
    let text: String
}

struct PairedDeviceInfo: Identifiable {
    let id: Int
    let name: String
    let address: String
    let connected: Bool
}

private struct BWRestorableProfile: Codable, Equatable {
    var noiseMode: Int
    var equalizer: [Int]
    var equalizerBypassed: Bool
    var wearSensorEnabled: Bool
    var wearSensitivity: Int
    var standbyMinutes: Int
    var customButtonMode: Int
    var voicePromptsEnabled: Bool
    var spatialAudioEnabled: Bool
    var spatialAudioPreset: Int
}

struct BWRPCPendingWrite: Equatable {
    let commandKey: String
    let commandName: String
    let data: Data
}

struct BWRPCWriteQueue {
    enum EnqueueResult: Equatable {
        case appended
        case replaced
        case rejectedFull
    }

    let capacity: Int
    private(set) var items: [BWRPCPendingWrite] = []

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    @discardableResult
    mutating func enqueue(_ pending: BWRPCPendingWrite) -> EnqueueResult {
        if let existing = items.lastIndex(where: { $0.commandKey == pending.commandKey }) {
            items[existing] = pending
            return .replaced
        }
        guard items.count < capacity else { return .rejectedFull }
        items.append(pending)
        return .appended
    }

    mutating func popFirst() -> BWRPCPendingWrite? {
        guard !items.isEmpty else { return nil }
        return items.removeFirst()
    }

    mutating func removeAll() {
        items.removeAll(keepingCapacity: true)
    }
}

struct BWRPCTransportReadiness: Equatable {
    var requestDiscovered = false
    var responseDiscovered = false
    var responseNotificationsConfirmed = false

    var isReady: Bool {
        requestDiscovered && responseDiscovered && responseNotificationsConfirmed
    }
}

struct BWPeripheralSessionIdentity: Equatable {
    let peripheralID: UUID
    let generation: Int

    func accepts(peripheralID: UUID, generation: Int) -> Bool {
        self.peripheralID == peripheralID && self.generation == generation
    }
}

struct BWAutomaticConnectionTracker: Equatable {
    private(set) var attemptedPeripheralIDs: Set<UUID> = []
    var reconnectAttempt = 0
    var isSuppressed = false

    mutating func markAttempted(_ peripheralID: UUID) {
        attemptedPeripheralIDs.insert(peripheralID)
    }

    func hasAttempted(_ peripheralID: UUID) -> Bool {
        attemptedPeripheralIDs.contains(peripheralID)
    }

    mutating func resetCandidates() {
        attemptedPeripheralIDs.removeAll()
    }

    mutating func resetForBluetoothRadioTransition() {
        attemptedPeripheralIDs.removeAll()
        reconnectAttempt = 0
        isSuppressed = false
    }
}

private enum BWPeripheralEvent {
    case discoveredServices(Error?)
    case discoveredCharacteristics(CBService, Error?)
    case updatedNotificationState(CBCharacteristic, Error?)
    case updatedValue(CBCharacteristic, Error?)
    case wroteValue(CBCharacteristic, Error?)
    case readyToWriteWithoutResponse
}

private final class BWPeripheralDelegateProxy: NSObject, CBPeripheralDelegate {
    let generation: Int
    private let handler: @MainActor (Int, CBPeripheral, BWPeripheralEvent) -> Void

    init(
        generation: Int,
        handler: @escaping @MainActor (Int, CBPeripheral, BWPeripheralEvent) -> Void
    ) {
        self.generation = generation
        self.handler = handler
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        forward(peripheral, .discoveredServices(error))
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        forward(peripheral, .discoveredCharacteristics(service, error))
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        forward(peripheral, .updatedNotificationState(characteristic, error))
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        forward(peripheral, .updatedValue(characteristic, error))
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        forward(peripheral, .wroteValue(characteristic, error))
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        forward(peripheral, .readyToWriteWithoutResponse)
    }

    private func forward(_ peripheral: CBPeripheral, _ event: BWPeripheralEvent) {
        let generation = generation
        let handler = handler
        Task { @MainActor in
            handler(generation, peripheral, event)
        }
    }
}

@MainActor
final class BowersWilkinsProvider: NSObject, ObservableObject {
    enum Phase: Equatable {
        case bluetoothUnavailable
        case idle
        case scanning
        case connecting
        case discovering
        case ready
        case failed(String)

        var title: String {
            switch self {
            case .bluetoothUnavailable: "Bluetooth unavailable"
            case .idle: "Not connected"
            case .scanning: "Scanning…"
            case .connecting: "Connecting…"
            case .discovering: "Discovering RPC…"
            case .ready: "Connected"
            case .failed(let reason): reason
            }
        }

        var canStartAutomaticScan: Bool {
            switch self {
            case .bluetoothUnavailable, .idle, .failed: true
            default: false
            }
        }

        var isConnecting: Bool {
            switch self {
            case .connecting, .discovering: true
            default: false
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var peripherals: [DiscoveredPeripheral] = []
    @Published var selectedPeripheralID: UUID?
    @Published private(set) var connectedName = "B&W Headphones"

    @Published private(set) var ancMode: ANCMode = .off
    @Published private(set) var batteryPercent: Int?
    @Published private(set) var isCharging: Bool?
    @Published private(set) var eqValues = [0, 0, 0, 0, 0]
    @Published private(set) var eqBypassed = true
    @Published private(set) var wearSensorEnabled = false
    @Published private(set) var wearSensitivity = 2
    @Published private(set) var sleepMinutes = 0
    @Published private(set) var customButtonMode: CustomButtonMode = .anc
    @Published private(set) var voicePromptsEnabled = true
    @Published private(set) var spatialAudioEnabled = false
    @Published private(set) var spatialAudioPreset = 0
    @Published private(set) var restoreOnConnectEnabled = false
    @Published var localName = ""

    @Published private(set) var softwareVersion = "—"
    @Published private(set) var serialNumber = "—"
    @Published private(set) var macAddress = "—"
    @Published private(set) var audioSource = "—"
    @Published private(set) var audioCodec = "—"
    @Published private(set) var samplingRate = "—"
    @Published private(set) var readings: [String: ProbeReading] = [:]
    @Published private(set) var log: [TransportLogEntry] = []
    @Published private(set) var pairedDevices: [PairedDeviceInfo] = []

    private var central: CBCentralManager!
    private var discovered: [UUID: DiscoveredPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var requestCharacteristic: CBCharacteristic?
    private var responseCharacteristic: CBCharacteristic?
    private var eventCharacteristic: CBCharacteristic?
    private var transportReadiness = BWRPCTransportReadiness()
    private var writeQueue = BWRPCWriteQueue(capacity: BowersWilkinsProvider.maximumQueuedWrites)
    private var writeInFlight = false
    private var writeTimeoutTask: Task<Void, Never>?
    private var refreshWorkItems: [String: DispatchWorkItem] = [:]
    private var didStartInitialRefresh = false
    private var pairedDeviceCount = 0
    private var nextPairedDeviceIndex: Int?
    private var audioConnectedDeviceNames: [String] = []
    private var automaticConnection = BWAutomaticConnectionTracker()
    private var automaticReconnectTask: Task<Void, Never>?
    private var pendingConnection: (item: DiscoveredPeripheral, automatically: Bool)?
    private var scanTimeoutWorkItem: DispatchWorkItem?
    private var scanGeneration = 0
    private var connectionTimeoutWorkItem: DispatchWorkItem?
    private var connectionAttemptGeneration = 0
    private var transportGeneration = 0
    private var activeSessionIdentity: BWPeripheralSessionIdentity?
    private var peripheralDelegateProxy: BWPeripheralDelegateProxy?
    private var teardownPeripheral: CBPeripheral?
    private var teardownTimeoutWorkItem: DispatchWorkItem?
    private var teardownGeneration = 0
    private var reconnectAfterTeardown = false
    private var profileRestoreTask: Task<Void, Never>?
    private var restoredProfileDeviceID: String?
    private var isApplyingRestoredProfile = false
    private var diagnosticsEnabled = false

    private static let linkTimeout: TimeInterval = 12
    private static let discoveryTimeout: TimeInterval = 12
    private static let writeTimeout: Duration = .seconds(4)
    private static let maximumAutomaticReconnectAttempts = 2
    private static let maximumQueuedWrites = 128

    override init() {
        super.init()
        restoreOnConnectEnabled = HeadphoneProfileStore.isRestoreEnabled(for: "bowers-wilkins")
        central = CBCentralManager(delegate: self, queue: nil)
    }

    deinit {
        automaticReconnectTask?.cancel()
        profileRestoreTask?.cancel()
        writeTimeoutTask?.cancel()
        scanTimeoutWorkItem?.cancel()
        connectionTimeoutWorkItem?.cancel()
        teardownTimeoutWorkItem?.cancel()
        refreshWorkItems.values.forEach { $0.cancel() }
        if let peripheral,
            let peripheralDelegateProxy,
            peripheral.delegate === peripheralDelegateProxy
        {
            peripheral.delegate = nil
        }
        central?.delegate = nil
    }

    var isReady: Bool { phase == .ready }

    func startScanning() {
        cancelAutomaticReconnect()
        startScanning(automatically: false)
    }

    func setDiagnosticsEnabled(_ enabled: Bool) {
        guard diagnosticsEnabled != enabled else { return }
        diagnosticsEnabled = enabled
        if enabled {
            addLog(
                .info,
                isReady
                    ? "Protocol diagnostics enabled; refreshing current values"
                    : "Protocol diagnostics enabled; waiting for an RPC connection"
            )
            if isReady { refreshPrimary() }
        } else {
            log.removeAll()
        }
    }

    private func startScanning(automatically: Bool) {
        guard central.state == .poweredOn else {
            cancelConnectionTimeout()
            phase = .bluetoothUnavailable
            return
        }
        guard !automatically || !audioConnectedDeviceNames.isEmpty else { return }
        guard phase.canStartAutomaticScan else { return }
        guard teardownPeripheral == nil else { return }
        guard peripheral?.state != .connected,
            peripheral?.state != .connecting,
            peripheral?.state != .disconnecting
        else { return }
        cancelConnectionTimeout()
        cancelScanTimeout()
        discovered.removeAll()
        peripherals.removeAll()
        phase = .scanning
        addLog(.info, "Scanning BLE advertisements for up to 10 seconds; duplicate advertisements disabled")
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])

        let expectedScanGeneration = scanGeneration
        let timeout = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self,
                    self.scanGeneration == expectedScanGeneration,
                    self.phase == .scanning
                else { return }
                self.scanTimeoutWorkItem = nil
                self.central.stopScan()
                self.phase = .idle
                self.addLog(.info, "BLE scan timed out and stopped")
            }
        }
        scanTimeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
    }

    func connectSelected() {
        guard let id = selectedPeripheralID, let item = discovered[id] else { return }
        automaticConnection.isSuppressed = false
        cancelAutomaticReconnect()
        connect(item, automatically: false)
    }

    func updateAudioConnectedDevices(_ devices: [SystemAudioDevice]) {
        let names =
            devices
            .filter(\.isBluetooth)
            .map(\.name)
            .filter(Self.isSupportedHeadphoneName)

        if names != audioConnectedDeviceNames {
            audioConnectedDeviceNames = names
            automaticConnection.resetCandidates()
            automaticConnection.isSuppressed = false
            cancelAutomaticReconnect()
        }
        if names.isEmpty {
            cancelAutomaticReconnect()
            cancelScanTimeout()
            cancelConnectionTimeout()
            cancelTeardownTracking()
            central.stopScan()
            let disconnectedPeripheral = releasePeripheral()
            if let disconnectedPeripheral,
                disconnectedPeripheral.state == .connected || disconnectedPeripheral.state == .connecting
            {
                central.cancelPeripheralConnection(disconnectedPeripheral)
            }
            pendingConnection = nil
            phase = central.state == .poweredOn ? .idle : .bluetoothUnavailable
        } else if !names.isEmpty,
            central.state == .poweredOn,
            phase.canStartAutomaticScan
        {
            startScanning(automatically: true)
        }
        tryAutomaticConnection()
    }

    private func connect(_ item: DiscoveredPeripheral, automatically: Bool) {
        guard phase != .connecting, phase != .discovering, phase != .ready else { return }
        guard teardownPeripheral == nil else {
            pendingConnection = (item, automatically)
            phase = .connecting
            addLog(.info, "Waiting for the stale BLE link to tear down before reconnecting")
            return
        }
        cancelAutomaticReconnect(resetAttempt: false)
        cancelScanTimeout()
        central.stopScan()

        if let current = peripheral,
            current.identifier != item.id,
            current.state != .disconnected
        {
            pendingConnection = (item, automatically)
            phase = .connecting
            addLog(.info, "Closing the previous BLE link before connecting to \(item.name)")
            armConnectionTimeout(
                for: current.identifier,
                expectedPhase: .connecting,
                after: Self.linkTimeout,
                failureMessage: "Previous control connection did not close"
            )
            if current.state != .disconnecting {
                central.cancelPeripheralConnection(current)
            }
            return
        }

        switch item.peripheral.state {
        case .connected:
            connectedName = item.name
            bindPeripheral(item.peripheral)
            phase = .discovering
            addLog(.info, "Reusing the existing BLE link to \(item.name)")
            armConnectionTimeout(
                for: item.id,
                expectedPhase: .discovering,
                after: Self.discoveryTimeout,
                failureMessage: "RPC discovery timed out"
            )
            item.peripheral.discoverServices(nil)
            return
        case .connecting:
            connectedName = item.name
            bindPeripheral(item.peripheral)
            phase = .connecting
            addLog(.info, "A BLE connection to \(item.name) is already pending")
            armConnectionTimeout(
                for: item.id,
                expectedPhase: .connecting,
                after: Self.linkTimeout,
                failureMessage: "Control connection timed out"
            )
            return
        case .disconnecting:
            addLog(.info, "Waiting for the previous BLE link to close before reconnecting")
            pendingConnection = (item, automatically)
            if peripheral !== item.peripheral {
                bindPeripheral(item.peripheral)
            }
            phase = .connecting
            armConnectionTimeout(
                for: item.id,
                expectedPhase: .connecting,
                after: Self.linkTimeout,
                failureMessage: "Control connection did not close"
            )
            return
        case .disconnected:
            break
        @unknown default:
            return
        }

        connectedName = item.name
        bindPeripheral(item.peripheral)
        phase = .connecting
        addLog(.info, "\(automatically ? "Auto-connecting" : "Connecting") to \(item.name)")
        armConnectionTimeout(
            for: item.id,
            expectedPhase: .connecting,
            after: Self.linkTimeout,
            failureMessage: "Control connection timed out"
        )
        central.connect(item.peripheral)
    }

    func disconnect() {
        automaticConnection.isSuppressed = true
        cancelAutomaticReconnect()
        pendingConnection = nil
        cancelScanTimeout()
        cancelConnectionTimeout()
        cancelTeardownTracking()
        central.stopScan()
        let disconnectedPeripheral = releasePeripheral()
        if let disconnectedPeripheral { central.cancelPeripheralConnection(disconnectedPeripheral) }
        phase = .idle
    }

    private func tryAutomaticConnection() {
        guard !automaticConnection.isSuppressed,
            phase == .scanning || phase == .idle,
            !audioConnectedDeviceNames.isEmpty
        else { return }

        guard
            let item = discovered.values
                .sorted(by: { $0.rssi > $1.rssi })
                .first(where: { candidate in
                    !automaticConnection.hasAttempted(candidate.id)
                        && audioConnectedDeviceNames.contains {
                            BluetoothDeviceNameMatcher.matches($0, candidate.name)
                        }
                })
        else { return }

        automaticConnection.markAttempted(item.id)
        selectedPeripheralID = item.id
        addLog(.info, "Core Audio already has \(item.name) connected; starting BLE RPC automatically")
        connect(item, automatically: true)
    }

    static func deviceNamesMatch(_ lhs: String, _ rhs: String) -> Bool {
        BluetoothDeviceNameMatcher.matches(lhs, rhs)
    }

    func recognizesBluetoothDevice(named name: String) -> Bool {
        Self.isSupportedHeadphoneName(name)
    }

    /// Recent Bowers & Wilkins headphones share the same RPC discovery path.
    /// The GATT service/characteristics remain the final compatibility check;
    /// this list only prevents unrelated Bluetooth devices from being probed.
    static func isSupportedHeadphoneName(_ name: String) -> Bool {
        let normalized = BluetoothDeviceNameMatcher.normalized(name)

        if normalized.contains("bowerswilkins"),
            normalized.contains("headphone") || normalized.contains("headset")
        {
            return true
        }
        return ["px7", "px8", "pi5", "pi6", "pi7", "pi8"].contains {
            normalized.contains($0)
        }
    }

    private func scheduleAutomaticReconnect() {
        guard !automaticConnection.isSuppressed,
            !audioConnectedDeviceNames.isEmpty,
            automaticReconnectTask == nil,
            teardownPeripheral == nil,
            phase.canStartAutomaticScan
        else { return }

        guard automaticConnection.reconnectAttempt < Self.maximumAutomaticReconnectAttempts else {
            addLog(
                .info,
                "Automatic RPC reconnect paused after \(automaticConnection.reconnectAttempt) retries"
            )
            return
        }

        automaticConnection.reconnectAttempt += 1
        let delay = 5 * automaticConnection.reconnectAttempt
        addLog(.info, "RPC disconnected while Bluetooth audio remains available; retrying in \(delay) seconds")
        automaticReconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            guard !Task.isCancelled else { return }
            self.automaticReconnectTask = nil
            guard self.phase.canStartAutomaticScan,
                !self.audioConnectedDeviceNames.isEmpty,
                self.peripheral?.state != .connected,
                self.peripheral?.state != .connecting,
                self.peripheral?.state != .disconnecting
            else { return }
            self.automaticConnection.resetCandidates()
            self.startScanning(automatically: true)
        }
    }

    private func cancelAutomaticReconnect(resetAttempt: Bool = true) {
        automaticReconnectTask?.cancel()
        automaticReconnectTask = nil
        if resetAttempt { automaticConnection.reconnectAttempt = 0 }
    }

    private func armConnectionTimeout(
        for peripheralID: UUID,
        expectedPhase: Phase,
        after delay: TimeInterval,
        failureMessage: String
    ) {
        cancelConnectionTimeout()
        let generation = connectionAttemptGeneration
        let timeout = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self,
                    self.connectionAttemptGeneration == generation,
                    self.phase == expectedPhase,
                    self.peripheral?.identifier == peripheralID
                else { return }

                self.connectionTimeoutWorkItem = nil
                self.connectionAttemptGeneration &+= 1
                let timedOutPeripheral = self.releasePeripheral()
                self.pendingConnection = nil
                self.phase = .failed(failureMessage)
                self.addLog(.info, "\(failureMessage); cancelling the stale BLE link")
                if let timedOutPeripheral {
                    self.beginTeardown(of: timedOutPeripheral, reconnectWhenFinished: true)
                } else {
                    self.scheduleAutomaticReconnect()
                }
            }
        }
        connectionTimeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: timeout)
    }

    private func cancelConnectionTimeout() {
        connectionTimeoutWorkItem?.cancel()
        connectionTimeoutWorkItem = nil
        connectionAttemptGeneration &+= 1
    }

    private func cancelScanTimeout() {
        scanTimeoutWorkItem?.cancel()
        scanTimeoutWorkItem = nil
        scanGeneration &+= 1
    }

    func refreshPrimary() {
        guard isReady else { return }
        BWRPCatalog.primaryReads.forEach { send($0) }
    }

    func probeEverything() {
        guard isReady else { return }
        readings.removeAll()
        BWRPCatalog.explorerReads.forEach { send($0) }
    }

    func setANC(_ mode: ANCMode) {
        ancMode = mode
        send(BWRPCatalog.ancSet, payload: .int(Int64(mode.rawValue)))
        refresh(BWRPCatalog.ancGet)
        persistDesiredProfile()
    }

    func setEQBand(_ index: Int, value: Int) {
        guard eqValues.indices.contains(index) else { return }
        eqValues[index] = min(60, max(-60, value))
    }

    func commitEQ() {
        send(BWRPCatalog.eqSet, payload: .array(eqValues.map { .int(Int64($0)) }))
        refresh(BWRPCatalog.eqGet)
        persistDesiredProfile()
    }

    func setEQBypassed(_ bypassed: Bool) {
        eqBypassed = bypassed
        send(BWRPCatalog.eqBypassSet, payload: .bool(bypassed))
        refresh(BWRPCatalog.eqBypassGet)
        persistDesiredProfile()
    }

    func setWearSensor(_ enabled: Bool) {
        wearSensorEnabled = enabled
        send(BWRPCatalog.wearSet, payload: .bool(enabled))
        refresh(BWRPCatalog.wearGet)
        persistDesiredProfile()
    }

    func setWearSensitivity(_ value: Int) {
        wearSensitivity = min(3, max(1, value))
        send(BWRPCatalog.wearSensitivitySet, payload: .int(Int64(wearSensitivity)))
        refresh(BWRPCatalog.wearSensitivityGet)
        persistDesiredProfile()
    }

    func setSleepMinutes(_ minutes: Int) {
        sleepMinutes = max(0, minutes)
        send(BWRPCatalog.sleepSet, payload: .int(Int64(sleepMinutes)))
        refresh(BWRPCatalog.sleepGet)
        persistDesiredProfile()
    }

    func setCustomButton(_ mode: CustomButtonMode) {
        customButtonMode = mode
        send(BWRPCatalog.buttonSet, payload: .int(Int64(mode.rawValue)))
        refresh(BWRPCatalog.buttonGet)
        persistDesiredProfile()
    }

    func setVoicePrompts(_ enabled: Bool) {
        voicePromptsEnabled = enabled
        send(BWRPCatalog.voiceSet, payload: .bool(enabled))
        refresh(BWRPCatalog.voiceGet)
        persistDesiredProfile()
    }

    func setSpatialAudio(_ enabled: Bool) {
        spatialAudioEnabled = enabled
        send(BWRPCatalog.spatialEnabledSet, payload: .bool(enabled))
        refresh(BWRPCatalog.spatialEnabledGet)
        persistDesiredProfile()
    }

    func setSpatialAudioPreset(_ preset: Int) {
        spatialAudioPreset = min(2, max(0, preset))
        send(BWRPCatalog.spatialPresetSet, payload: .int(Int64(spatialAudioPreset)))
        refresh(BWRPCatalog.spatialPresetGet)
        persistDesiredProfile()
    }

    func setRestoreOnConnectEnabled(_ enabled: Bool) {
        guard restoreOnConnectEnabled != enabled else { return }
        restoreOnConnectEnabled = enabled
        HeadphoneProfileStore.setRestoreEnabled(enabled, for: "bowers-wilkins")
        restoredProfileDeviceID = nil
        if !enabled {
            profileRestoreTask?.cancel()
            profileRestoreTask = nil
        }
        if enabled,
            isReady,
            let deviceID = connectedDeviceID,
            HeadphoneProfileStore.load(
                BWRestorableProfile.self,
                providerID: "bowers-wilkins",
                deviceID: deviceID
            ) == nil
        {
            persistDesiredProfile()
        }
        if enabled { scheduleProfileRestore() }
    }

    func commitLocalName() {
        guard !localName.isEmpty else { return }
        send(BWRPCatalog.nameSet, payload: .string(localName))
        refresh(BWRPCatalog.nameGet)
    }

    func sendRaw(namespace: UInt8, commandID: UInt8, payload: MessagePackValue?) {
        send(BWRPCCommand(namespace: namespace, id: commandID, name: "Manual command"), payload: payload)
    }

    private func refresh(_ command: BWRPCCommand) {
        refreshWorkItems[command.key]?.cancel()
        let expectedGeneration = transportGeneration
        var workItem: DispatchWorkItem?
        let scheduled = DispatchWorkItem { [weak self] in
            guard let self,
                let workItem,
                !workItem.isCancelled,
                self.transportGeneration == expectedGeneration,
                self.isReady
            else { return }
            self.refreshWorkItems[command.key] = nil
            self.send(command)
        }
        workItem = scheduled
        refreshWorkItems[command.key] = scheduled
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: scheduled)
    }

    private func send(_ command: BWRPCCommand, payload: MessagePackValue? = nil) {
        guard isReady,
            transportReadiness.isReady,
            requestCharacteristic != nil,
            peripheral != nil
        else {
            addLog(.info, "Ignored \(command.name): transport is not ready")
            return
        }
        let data = BWRPC.request(command, payload: payload)
        addLog(.outgoing, "\(command.name) [\(command.key)]  \(data.hexString)")
        let pending = BWRPCPendingWrite(commandKey: command.key, commandName: command.name, data: data)
        if writeQueue.enqueue(pending) == .rejectedFull {
            addLog(.info, "Ignored \(command.name): write queue is full")
            return
        }
        pumpWriteQueue()
    }

    private func pumpWriteQueue() {
        guard !writeInFlight,
            let peripheral,
            let characteristic = requestCharacteristic,
            let identity = activeSessionIdentity,
            identity.accepts(peripheralID: peripheral.identifier, generation: transportGeneration)
        else { return }

        let type: CBCharacteristicWriteType =
            characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        guard type == .withResponse || peripheral.canSendWriteWithoutResponse else { return }
        guard let pending = writeQueue.popFirst() else { return }

        writeInFlight = type == .withResponse
        peripheral.writeValue(pending.data, for: characteristic, type: type)
        if type == .withResponse {
            armWriteTimeout(for: pending, identity: identity)
        } else {
            DispatchQueue.main.async { [weak self] in self?.pumpWriteQueue() }
        }
    }

    private func armWriteTimeout(for pending: BWRPCPendingWrite, identity: BWPeripheralSessionIdentity) {
        cancelWriteTimeout()
        writeTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.writeTimeout)
            guard let self,
                !Task.isCancelled,
                self.writeInFlight,
                self.activeSessionIdentity == identity
            else { return }

            self.addLog(.info, "GATT write timed out for \(pending.commandName); resetting the RPC link")
            let timedOutPeripheral = self.releasePeripheral()
            self.phase = .failed("RPC write timed out")
            if let timedOutPeripheral {
                self.beginTeardown(of: timedOutPeripheral, reconnectWhenFinished: true)
            } else {
                self.scheduleAutomaticReconnect()
            }
        }
    }

    private func cancelWriteTimeout() {
        writeTimeoutTask?.cancel()
        writeTimeoutTask = nil
    }

    private func bindPeripheral(_ newPeripheral: CBPeripheral) {
        _ = releasePeripheral()
        transportGeneration &+= 1
        let identity = BWPeripheralSessionIdentity(
            peripheralID: newPeripheral.identifier,
            generation: transportGeneration
        )
        let proxy = BWPeripheralDelegateProxy(generation: identity.generation) {
            [weak self] generation, peripheral, event in
            self?.handlePeripheralEvent(event, from: peripheral, generation: generation)
        }
        peripheral = newPeripheral
        activeSessionIdentity = identity
        peripheralDelegateProxy = proxy
        newPeripheral.delegate = proxy
    }

    private func beginTeardown(
        of stalePeripheral: CBPeripheral,
        reconnectWhenFinished: Bool
    ) {
        cancelTeardownTracking()
        guard stalePeripheral.state != .disconnected else {
            if reconnectWhenFinished { scheduleAutomaticReconnect() }
            return
        }

        teardownPeripheral = stalePeripheral
        reconnectAfterTeardown = reconnectWhenFinished
        central.cancelPeripheralConnection(stalePeripheral)
        let expectedGeneration = teardownGeneration
        let timeout = DispatchWorkItem { [weak self, weak stalePeripheral] in
            Task { @MainActor in
                guard let self,
                    let stalePeripheral,
                    self.teardownGeneration == expectedGeneration,
                    self.teardownPeripheral === stalePeripheral
                else { return }
                self.teardownTimeoutWorkItem = nil
                if stalePeripheral.state == .disconnected {
                    self.finishTeardown(of: stalePeripheral)
                } else {
                    self.addLog(.info, "Stale BLE link did not tear down; reconnect remains blocked")
                    self.phase = .failed("Previous control connection did not close")
                }
            }
        }
        teardownTimeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.linkTimeout, execute: timeout)
    }

    private func finishTeardown(of stalePeripheral: CBPeripheral) {
        guard teardownPeripheral === stalePeripheral else { return }
        let shouldReconnect = reconnectAfterTeardown
        teardownTimeoutWorkItem?.cancel()
        teardownTimeoutWorkItem = nil
        teardownPeripheral = nil
        reconnectAfterTeardown = false
        teardownGeneration &+= 1

        if let nextConnection = pendingConnection {
            pendingConnection = nil
            phase = .idle
            connect(nextConnection.item, automatically: nextConnection.automatically)
        } else if shouldReconnect {
            scheduleAutomaticReconnect()
        }
    }

    private func cancelTeardownTracking() {
        teardownTimeoutWorkItem?.cancel()
        teardownTimeoutWorkItem = nil
        reconnectAfterTeardown = false
        if let teardownPeripheral, teardownPeripheral.state != .disconnected {
            central.cancelPeripheralConnection(teardownPeripheral)
        }
        teardownPeripheral = nil
        teardownGeneration &+= 1
    }

    @discardableResult
    private func releasePeripheral() -> CBPeripheral? {
        let releasedPeripheral = peripheral
        if let releasedPeripheral,
            let peripheralDelegateProxy,
            releasedPeripheral.delegate === peripheralDelegateProxy
        {
            releasedPeripheral.delegate = nil
        }
        peripheralDelegateProxy = nil
        activeSessionIdentity = nil
        peripheral = nil
        transportGeneration &+= 1
        resetTransportState()
        return releasedPeripheral
    }

    private func resetTransportState() {
        profileRestoreTask?.cancel()
        profileRestoreTask = nil
        cancelWriteTimeout()
        refreshWorkItems.values.forEach { $0.cancel() }
        refreshWorkItems.removeAll(keepingCapacity: true)
        requestCharacteristic = nil
        responseCharacteristic = nil
        eventCharacteristic = nil
        transportReadiness = BWRPCTransportReadiness()
        writeQueue.removeAll()
        writeInFlight = false
        didStartInitialRefresh = false
        restoredProfileDeviceID = nil
        nextPairedDeviceIndex = nil
        readings.removeAll()
        clearPublishedDeviceState()
    }

    private func clearPublishedDeviceState() {
        ancMode = .off
        batteryPercent = nil
        isCharging = nil
        eqValues = [0, 0, 0, 0, 0]
        eqBypassed = true
        wearSensorEnabled = false
        wearSensitivity = 2
        sleepMinutes = 0
        customButtonMode = .anc
        voicePromptsEnabled = true
        spatialAudioEnabled = false
        spatialAudioPreset = 0
        localName = ""
        softwareVersion = "—"
        serialNumber = "—"
        macAddress = "—"
        audioSource = "—"
        audioCodec = "—"
        samplingRate = "—"
        pairedDevices.removeAll()
    }

    private func transportMayBeReady() {
        guard transportReadiness.isReady,
            requestCharacteristic != nil,
            responseCharacteristic != nil
        else { return }
        cancelConnectionTimeout()
        cancelAutomaticReconnect()
        phase = .ready
        cancelScanTimeout()
        central.stopScan()
        guard !didStartInitialRefresh else { return }
        didStartInitialRefresh = true
        addLog(.info, "B&W RPC characteristics discovered")
        refreshPrimary()
        scheduleProfileRestore()
    }

    private func scheduleProfileRestore() {
        profileRestoreTask?.cancel()
        guard restoreOnConnectEnabled,
            let deviceID = connectedDeviceID,
            restoredProfileDeviceID != deviceID
        else { return }

        profileRestoreTask = Task { @MainActor [weak self] in
            // Let the initial capability reads settle before deciding which
            // parts of a saved profile are safe to send to this model.
            try? await Task.sleep(for: .milliseconds(1_500))
            guard let self,
                !Task.isCancelled,
                self.isReady,
                self.connectedDeviceID == deviceID
            else { return }

            if let profile = HeadphoneProfileStore.load(
                BWRestorableProfile.self,
                providerID: "bowers-wilkins",
                deviceID: deviceID
            ) {
                self.applyRestoredProfile(profile)
                self.addLog(.info, "Restored saved settings after connect")
            } else {
                self.persistDesiredProfile()
                self.addLog(.info, "Saved current settings as the restore-on-connect baseline")
            }
            self.restoredProfileDeviceID = deviceID
            self.profileRestoreTask = nil
        }
    }

    private func applyRestoredProfile(_ profile: BWRestorableProfile) {
        isApplyingRestoredProfile = true
        defer {
            isApplyingRestoredProfile = false
            if let deviceID = connectedDeviceID {
                HeadphoneProfileStore.save(
                    profile,
                    providerID: "bowers-wilkins",
                    deviceID: deviceID
                )
            }
        }

        let supported = capabilities
        if supported.contains(.noiseControl),
            let mode = ANCMode(rawValue: profile.noiseMode), mode != ancMode
        {
            setANC(mode)
        }
        let equalizer = Array(profile.equalizer.prefix(5)).map { min(60, max(-60, $0)) }
        if supported.contains(.equalizer), equalizer.count == 5, equalizer != eqValues {
            eqValues = equalizer
            commitEQ()
        }
        if supported.contains(.equalizer), profile.equalizerBypassed != eqBypassed {
            setEQBypassed(profile.equalizerBypassed)
        }
        if supported.contains(.wearSensor), profile.wearSensorEnabled != wearSensorEnabled {
            setWearSensor(profile.wearSensorEnabled)
        }
        if supported.contains(.wearSensor), profile.wearSensitivity != wearSensitivity {
            setWearSensitivity(profile.wearSensitivity)
        }
        if supported.contains(.standbyTimer), profile.standbyMinutes != sleepMinutes {
            setSleepMinutes(profile.standbyMinutes)
        }
        if supported.contains(.customButton),
            let button = CustomButtonMode(rawValue: profile.customButtonMode), button != customButtonMode
        {
            setCustomButton(button)
        }
        if supported.contains(.voicePrompts), profile.voicePromptsEnabled != voicePromptsEnabled {
            setVoicePrompts(profile.voicePromptsEnabled)
        }
        if supported.contains(.spatialAudio), profile.spatialAudioEnabled != spatialAudioEnabled {
            setSpatialAudio(profile.spatialAudioEnabled)
        }
        if supported.contains(.spatialAudio), profile.spatialAudioPreset != spatialAudioPreset {
            setSpatialAudioPreset(profile.spatialAudioPreset)
        }
    }

    private func persistDesiredProfile() {
        guard !isApplyingRestoredProfile,
            let deviceID = connectedDeviceID
        else { return }
        HeadphoneProfileStore.save(
            BWRestorableProfile(
                noiseMode: ancMode.rawValue,
                equalizer: eqValues,
                equalizerBypassed: eqBypassed,
                wearSensorEnabled: wearSensorEnabled,
                wearSensitivity: wearSensitivity,
                standbyMinutes: sleepMinutes,
                customButtonMode: customButtonMode.rawValue,
                voicePromptsEnabled: voicePromptsEnabled,
                spatialAudioEnabled: spatialAudioEnabled,
                spatialAudioPreset: spatialAudioPreset
            ),
            providerID: "bowers-wilkins",
            deviceID: deviceID
        )
    }

    private func handle(_ data: Data) {
        addLog(.incoming, data.hexString)
        do {
            let message = try BWRPC.decode(data)
            let value = message.payload?.displayValue ?? "(no payload)"
            readings[message.command.key] = ProbeReading(
                id: message.command.key,
                name: message.command.name,
                value: value,
                errorCode: message.errorCode,
                updatedAt: Date()
            )
            if message.succeeded { apply(message) }
        } catch {
            addLog(.info, "Decode error: \(error.localizedDescription)")
        }
    }

    private func apply(_ message: BWRPCMessage) {
        guard let payload = message.payload else { return }
        let key = message.command.key
        switch key {
        case BWRPCatalog.ancGet.key:
            if let value = payload.intValue, let mode = ANCMode(rawValue: value) { ancMode = mode }
        case BWRPCatalog.eqGet.key:
            if let values = payload.arrayValue?.compactMap(\.intValue), values.count >= 5 {
                eqValues = Array(values.prefix(5))
            }
        case BWRPCatalog.eqBypassGet.key:
            if let value = payload.boolValue { eqBypassed = value }
        case BWRPCatalog.wearGet.key:
            if let value = payload.boolValue { wearSensorEnabled = value }
        case BWRPCatalog.wearSensitivityGet.key:
            if let value = payload.intValue { wearSensitivity = value }
        case BWRPCatalog.sleepGet.key:
            if let value = payload.intValue { sleepMinutes = value }
        case BWRPCatalog.buttonGet.key:
            let value = payload.intValue ?? (payload.boolValue == true ? 1 : 0)
            if let mode = CustomButtonMode(rawValue: value) { customButtonMode = mode }
        case BWRPCatalog.voiceGet.key:
            if let value = payload.boolValue { voicePromptsEnabled = value }
        case BWRPCatalog.nameGet.key:
            if let value = payload.stringValue { localName = value }
        case BWRPCatalog.spatialEnabledGet.key:
            if let value = payload.boolValue { spatialAudioEnabled = value }
        case BWRPCatalog.spatialPresetGet.key:
            if let value = payload.intValue { spatialAudioPreset = value }
        case "08:0C": batteryPercent = payload.intValue
        case "08:0B": isCharging = payload.boolValue
        case "04:0C": audioSource = Self.sourceName(payload.intValue)
        case "05:06": audioCodec = Self.codecName(Self.embeddedInt(payload))
        case "04:14":
            samplingRate = payload.intValue.map { "\($0) Hz" } ?? payload.displayValue
        case "02:01": softwareVersion = payload.displayValue
        case "08:04":
            serialNumber = payload.displayValue
            scheduleProfileRestore()
        case "08:02":
            let rawAddress = payload.displayValue
            macAddress = Self.normalizedMACAddress(rawAddress) ?? rawAddress.uppercased()
            scheduleProfileRestore()
        case BWRPCatalog.pairedDeviceCountGet.key:
            if let count = payload.intValue { beginPairedDeviceRead(count: count) }
        case BWRPCatalog.pairedDeviceGet.key:
            applyPairedDevice(payload)
        case "04:16":
            if let values = payload.arrayValue?.compactMap(\.intValue), values.count >= 3 {
                audioSource = Self.sourceName(values[0])
                audioCodec = Self.codecName(values[1])
                samplingRate = "\(values[2]) Hz"
            }
        default: break
        }
    }

    private func beginPairedDeviceRead(count: Int) {
        pairedDeviceCount = max(0, count)
        pairedDevices.removeAll()
        guard pairedDeviceCount > 0 else { nextPairedDeviceIndex = nil; return }
        nextPairedDeviceIndex = 0
        send(BWRPCatalog.pairedDeviceGet, payload: .int(0))
    }

    private func applyPairedDevice(_ payload: MessagePackValue) {
        guard let index = nextPairedDeviceIndex,
            case .map(let map) = payload,
            let name = map["2"]?.stringValue
        else { return }
        let address =
            map["1"]?.arrayValue?
            .compactMap(\.intValue)
            .map { String(format: "%02X", $0 & 0xFF) }
            .joined(separator: ":") ?? "—"
        let item = PairedDeviceInfo(id: index, name: name, address: address, connected: map["3"]?.boolValue ?? false)
        pairedDevices.removeAll { $0.id == index }
        pairedDevices.append(item)
        pairedDevices.sort { $0.id < $1.id }

        let next = index + 1
        if next < pairedDeviceCount {
            nextPairedDeviceIndex = next
            send(BWRPCatalog.pairedDeviceGet, payload: .int(Int64(next)))
        } else {
            nextPairedDeviceIndex = nil
        }
    }

    static func persistentDeviceIdentifier(macAddress: String, serialNumber: String) -> String? {
        if let address = normalizedMACAddress(macAddress) {
            return "mac:\(address.lowercased())"
        }

        let serial = serialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard serial.count >= 4,
            serial != "—",
            serial.caseInsensitiveCompare("null") != .orderedSame,
            serial.caseInsensitiveCompare("(no payload)") != .orderedSame
        else { return nil }
        return "serial:\(serial.lowercased())"
    }

    private static func normalizedMACAddress(_ value: String) -> String? {
        let payload = value.lowercased().hasPrefix("0x") ? String(value.dropFirst(2)) : value
        let hexadecimal = payload.uppercased().filter(\.isHexDigit)
        guard hexadecimal.count == 12 else { return nil }
        var groups: [String] = []
        var index = hexadecimal.startIndex
        for _ in 0..<6 {
            let end = hexadecimal.index(index, offsetBy: 2)
            groups.append(String(hexadecimal[index..<end]))
            index = end
        }
        return groups.joined(separator: ":")
    }

    private static func embeddedInt(_ payload: MessagePackValue) -> Int? {
        if let value = payload.intValue { return value }
        guard let text = payload.stringValue else { return nil }
        return text.split(whereSeparator: { !$0.isNumber && $0 != "-" }).last.flatMap { Int($0) }
    }

    private static func sourceName(_ value: Int?) -> String {
        switch value {
        case 2: "AUX"
        case 5: "USB"
        case 6: "Bluetooth A2DP 1"
        case 7: "Bluetooth A2DP 2"
        default: value.map { "Unknown (\($0))" } ?? "—"
        }
    }

    private static func codecName(_ value: Int?) -> String {
        switch value {
        case 0, nil: "—"
        case 1: "SBC"
        case 3: "AAC"
        case 5: "aptX"
        case 7: "aptX HD"
        case 8: "aptX Low Latency"
        case 9: "aptX Adaptive"
        default: value.map { "Unknown (\($0))" } ?? "—"
        }
    }

    private func handlePeripheralEvent(
        _ event: BWPeripheralEvent,
        from callbackPeripheral: CBPeripheral,
        generation: Int
    ) {
        guard isCurrentPeripheralCallback(callbackPeripheral, generation: generation) else { return }

        switch event {
        case .discoveredServices(let error):
            guard phase == .discovering else { return }
            if let error {
                failTransport(error.localizedDescription, peripheral: callbackPeripheral)
                return
            }
            guard let services = callbackPeripheral.services, !services.isEmpty else {
                failTransport("No BLE services found", peripheral: callbackPeripheral)
                return
            }
            services.forEach { callbackPeripheral.discoverCharacteristics(nil, for: $0) }

        case .discoveredCharacteristics(let service, let error):
            guard phase == .discovering, service.peripheral === callbackPeripheral else { return }
            if let error {
                addLog(.info, "Characteristic discovery failed: \(error.localizedDescription)")
                return
            }
            for characteristic in service.characteristics ?? [] {
                switch characteristic.uuid.uuidString.lowercased() {
                case BWRPC.requestUUID:
                    requestCharacteristic = characteristic
                    transportReadiness.requestDiscovered = true
                case BWRPC.responseUUID:
                    guard responseCharacteristic !== characteristic else { continue }
                    responseCharacteristic = characteristic
                    transportReadiness.responseDiscovered = true
                    transportReadiness.responseNotificationsConfirmed = false
                    callbackPeripheral.setNotifyValue(true, for: characteristic)
                case BWRPC.notificationUUID:
                    guard eventCharacteristic !== characteristic else { continue }
                    eventCharacteristic = characteristic
                    callbackPeripheral.setNotifyValue(true, for: characteristic)
                default:
                    break
                }
            }
            transportMayBeReady()

        case .updatedNotificationState(let characteristic, let error):
            if characteristic === eventCharacteristic {
                if let error {
                    addLog(.info, "Event notification setup failed: \(error.localizedDescription)")
                }
                return
            }
            guard characteristic === responseCharacteristic,
                phase == .discovering || phase == .ready
            else { return }

            if let error {
                failTransport(
                    "RPC notification setup failed: \(error.localizedDescription)",
                    peripheral: callbackPeripheral
                )
                return
            }
            guard characteristic.isNotifying else {
                failTransport("RPC notifications are unavailable", peripheral: callbackPeripheral)
                return
            }
            transportReadiness.responseNotificationsConfirmed = true
            transportMayBeReady()

        case .updatedValue(let characteristic, let error):
            guard phase == .ready,
                characteristic === responseCharacteristic || characteristic === eventCharacteristic
            else { return }
            if let error {
                addLog(.info, "GATT notification error: \(error.localizedDescription)")
                return
            }
            if let data = characteristic.value { handle(data) }

        case .wroteValue(let characteristic, let error):
            guard phase == .ready,
                characteristic === requestCharacteristic,
                writeInFlight
            else { return }
            cancelWriteTimeout()
            writeInFlight = false
            if let error {
                failTransport("GATT write failed: \(error.localizedDescription)", peripheral: callbackPeripheral)
                return
            }
            pumpWriteQueue()

        case .readyToWriteWithoutResponse:
            guard phase == .ready else { return }
            pumpWriteQueue()
        }
    }

    private func isCurrentPeripheralCallback(_ callbackPeripheral: CBPeripheral, generation: Int) -> Bool {
        guard isCurrentPeripheralSession(callbackPeripheral),
            let activeSessionIdentity,
            activeSessionIdentity.accepts(
                peripheralID: callbackPeripheral.identifier,
                generation: generation
            ),
            let peripheralDelegateProxy,
            peripheralDelegateProxy.generation == generation,
            callbackPeripheral.delegate === peripheralDelegateProxy
        else { return false }
        return true
    }

    private func isCurrentPeripheralSession(_ candidate: CBPeripheral) -> Bool {
        guard let activeSessionIdentity,
            activeSessionIdentity.accepts(
                peripheralID: candidate.identifier,
                generation: transportGeneration
            ),
            peripheral === candidate
        else { return false }
        return true
    }

    private func failTransport(_ message: String, peripheral failedPeripheral: CBPeripheral) {
        guard peripheral === failedPeripheral else { return }
        cancelConnectionTimeout()
        let releasedPeripheral = releasePeripheral()
        phase = .failed(message)
        if let releasedPeripheral {
            beginTeardown(of: releasedPeripheral, reconnectWhenFinished: true)
        } else {
            scheduleAutomaticReconnect()
        }
    }

    private func addLog(_ direction: TransportLogEntry.Direction, _ text: String) {
        guard diagnosticsEnabled else { return }
        log.append(TransportLogEntry(time: Date(), direction: direction, text: text))
        if log.count > 300 { log.removeFirst(log.count - 300) }
    }
}

extension BowersWilkinsProvider: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            guard self.central === central else { return }
            switch central.state {
            case .poweredOn:
                automaticConnection.resetCandidates()
                cancelAutomaticReconnect()
                if phase == .bluetoothUnavailable {
                    phase = .idle
                }
                if audioConnectedDeviceNames.isEmpty {
                    phase = .idle
                } else {
                    startScanning(automatically: true)
                }
            case .unsupported, .unauthorized, .poweredOff, .resetting:
                cancelAutomaticReconnect()
                cancelScanTimeout()
                cancelConnectionTimeout()
                pendingConnection = nil
                automaticConnection.resetForBluetoothRadioTransition()
                central.stopScan()
                _ = releasePeripheral()
                cancelTeardownTracking()
                phase = .bluetoothUnavailable
            default: break
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        Task { @MainActor in
            guard self.central === central, self.phase == .scanning else { return }
            let advertised = advertisementData[CBAdvertisementDataLocalNameKey] as? String
            let name = advertised ?? peripheral.name ?? "Unnamed BLE device"
            guard Self.isSupportedHeadphoneName(name) else { return }
            let item = DiscoveredPeripheral(
                id: peripheral.identifier, name: name, rssi: RSSI.intValue, peripheral: peripheral)
            discovered[peripheral.identifier] = item
            peripherals = discovered.values.sorted { $0.rssi > $1.rssi }
            if selectedPeripheralID == nil,
                Self.isSupportedHeadphoneName(name)
            {
                selectedPeripheralID = peripheral.identifier
            }
            tryAutomaticConnection()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            if self.teardownPeripheral === peripheral {
                central.cancelPeripheralConnection(peripheral)
                return
            }
            guard self.central === central,
                self.isCurrentPeripheralSession(peripheral),
                self.phase == .connecting
            else {
                central.cancelPeripheralConnection(peripheral)
                return
            }
            cancelConnectionTimeout()
            cancelAutomaticReconnect(resetAttempt: false)
            phase = .discovering
            addLog(.info, "Connected; discovering every GATT service")
            armConnectionTimeout(
                for: peripheral.identifier,
                expectedPhase: .discovering,
                after: Self.discoveryTimeout,
                failureMessage: "RPC discovery timed out"
            )
            peripheral.discoverServices(nil)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
    ) {
        Task { @MainActor in
            if self.central === central, self.teardownPeripheral === peripheral {
                self.finishTeardown(of: peripheral)
                return
            }
            guard self.central === central,
                self.isCurrentPeripheralSession(peripheral),
                self.phase == .connecting
            else { return }
            cancelConnectionTimeout()
            _ = releasePeripheral()
            phase = .failed(error?.localizedDescription ?? "Connection failed")
            scheduleAutomaticReconnect()
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
    ) {
        Task { @MainActor in
            if self.central === central, self.teardownPeripheral === peripheral {
                self.finishTeardown(of: peripheral)
                return
            }
            guard self.central === central,
                self.isCurrentPeripheralSession(peripheral)
            else { return }
            cancelConnectionTimeout()
            let nextConnection = pendingConnection
            pendingConnection = nil
            _ = releasePeripheral()
            if let nextConnection {
                phase = .idle
                connect(nextConnection.item, automatically: nextConnection.automatically)
                return
            }
            phase = error.map { .failed($0.localizedDescription) } ?? .idle
            scheduleAutomaticReconnect()
        }
    }
}

extension BowersWilkinsProvider: HeadphoneProvider {
    var providerID: String { "bowers-wilkins" }
    var vendorName: String { "Bowers & Wilkins" }
    var connectedDeviceID: String? {
        Self.persistentDeviceIdentifier(macAddress: macAddress, serialNumber: serialNumber)
    }

    var connectionState: HeadphoneConnectionState {
        switch phase {
        case .bluetoothUnavailable, .idle: .idle
        case .scanning: .scanning
        case .connecting, .discovering: .connecting
        case .ready: .ready
        case .failed(let message): .failed(message)
        }
    }

    var codecName: String? { audioCodec == "—" ? nil : audioCodec }

    var connectionStatePublisher: AnyPublisher<HeadphoneConnectionState, Never> {
        $phase
            .map { phase in
                switch phase {
                case .bluetoothUnavailable, .idle: .idle
                case .scanning: .scanning
                case .connecting, .discovering: .connecting
                case .ready: .ready
                case .failed(let message): .failed(message)
                }
            }
            .eraseToAnyPublisher()
    }

    var capabilities: HeadphoneCapabilities {
        func supports(_ command: BWRPCCommand) -> Bool {
            readings[command.key]?.errorCode == 0
        }

        var result: HeadphoneCapabilities = []
        if supports(BWRPCatalog.batteryPercentageGet) { result.insert(.battery) }
        if supports(BWRPCatalog.ancGet) { result.insert(.noiseControl) }
        if supports(BWRPCatalog.eqGet) { result.insert(.equalizer) }
        if supports(BWRPCatalog.wearGet) { result.insert(.wearSensor) }
        if supports(BWRPCatalog.spatialEnabledGet) { result.insert(.spatialAudio) }
        if supports(BWRPCatalog.voiceGet) { result.insert(.voicePrompts) }
        if supports(BWRPCatalog.sleepGet) { result.insert(.standbyTimer) }
        if supports(BWRPCatalog.buttonGet) { result.insert(.customButton) }
        if supports(BWRPCatalog.nameGet) { result.insert(.deviceName) }
        return result
    }

    var noiseMode: HeadphoneNoiseMode? {
        switch ancMode {
        case .off: .off
        case .noiseCancellation: .noiseCancellation
        case .passThrough: .ambient
        }
    }

    var supportedNoiseModes: [HeadphoneNoiseMode] {
        [.off, .ambient, .noiseCancellation]
    }

    func matches(audioDevice: SystemAudioDevice) -> Bool {
        Self.isSupportedHeadphoneName(audioDevice.name)
    }

    func refresh() {
        refreshPrimary()
    }

    func refreshBatteryStatus() {
        guard isReady else { return }
        send(BWRPCatalog.batteryPercentageGet)
        send(BWRPCatalog.chargingStatusGet)
    }

    func setNoiseMode(_ mode: HeadphoneNoiseMode) {
        switch mode {
        case .off: setANC(.off)
        case .noiseCancellation: setANC(.noiseCancellation)
        case .ambient: setANC(.passThrough)
        case .windReduction: break
        }
    }
}
