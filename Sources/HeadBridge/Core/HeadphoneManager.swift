import Combine
import CoreAudio
import Foundation

private struct HeadphoneVolumeSyncState: Equatable {
    let normalizedVolume: Float
    let deviceID: AudioDeviceID?
    let enabled: Bool
    let providerReady: Bool
}

struct RecognizedHeadphoneDevice: Identifiable, Equatable {
    let id: String
    let deviceID: String
    let name: String
    let address: String
    let isConnected: Bool
    let providerID: String
    let vendorName: String
}

@MainActor
final class HeadphoneManager: ObservableObject {
    let providers: [any HeadphoneProvider]
    @Published private(set) var recognizedDevices: [RecognizedHeadphoneDevice] = []

    private var cancellables: Set<AnyCancellable> = []
    private var isShutdown = false
    private var inventoryQuery: BluetoothInventoryQuery?
    private var inventoryGeneration = 0
    private var isRefreshingInventory = false
    private var needsInventoryRefresh = false

    private static let inventoryQueue = DispatchQueue(
        label: "io.github.herenickname.HeadBridge.bluetooth-device-discovery",
        qos: .utility
    )

    init(providers: [any HeadphoneProvider]) {
        self.providers = providers

        for provider in providers {
            provider.objectWillChange
                // ObservableObject emits before the provider mutates its
                // published fields. Deliver the aggregate notification on the
                // next run-loop turn so existential provider rows read the new
                // name, state, and battery instead of the previous snapshot.
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }
    }

    func provider(for device: SystemAudioDevice) -> (any HeadphoneProvider)? {
        providers.first { $0.matches(audioDevice: device) }
    }

    func provider(withID providerID: String) -> (any HeadphoneProvider)? {
        providers.first { $0.providerID == providerID }
    }

    func activeProvider(systemAudio: SystemAudioController) -> (any HeadphoneProvider)? {
        guard let id = systemAudio.defaultDeviceID,
            let device = systemAudio.devices.first(where: { $0.id == id })
        else { return nil }
        return provider(for: device)
    }

    func updateAudioConnectedDevices(_ devices: [SystemAudioDevice]) {
        providers.forEach { $0.updateAudioConnectedDevices(devices) }
    }

    func installAudioDeviceDiscovery(systemAudio: SystemAudioController) {
        systemAudio.$devices
            .receive(on: RunLoop.main)
            .sink { [weak self] devices in
                self?.updateAudioConnectedDevices(devices)
                self?.refreshBluetoothDevices()
            }
            .store(in: &cancellables)
    }

    func refreshAll() {
        refreshBluetoothDevices()
        providers.forEach { $0.refresh() }
    }

    func refreshBluetoothDevices() {
        guard !isShutdown else { return }
        guard !isRefreshingInventory else {
            needsInventoryRefresh = true
            return
        }

        isRefreshingInventory = true
        inventoryGeneration &+= 1
        let expectedGeneration = inventoryGeneration
        let query = BluetoothInventoryQuery()
        inventoryQuery = query

        Self.inventoryQueue.async {
            let devices = query.run().flatMap(BluetoothDeviceInventory.decode)
            DispatchQueue.main.async { [weak self] in
                guard let self,
                    !self.isShutdown,
                    self.inventoryGeneration == expectedGeneration,
                    self.inventoryQuery === query
                else { return }

                self.inventoryQuery = nil
                self.isRefreshingInventory = false
                if let devices {
                    self.applyBluetoothPairedDevices(devices)
                }

                if self.needsInventoryRefresh {
                    self.needsInventoryRefresh = false
                    self.refreshBluetoothDevices()
                }
            }
        }
    }

    func applyBluetoothPairedDevices(_ devices: [BluetoothPairedDevice]) {
        providers.forEach { $0.updateBluetoothPairedDevices(devices) }

        let recognized = devices.compactMap { device -> RecognizedHeadphoneDevice? in
            guard
                let provider = providers.first(where: {
                    $0.recognizesBluetoothDevice(named: device.name)
                })
            else { return nil }

            return RecognizedHeadphoneDevice(
                id: "\(provider.providerID):\(device.id)",
                deviceID: device.id,
                name: device.name,
                address: device.address,
                isConnected: device.isConnected,
                providerID: provider.providerID,
                vendorName: provider.vendorName
            )
        }
        .sorted {
            let vendorOrder = $0.vendorName.localizedCaseInsensitiveCompare($1.vendorName)
            if vendorOrder != .orderedSame { return vendorOrder == .orderedAscending }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        if recognizedDevices != recognized {
            recognizedDevices = recognized
        }
    }

    /// Stops aggregate subscriptions before asking every provider to release
    /// its transport. The operation is deliberately idempotent because AppKit
    /// can deliver more than one terminal lifecycle notification.
    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        inventoryGeneration &+= 1
        inventoryQuery?.cancel()
        inventoryQuery = nil
        isRefreshingInventory = false
        needsInventoryRefresh = false
        cancellables.removeAll()
        providers.forEach { $0.shutdown() }
    }

    func installVolumeSynchronization(
        settings: AppSettings,
        systemAudio: SystemAudioController
    ) {
        for provider in providers where provider.supportsSystemVolumeSynchronization {
            settings.registerVolumeSynchronization(
                providerID: provider.providerID,
                defaultEnabled: provider.defaultSystemVolumeSynchronizationEnabled
            )
            installVolumeSynchronization(
                provider: provider,
                enabled: settings.volumeSynchronizationPublisher(for: provider.providerID),
                systemAudio: systemAudio
            )
        }
    }

    private func installVolumeSynchronization(
        provider: any HeadphoneProvider,
        enabled: AnyPublisher<Bool, Never>,
        systemAudio: SystemAudioController
    ) {
        let audioState = systemAudio.$volume
            .combineLatest(systemAudio.$defaultDeviceID)
        let providerState =
            enabled
            .combineLatest(provider.connectionStatePublisher)
        weak let weakProvider = provider

        audioState
            .combineLatest(providerState)
            .map { audio, providerState in
                let (volume, deviceID) = audio
                let (enabled, connectionState) = providerState
                return HeadphoneVolumeSyncState(
                    normalizedVolume: volume,
                    deviceID: deviceID,
                    enabled: enabled,
                    providerReady: connectionState == .ready
                )
            }
            .removeDuplicates()
            .sink { [weak systemAudio] (state: HeadphoneVolumeSyncState) in
                guard let systemAudio, let provider = weakProvider,
                    state.enabled, state.providerReady,
                    provider.capabilities.contains(.deviceVolume),
                    let deviceID = state.deviceID,
                    let device = systemAudio.devices.first(where: { $0.id == deviceID }),
                    provider.matches(audioDevice: device),
                    BluetoothDeviceNameMatcher.matches(provider.connectedName, device.name)
                else { return }
                provider.setDeviceVolume(normalized: state.normalizedVolume)
            }
            .store(in: &cancellables)
    }
}
