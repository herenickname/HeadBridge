import CoreBluetooth
import Foundation
import JavaScriptCore

struct HatorDeviceSnapshot {
    var fields: [UInt8: [UInt8]] = [:]
    var vendor: [UInt8: UInt8] = [:]

    var batteryPercent: Int? {
        guard let value = fields[0x00]?.first, value <= 100 else { return nil }
        return Int(value)
    }

    var noiseMode: HeadphoneNoiseMode? {
        guard let value = fields[0x0D]?.first else { return nil }
        switch value {
        case 0: return .off
        case 1: return .noiseCancellation
        case 2: return .ambient
        default: return nil
        }
    }

    func vendorBool(_ code: UInt8) -> Bool? {
        guard let value = vendor[code] else { return nil }
        if code == 0x02 { return value == 0x02 ? true : value == 0 ? false : nil }
        return value == 1 ? true : value == 0 ? false : nil
    }
}

/// Single-owner BLE transport for Phoenix 2. All delegate events are delivered on the main queue.
final class HatorBLEClient: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static func shouldVerifyOnAck(code: UInt8) -> Bool { code != 0x02 }
    static func verificationDelay(for code: UInt8) -> TimeInterval { code == 0x02 ? 9.5 : 0.5 }
    var onConnection: ((HeadphoneConnectionState) -> Void)?
    var onSnapshot: ((HatorDeviceSnapshot) -> Void)?
    var onVerifiedWrite: ((UInt8, UInt8, Bool) -> Void)?
    var connectedIdentifier: UUID? { hasReadySession ? peripheral?.identifier : nil }
    var spatialWritesAllowed = false

    func cancelQueuedVendor(_ code: UInt8) {
        desiredWrites.removeValue(forKey: code)
        writeOrder.removeAll(where: { $0 == code })
    }

    private enum Phase: Equatable {
        case idle, scanning, connecting, discovering
        case authDevice, authChallenge, authConfirmation
        case targetInfo, systemInfo, vendorRead, ready, writing, verifyWrite, retrying
    }

    private let serviceUUID = CBUUID(string: "AE00")
    private let txUUID = CBUUID(string: "AE01")
    private let rxUUID = CBUUID(string: "AE02")
    private let cachedUUIDKey = "HeadBridge.HatorPhoenix2.BLEUUID"
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var tx: CBCharacteristic?
    private var js: JSContext?
    private var phase: Phase = .idle
    private var parser = HatorRCSPParser()
    private var nonce: [UInt8] = []
    private var sequence = UInt8.random(in: 0x30...0xD0)
    private var requestSequence: UInt8 = 0
    private var vendorIndex = 0
    private let vendorCodes: [UInt8] = [0x02, 0x05, 0x08]
    private var snapshot = HatorDeviceSnapshot()
    private var desiredWrites: [UInt8: UInt8] = [:]
    private var writeOrder: [UInt8] = []
    private var activeWrite: (code: UInt8, value: UInt8)?
    private var generation = 0
    private var retryCount = 0
    private var isStarted = false
    private var isShutdown = false
    private var attemptedCached = false
    private var scanOnNextAttempt = false
    private var needsRefresh = false
    private var refreshScheduled = false
    private var hasReadySession = false

    func start() {
        guard !isShutdown, !isStarted else { return }
        isStarted = true
        guard loadAuth() else {
            isStarted = false
            onConnection?(.failed("JieLi authentication module missing"))
            return
        }
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        } else if central?.state == .poweredOn {
            beginConnect()
        }
    }

    func stop() {
        isStarted = false
        generation &+= 1
        central?.stopScan()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral?.delegate = nil
        peripheral = nil
        tx = nil
        parser.reset()
        nonce.removeAll()
        snapshot = HatorDeviceSnapshot()
        desiredWrites.removeAll()
        writeOrder.removeAll()
        activeWrite = nil
        phase = .idle
        hasReadySession = false
        needsRefresh = false
        refreshScheduled = false
        onSnapshot?(snapshot)
        onConnection?(.idle)
    }

    func shutdown() {
        stop()
        isShutdown = true
        central?.delegate = nil
        central = nil
        js = nil
    }

    func refresh() {
        guard phase == .ready else { needsRefresh = true; return }
        requestSystemInfo()
    }

    /// Only three independently verified reversible vendor controls.
    func setVendor(_ code: UInt8, value: UInt8) {
        guard isStarted, [0x02, 0x05, 0x08].contains(code),
            code != 0x02 || spatialWritesAllowed
        else { return }
        guard
            (code == 0x02 && [0, 2].contains(value))
                || (code != 0x02 && [0, 1].contains(value))
        else { return }
        if desiredWrites[code] == nil {
            guard writeOrder.count < 3 else { return }
            writeOrder.append(code)
        }
        desiredWrites[code] = value
        processWritesIfReady()
    }

    private func loadAuth() -> Bool {
        if js != nil { return true }
        #if SWIFT_PACKAGE
            let resource = Bundle.module.url(forResource: "jl-auth-bundle", withExtension: "js")
        #else
            let resource = Bundle.main.url(forResource: "jl-auth-bundle", withExtension: "js")
        #endif
        guard let resource,
            let script = try? String(contentsOf: resource, encoding: .utf8),
            let context = JSContext()
        else { return false }
        context.evaluateScript(script)
        guard context.exception == nil,
            context.evaluateScript("typeof JieLiAuth.getEncryptedAuthData")?.toString() == "function"
        else { return false }
        js = context
        return true
    }

    private func encrypt(_ challenge: [UInt8]) -> [UInt8]? {
        guard challenge.count == 17, challenge.first == 0, let js else { return nil }
        let input = challenge.map(String.init).joined(separator: ",")
        let expression = "Array.from(JieLiAuth.getEncryptedAuthData(new Uint8Array([\(input)])))"
        guard let response = js.evaluateScript(expression), js.exception == nil,
            let values = response.toArray() as? [NSNumber], values.count == 17
        else { return nil }
        return values.map(\.uint8Value)
    }

    private func nextSequence() -> UInt8 {
        sequence &+= 1
        return sequence
    }

    private func beginConnect() {
        guard isStarted, !isShutdown, central?.state == .poweredOn else { return }
        generation &+= 1
        let token = generation
        parser.reset()
        nonce = []
        hasReadySession = false
        needsRefresh = false
        refreshScheduled = false
        tx = nil
        snapshot = HatorDeviceSnapshot()
        activeWrite = nil
        peripheral = nil
        attemptedCached = false

        let uuid = UserDefaults.standard.string(forKey: cachedUUIDKey).flatMap(UUID.init(uuidString:))
        if !scanOnNextAttempt, let uuid,
            let cached = central?.retrievePeripherals(withIdentifiers: [uuid]).first
        {
            peripheral = cached
            attemptedCached = true
            phase = .connecting
            onConnection?(.connecting)
            central?.connect(cached, options: nil)
        } else {
            scanOnNextAttempt = false
            phase = .scanning
            onConnection?(.scanning)
            central?.scanForPeripherals(withServices: nil, options: nil)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 18) { [weak self] in
            guard let self, self.generation == token,
                self.phase != .ready, self.phase != .retrying, self.phase != .idle
            else { return }
            self.retry()
        }
    }

    private func retry() {
        guard isStarted, !isShutdown, phase != .retrying else { return }
        if attemptedCached { scanOnNextAttempt = true }
        retryCount = min(retryCount + 1, 6)
        generation &+= 1
        let token = generation
        phase = .retrying
        onConnection?(.connecting)
        central?.stopScan()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral?.delegate = nil
        peripheral = nil
        tx = nil
        parser.reset()
        snapshot = HatorDeviceSnapshot()
        activeWrite = nil
        desiredWrites.removeAll()
        writeOrder.removeAll()
        hasReadySession = false
        needsRefresh = false
        refreshScheduled = false
        onSnapshot?(snapshot)
        let delay = min(30.0, pow(2.0, Double(retryCount - 1)))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == token, self.isStarted else { return }
            if self.central?.state == .poweredOn { self.beginConnect() } else { self.waitForBluetooth(token: token) }
        }
    }

    private func waitForBluetooth(token: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.generation == token, self.isStarted else { return }
            if self.central?.state == .poweredOn { self.beginConnect() } else { self.waitForBluetooth(token: token) }
        }
    }

    private func send(_ bytes: [UInt8]) {
        guard isStarted, let peripheral, let tx else { return }
        peripheral.writeValue(Data(bytes), for: tx, type: .withoutResponse)
    }

    private func requestTargetInfo() {
        phase = .targetInfo
        requestSequence = nextSequence()
        send(HatorRCSP.targetInfo(sequence: requestSequence))
    }

    private func requestSystemInfo() {
        phase = .systemInfo
        requestSequence = nextSequence()
        send(HatorRCSP.systemInfo(sequence: requestSequence))
        let token = generation
        let expected = requestSequence
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.generation == token, self.phase == .systemInfo,
                self.requestSequence == expected
            else { return }
            self.retry()
        }
    }

    private func requestNextVendor() {
        guard vendorIndex < vendorCodes.count else {
            phase = .ready
            let firstReady = !hasReadySession
            hasReadySession = true
            retryCount = 0
            if let id = peripheral?.identifier {
                UserDefaults.standard.set(id.uuidString, forKey: cachedUUIDKey)
            }
            onSnapshot?(snapshot)
            if firstReady { onConnection?(.ready) }
            scheduleRefresh()
            processWritesIfReady()
            return
        }
        phase = .vendorRead
        let code = vendorCodes[vendorIndex]
        requestSequence = nextSequence()
        send(HatorRCSP.vendorGet(code, sequence: requestSequence))
        let token = generation
        let index = vendorIndex
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.generation == token,
                self.phase == .vendorRead, self.vendorIndex == index
            else { return }
            self.vendorIndex += 1
            self.requestNextVendor()
        }
    }

    private func scheduleRefresh() {
        // A status GET, manual refresh, or a write may all finish in the same
        // interval. Keep only one periodic poll in flight per BLE session.
        guard !refreshScheduled else { return }
        refreshScheduled = true
        let token = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.generation == token, self.isStarted else { return }
            self.refreshScheduled = false
            if self.phase == .ready {
                self.requestSystemInfo()
            } else {
                self.needsRefresh = true
            }
        }
    }

    private func processWritesIfReady() {
        guard phase == .ready, activeWrite == nil else { return }
        if needsRefresh {
            needsRefresh = false
            requestSystemInfo()
            return
        }
        guard !writeOrder.isEmpty else { return }
        let code = writeOrder.removeFirst()
        guard let value = desiredWrites.removeValue(forKey: code) else { return }
        if code == 0x02 && !spatialWritesAllowed {
            processWritesIfReady()
            return
        }
        activeWrite = (code, value)
        phase = .writing
        requestSequence = nextSequence()
        send(HatorRCSP.vendorSet(code, value: value, sequence: requestSequence))
        let token = generation
        let expected = requestSequence
        // Spatial ON may take several seconds to calibrate on this firmware.
        // Do not mistake an immediate pre-calibration GET for the final state.
        let verificationDelay = Self.verificationDelay(for: code)
        DispatchQueue.main.asyncAfter(deadline: .now() + verificationDelay) { [weak self] in
            guard let self, self.generation == token,
                self.phase == .writing, self.requestSequence == expected
            else { return }
            self.verifyActiveWrite()
        }
    }

    private func verifyActiveWrite() {
        guard let activeWrite else { return }
        phase = .verifyWrite
        requestSequence = nextSequence()
        send(HatorRCSP.vendorGet(activeWrite.code, sequence: requestSequence))
        let token = generation
        let expected = requestSequence
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.generation == token,
                self.phase == .verifyWrite, self.requestSequence == expected
            else { return }
            self.completeWrite(confirmed: false, readback: nil)
        }
    }

    private func completeWrite(confirmed: Bool, readback: UInt8?) {
        guard let activeWrite else { return }
        if let readback { snapshot.vendor[activeWrite.code] = readback }
        onSnapshot?(snapshot)
        onVerifiedWrite?(activeWrite.code, activeWrite.value, confirmed)
        self.activeWrite = nil
        phase = .ready
        processWritesIfReady()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard isStarted else { return }
        if central.state == .poweredOn, phase == .idle || phase == .retrying {
            beginConnect()
        } else if central.state != .poweredOn, phase != .idle, phase != .retrying {
            retry()
        }
    }

    func centralManager(
        _ central: CBCentralManager, didDiscover device: CBPeripheral,
        advertisementData: [String: Any], rssi: NSNumber
    ) {
        guard isStarted, phase == .scanning else { return }
        let name = device.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""
        guard BluetoothDeviceNameMatcher.normalized(name) == "hatorphoenix2" else { return }
        central.stopScan()
        peripheral = device
        phase = .connecting
        onConnection?(.connecting)
        central.connect(device, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect device: CBPeripheral) {
        guard isStarted, peripheral === device, phase == .connecting else { return }
        phase = .discovering
        device.delegate = self
        device.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect device: CBPeripheral, error: Error?) {
        guard peripheral === device else { return }
        retry()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral device: CBPeripheral, error: Error?) {
        guard peripheral === device else { return }
        retry()
    }

    func peripheral(_ device: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === device, phase == .discovering, error == nil,
            let service = device.services?.first(where: { $0.uuid == serviceUUID })
        else {
            retry()
            return
        }
        device.discoverCharacteristics([txUUID, rxUUID], for: service)
    }

    func peripheral(_ device: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === device, phase == .discovering, error == nil,
            let write = service.characteristics?.first(where: { $0.uuid == txUUID }),
            let read = service.characteristics?.first(where: { $0.uuid == rxUUID })
        else {
            retry()
            return
        }
        tx = write
        device.setNotifyValue(true, for: read)
    }

    func peripheral(
        _ device: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard peripheral === device, phase == .discovering else { return }
        guard error == nil, characteristic.uuid == rxUUID, characteristic.isNotifying else {
            retry()
            return
        }
        nonce = (0..<16).map { _ in UInt8.random(in: 0...255) }
        phase = .authDevice
        send([0] + nonce)
    }

    func peripheral(
        _ device: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard peripheral === device, characteristic.uuid == rxUUID,
            error == nil, let data = characteristic.value
        else { return }
        let bytes = [UInt8](data)
        switch phase {
        case .authDevice:
            guard bytes.count == 17, bytes.first == 1,
                encrypt([0] + nonce) == bytes
            else { retry(); return }
            phase = .authChallenge
            send([2, 0x70, 0x61, 0x73, 0x73])
        case .authChallenge:
            if bytes.first == 0xFE { return }
            guard bytes.count == 17, bytes.first == 0,
                let proof = encrypt(bytes)
            else { retry(); return }
            phase = .authConfirmation
            send(proof)
        case .authConfirmation:
            if bytes.first == 0xFE { return }
            guard bytes == [2, 0x70, 0x61, 0x73, 0x73] else { retry(); return }
            requestTargetInfo()
        default:
            for frame in parser.append(bytes) { handle(frame) }
        }
    }

    private func handle(_ frame: HatorRCSPFrame) {
        if frame.isCommand, frame.opcode == 0xFF, frame.parameters.count == 2 {
            send(HatorRCSP.acknowledgeVendor(sequence: frame.sequence))
            let code = frame.parameters[0]
            let value = frame.parameters[1]
            if phase == .vendorRead, vendorIndex < vendorCodes.count,
                code == vendorCodes[vendorIndex], value != 0xFF
            {
                snapshot.vendor[code] = value
                vendorIndex += 1
                requestNextVendor()
            } else if phase == .verifyWrite, let activeWrite,
                code == activeWrite.code, value != 0xFF
            {
                completeWrite(confirmed: value == activeWrite.value, readback: value)
            } else if phase == .ready, [0x02, 0x05, 0x08].contains(code) {
                snapshot.vendor[code] = value
                onSnapshot?(snapshot)
            }
            return
        }
        guard !frame.isCommand else { return }
        switch phase {
        case .targetInfo:
            guard frame.opcode == 0x03, frame.sequence == requestSequence,
                frame.status == 0
            else { return }
            requestSystemInfo()
        case .systemInfo:
            guard frame.opcode == 0x07, frame.sequence == requestSequence,
                frame.status == 0, let fields = HatorRCSP.systemFields(frame.parameters)
            else { return }
            snapshot.fields = fields
            snapshot.vendor = [:]
            vendorIndex = 0
            requestNextVendor()
        case .writing:
            if frame.opcode == 0xFF, frame.sequence == requestSequence, frame.status == 0,
                activeWrite.map({ Self.shouldVerifyOnAck(code: $0.code) }) == true
            {
                // Spatial ON may need calibration before a fresh GET confirms
                // the new state; the acknowledgement alone must not bypass
                // the delayed verification scheduled for that command.
                verifyActiveWrite()
            }
        default: break
        }
    }
}
