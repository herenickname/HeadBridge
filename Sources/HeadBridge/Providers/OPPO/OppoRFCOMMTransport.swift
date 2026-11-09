import Foundation
import IOBluetooth

enum OppoRFCOMMStatus: Equatable {
    case idle
    case connecting
    case connected
    case failed(String)
}

/// Single-owner RFCOMM transport for the OPPO earphone control service.
///
/// The earbuds expose the vendor service over Bluetooth Classic, not BLE, so
/// the channel is resolved through SDP and then held open for pushes. Closing
/// the previous channel before opening another avoids leaked RFCOMM sessions.
@MainActor
final class OppoRFCOMMTransport: NSObject {
    var onStatusChange: ((OppoRFCOMMStatus) -> Void)?
    var onData: ((Data) -> Void)?

    private static let serviceUUIDBytes: [UInt8] = [
        0x00, 0x00, 0x07, 0x9A,
        0xD1, 0x02,
        0x11, 0xE1,
        0x9B, 0x23,
        0x00, 0x02, 0x5B, 0x00, 0xA5, 0xA5,
    ]

    private(set) var status: OppoRFCOMMStatus = .idle
    private var device: IOBluetoothDevice?
    private var channel: IOBluetoothRFCOMMChannel?
    private var openTimeoutTask: Task<Void, Never>?
    private var generation = 0
    private var requestedDisconnect = false

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

        openTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self,
                !Task.isCancelled,
                self.generation == expectedGeneration,
                self.status == .connecting
            else { return }
            self.fail("OPPO RFCOMM open timed out")
        }

        if !findServiceAndOpen(on: device) {
            let result = device.performSDPQuery(self)
            guard result == kIOReturnSuccess else {
                fail("Could not start OPPO service discovery (\(result))")
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
        guard let record = serviceRecord(on: device) else { return false }

        var channelID: BluetoothRFCOMMChannelID = 0
        guard record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess else {
            fail("OPPO control service has no RFCOMM channel")
            return true
        }

        var openedChannel: IOBluetoothRFCOMMChannel?
        let result = device.openRFCOMMChannelAsync(
            &openedChannel,
            withChannelID: channelID,
            delegate: self
        )
        guard result == kIOReturnSuccess else {
            fail("Could not open OPPO RFCOMM channel (\(result))")
            return true
        }
        channel = openedChannel
        return true
    }

    private func serviceRecord(on device: IOBluetoothDevice) -> IOBluetoothSDPServiceRecord? {
        let uuid = IOBluetoothSDPUUID(bytes: Self.serviceUUIDBytes, length: Self.serviceUUIDBytes.count)
        return device.getServiceRecord(for: uuid)
    }

    private func updateStatus(_ newStatus: OppoRFCOMMStatus) {
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
        updateStatus(.failed(message))
    }

    private func handleSDPResult(device: IOBluetoothDevice?, status result: IOReturn) {
        guard status == .connecting, let expectedDevice = self.device,
            device === expectedDevice
        else { return }
        guard result == kIOReturnSuccess else {
            fail("OPPO service discovery failed (\(result))")
            return
        }
        if !findServiceAndOpen(on: expectedDevice) {
            fail("No OPPO earphone control service was found")
        }
    }

    private func handleOpen(channel openedChannel: IOBluetoothRFCOMMChannel?, error: IOReturn) {
        guard let openedChannel else {
            if status == .connecting {
                fail("OPPO RFCOMM open failed (\(error))")
            }
            return
        }
        guard status == .connecting, openedChannel === channel else {
            // A late open from a replaced generation must not be leaked.
            openedChannel.setDelegate(nil)
            openedChannel.close()
            return
        }
        guard error == kIOReturnSuccess else {
            fail("OPPO RFCOMM open failed (\(error))")
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
            updateStatus(.failed("OPPO RFCOMM channel closed"))
        }
    }
}

extension OppoRFCOMMTransport: IOBluetoothRFCOMMChannelDelegate {
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
