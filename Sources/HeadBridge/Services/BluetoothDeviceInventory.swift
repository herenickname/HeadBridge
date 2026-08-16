import Darwin
import Foundation

struct BluetoothPairedDevice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let address: String
    let isConnected: Bool
    let isAudioConnected: Bool

    init(
        id: String,
        name: String,
        address: String,
        isConnected: Bool,
        isAudioConnected: Bool = false
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.isConnected = isConnected
        self.isAudioConnected = isAudioConnected
    }
}

private final class BluetoothInventoryDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func store(_ value: Data) {
        lock.lock()
        data = value
        lock.unlock()
    }

    func value() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

/// Owns one bounded `system_profiler` invocation. Keeping it outside any
/// vendor provider gives Settings a single inventory of devices macOS already
/// knows about, including paired headphones that are currently powered off.
final class BluetoothInventoryQuery: @unchecked Sendable {
    private static let outputQueue = DispatchQueue(
        label: "io.github.herenickname.HeadBridge.bluetooth-inventory-output",
        qos: .utility,
        attributes: .concurrent
    )

    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        let process = process
        lock.unlock()

        if process?.isRunning == true {
            process?.terminate()
        }
    }

    func run(timeout: TimeInterval = 5) -> Data? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return nil
        }
        self.process = process
        lock.unlock()

        let processFinished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in processFinished.signal() }

        do {
            try process.run()
        } catch {
            clear(process)
            return nil
        }

        let dataBox = BluetoothInventoryDataBox()
        let outputFinished = DispatchSemaphore(value: 0)
        Self.outputQueue.async {
            dataBox.store(output.fileHandleForReading.readDataToEndOfFile())
            outputFinished.signal()
        }

        if isCancelled, process.isRunning {
            process.terminate()
        }

        var timedOut = false
        if processFinished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            if process.isRunning {
                process.terminate()
            }
            if processFinished.wait(timeout: .now() + 1) == .timedOut,
                process.isRunning
            {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }

        process.waitUntilExit()
        outputFinished.wait()
        process.terminationHandler = nil
        let wasCancelled = isCancelled
        clear(process)

        guard !timedOut, !wasCancelled, process.terminationStatus == 0 else {
            return nil
        }
        return dataBox.value()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private func clear(_ completedProcess: Process) {
        lock.lock()
        if process === completedProcess {
            process = nil
        }
        lock.unlock()
    }
}

enum BluetoothDeviceInventory {
    static func decode(_ data: Data) -> [BluetoothPairedDevice]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let profiles = root["SPBluetoothDataType"] as? [[String: Any]]
        else {
            return nil
        }

        var devicesByAddress: [String: BluetoothPairedDevice] = [:]
        for profile in profiles {
            for (section, isConnected) in [
                ("device_connected", true),
                ("device_not_connected", false),
            ] {
                guard let entries = profile[section] as? [[String: Any]] else { continue }
                for entry in entries {
                    for (name, rawDetails) in entry {
                        guard let details = rawDetails as? [String: Any],
                            let address = details["device_address"] as? String
                        else { continue }

                        let id = address.lowercased()
                        let services = (details["device_services"] as? String)?.uppercased() ?? ""
                        let isAudioConnected =
                            isConnected && (services.contains("A2DP") || services.contains("HFP"))
                        if let existing = devicesByAddress[id] {
                            devicesByAddress[id] = BluetoothPairedDevice(
                                id: id,
                                name: existing.isConnected ? existing.name : name,
                                address: address,
                                isConnected: existing.isConnected || isConnected,
                                isAudioConnected: existing.isAudioConnected || isAudioConnected
                            )
                        } else {
                            devicesByAddress[id] = BluetoothPairedDevice(
                                id: id,
                                name: name,
                                address: address,
                                isConnected: isConnected,
                                isAudioConnected: isAudioConnected
                            )
                        }
                    }
                }
            }
        }

        let devices = Array(devicesByAddress.values)
        let audioConnectedNames = Set(
            devices
                .filter(\.isAudioConnected)
                .map { BluetoothDeviceNameMatcher.normalized($0.name) }
        )

        // Recent headphones can expose separate Classic Audio and BLE control
        // endpoints with different addresses but the same model name. Keep the
        // A2DP/HFP endpoint as the physical device row and hide only its
        // currently connected BLE companion. Powered-off devices and multiple
        // Classic Audio devices with the same model name remain distinct.
        return devices.filter { device in
            device.isAudioConnected
                || !device.isConnected
                || !audioConnectedNames.contains(BluetoothDeviceNameMatcher.normalized(device.name))
        }
        .sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}
