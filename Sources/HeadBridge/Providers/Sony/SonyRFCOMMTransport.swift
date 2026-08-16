import Foundation
import IOBluetooth
import OSLog

enum SonyRFCOMMStatus: Equatable {
    case idle
    case connecting
    case connected
    case failed(String)
}

/// A single-owner RFCOMM transport for Sony's MDR control service.
///
/// Keeping ownership here is important: closing or replacing a session always
/// closes the old channel first, preventing the leaked DLCIs that eventually
/// make IOBluetooth report that the system reached its session limit.
@MainActor
final class SonyRFCOMMTransport: NSObject {
    var onStatusChange: ((SonyRFCOMMStatus) -> Void)?
    var onData: ((Data) -> Void)?

    private static let v1ServiceUUIDBytes: [UInt8] = [
        0x96, 0xCC, 0x20, 0x3E,
        0x50, 0x68,
        0x46, 0xAD,
        0xB3, 0x2D,
        0xE3, 0x16, 0xF5, 0xE0, 0x69, 0xBA,
    ]
    private static let v2ServiceUUIDBytes: [UInt8] = [
        0x95, 0x6C, 0x7B, 0x26,
        0xD4, 0x9A,
        0x4B, 0xA8,
        0xB0, 0x3F,
        0xB1, 0x7D, 0x39, 0x3C, 0xB6, 0xE2,
    ]

    private(set) var status: SonyRFCOMMStatus = .idle
    private var device: IOBluetoothDevice?
    private var channel: IOBluetoothRFCOMMChannel?
    private var openTimeoutTask: Task<Void, Never>?
    private var generation = 0
    private var requestedDisconnect = false
    private let logger = Logger(subsystem: "io.github.herenickname.HeadBridge", category: "SonyRFCOMM")

    deinit {
        openTimeoutTask?.cancel()
        channel?.setDelegate(nil)
        channel?.close()
    }

    func connect(address: String) {
        disconnect(notify: false)
        generation &+= 1
        let expectedGeneration = generation
        requestedDisconnect = false

        guard let device = IOBluetoothDevice(addressString: address) else {
            updateStatus(.failed("Invalid Bluetooth address"))
            return
        }

        self.device = device
        updateStatus(.connecting)
        logger.info("Opening Sony RFCOMM control channel")

        openTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self,
                !Task.isCancelled,
                self.generation == expectedGeneration,
                self.status == .connecting
            else { return }
            self.fail("Sony RFCOMM open timed out")
        }

        if !findServiceAndOpen(on: device) {
            let result = device.performSDPQuery(self)
            guard result == kIOReturnSuccess else {
                fail("Could not start Sony service discovery (\(result))")
                return
            }
        }
    }

    func disconnect() {
        disconnect(notify: true)
    }

    @discardableResult
    func send(_ data: Data) -> IOReturn {
        guard status == .connected, let channel else {
            return kIOReturnNotOpen
        }
        guard data.count <= Int(UInt16.max) else {
            return kIOReturnMessageTooLarge
        }

        var bytes = [UInt8](data)
        let result = bytes.withUnsafeMutableBufferPointer { buffer -> IOReturn in
            guard let baseAddress = buffer.baseAddress else { return kIOReturnNoMemory }
            return channel.writeSync(baseAddress, length: UInt16(buffer.count))
        }
        if result != kIOReturnSuccess {
            logger.error("Sony RFCOMM write failed: \(result)")
        }
        return result
    }

    private func disconnect(notify: Bool) {
        requestedDisconnect = true
        generation &+= 1
        openTimeoutTask?.cancel()
        openTimeoutTask = nil

        let oldChannel = channel
        channel = nil
        oldChannel?.setDelegate(nil)
        oldChannel?.close()
        device = nil

        if notify {
            updateStatus(.idle)
        } else {
            status = .idle
        }
    }

    @discardableResult
    private func findServiceAndOpen(on device: IOBluetoothDevice) -> Bool {
        guard let record = serviceRecord(on: device, uuidBytes: Self.v1ServiceUUIDBytes) else {
            if serviceRecord(on: device, uuidBytes: Self.v2ServiceUUIDBytes) != nil {
                fail("Sony MDR V2 detected; this build currently implements the V1 protocol adapter")
                return true
            }
            return false
        }

        var channelID: BluetoothRFCOMMChannelID = 0
        guard record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess else {
            fail("Sony service has no RFCOMM channel")
            return true
        }

        var openedChannel: IOBluetoothRFCOMMChannel?
        let result = device.openRFCOMMChannelAsync(
            &openedChannel,
            withChannelID: channelID,
            delegate: self
        )
        guard result == kIOReturnSuccess else {
            fail("Could not open Sony RFCOMM channel (\(result))")
            return true
        }
        channel = openedChannel
        return true
    }

    private func serviceRecord(
        on device: IOBluetoothDevice,
        uuidBytes: [UInt8]
    ) -> IOBluetoothSDPServiceRecord? {
        let uuid = IOBluetoothSDPUUID(bytes: uuidBytes, length: uuidBytes.count)
        return device.getServiceRecord(for: uuid)
    }

    private func updateStatus(_ newStatus: SonyRFCOMMStatus) {
        guard status != newStatus else { return }
        status = newStatus
        onStatusChange?(newStatus)
    }

    private func fail(_ message: String) {
        generation &+= 1
        requestedDisconnect = false
        openTimeoutTask?.cancel()
        openTimeoutTask = nil
        let oldChannel = channel
        channel = nil
        oldChannel?.setDelegate(nil)
        oldChannel?.close()
        device = nil
        logger.error("Sony transport failed: \(message, privacy: .public)")
        updateStatus(.failed(message))
    }

    private func handleSDPResult(device: IOBluetoothDevice?, status result: IOReturn) {
        guard status == .connecting, let expectedDevice = self.device,
            device === expectedDevice
        else { return }
        guard result == kIOReturnSuccess else {
            fail("Sony service discovery failed (\(result))")
            return
        }
        if !findServiceAndOpen(on: expectedDevice) {
            fail("No supported Sony MDR control service was found")
        }
    }

    private func handleOpen(channel openedChannel: IOBluetoothRFCOMMChannel?, error: IOReturn) {
        guard let openedChannel else {
            if status == .connecting {
                fail("Sony RFCOMM open failed (\(error))")
            }
            return
        }
        guard status == .connecting, openedChannel === channel else {
            // An async open can complete after disconnect or after a newer
            // generation has replaced its channel. Close that late channel
            // explicitly instead of leaking an RFCOMM session.
            openedChannel.setDelegate(nil)
            openedChannel.close()
            return
        }
        guard error == kIOReturnSuccess else {
            fail("Sony RFCOMM open failed (\(error))")
            return
        }
        openTimeoutTask?.cancel()
        openTimeoutTask = nil
        updateStatus(.connected)
    }

    private func handleData(channel sourceChannel: IOBluetoothRFCOMMChannel?, data: Data) {
        guard status == .connected,
            let sourceChannel,
            sourceChannel === channel
        else { return }
        onData?(data)
    }

    private func handleClosed(channel closedChannel: IOBluetoothRFCOMMChannel?) {
        guard let closedChannel, closedChannel === channel else { return }
        channel = nil
        device = nil
        generation &+= 1
        openTimeoutTask?.cancel()
        openTimeoutTask = nil

        if requestedDisconnect {
            updateStatus(.idle)
        } else {
            updateStatus(.failed("Sony RFCOMM channel closed"))
        }
    }
}

extension SonyRFCOMMTransport: IOBluetoothRFCOMMChannelDelegate {
    nonisolated func rfcommChannelOpenComplete(
        _ rfcommChannel: IOBluetoothRFCOMMChannel!,
        status error: IOReturn
    ) {
        Task { @MainActor [weak self] in
            self?.handleOpen(channel: rfcommChannel, error: error)
        }
    }

    nonisolated func rfcommChannelData(
        _ rfcommChannel: IOBluetoothRFCOMMChannel!,
        data dataPointer: UnsafeMutableRawPointer!,
        length dataLength: Int
    ) {
        guard let dataPointer, dataLength > 0 else { return }
        let data = Data(bytes: dataPointer, count: dataLength)
        Task { @MainActor [weak self] in
            self?.handleData(channel: rfcommChannel, data: data)
        }
    }

    nonisolated func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        Task { @MainActor [weak self] in
            self?.handleClosed(channel: rfcommChannel)
        }
    }

    @objc nonisolated func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        Task { @MainActor [weak self] in
            self?.handleSDPResult(device: device, status: status)
        }
    }
}
