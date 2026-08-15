import Combine
import CoreAudio
import Foundation

private struct HeadphoneVolumeSyncState: Equatable {
    let normalizedVolume: Float
    let deviceID: AudioDeviceID?
    let enabled: Bool
    let providerReady: Bool
}

@MainActor
final class HeadphoneManager: ObservableObject {
    let providers: [any HeadphoneProvider]

    private var cancellables: Set<AnyCancellable> = []
    private var isShutdown = false

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
            }
            .store(in: &cancellables)
    }

    func refreshAll() {
        providers.forEach { $0.refresh() }
    }

    /// Stops aggregate subscriptions before asking every provider to release
    /// its transport. The operation is deliberately idempotent because AppKit
    /// can deliver more than one terminal lifecycle notification.
    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
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
