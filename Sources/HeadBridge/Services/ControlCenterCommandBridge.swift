import Combine
import Foundation
import WidgetKit

@MainActor
final class ControlCenterCommandBridge: NSObject {
    static let shared = ControlCenterCommandBridge()

    private weak var headphones: HeadphoneManager?
    private weak var systemAudio: SystemAudioController?
    private var cancellables: Set<AnyCancellable> = []
    private var isInstalled = false

    func install(headphones: HeadphoneManager, systemAudio: SystemAudioController) {
        self.headphones = headphones
        self.systemAudio = systemAudio
        guard !isInstalled else { return }
        isInstalled = true

        let center = DistributedNotificationCenter.default()
        center.addObserver(
            self,
            selector: #selector(cycleNoiseControl),
            name: HeadBridgeControlConstants.cycleNoiseNotification,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        center.addObserver(
            self,
            selector: #selector(enableStickyInput),
            name: HeadBridgeControlConstants.stickyInputOnNotification,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        center.addObserver(
            self,
            selector: #selector(disableStickyInput),
            name: HeadBridgeControlConstants.stickyInputOffNotification,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )

        headphones.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.syncNoiseControlState() }
            }
            .store(in: &cancellables)

        systemAudio.$stickyInputUID
            .map { $0 != nil }
            .removeDuplicates()
            .sink { enabled in
                HeadBridgeControlStateStore.setStickyInputEnabled(enabled)
                Self.reload(kind: HeadBridgeControlConstants.stickyInputKind)
            }
            .store(in: &cancellables)

        syncNoiseControlState()
    }

    @objc private func cycleNoiseControl() {
        guard let headphones, let systemAudio,
            let provider = headphones.activeProvider(systemAudio: systemAudio),
            provider.connectionState == .ready,
            let current = provider.noiseMode,
            let index = provider.supportedNoiseModes.firstIndex(of: current)
        else { return }
        let nextIndex = provider.supportedNoiseModes.index(after: index)
        let next =
            nextIndex == provider.supportedNoiseModes.endIndex
            ? provider.supportedNoiseModes[0]
            : provider.supportedNoiseModes[nextIndex]
        provider.setNoiseMode(next)
    }

    @objc private func enableStickyInput() {
        systemAudio?.setStickyInputEnabled(true)
    }

    @objc private func disableStickyInput() {
        systemAudio?.setStickyInputEnabled(false)
    }

    private static func reload(kind: String) {
        if #available(macOS 26.0, *) {
            ControlCenter.shared.reloadControls(ofKind: kind)
        }
    }

    private func syncNoiseControlState() {
        guard let headphones, let systemAudio,
            let provider = headphones.activeProvider(systemAudio: systemAudio),
            let mode = provider.noiseMode
        else { return }
        HeadBridgeControlStateStore.setSupportedNoiseModes(provider.supportedNoiseModes.map(\.rawValue))
        HeadBridgeControlStateStore.setNoiseMode(mode.rawValue)
        Self.reload(kind: HeadBridgeControlConstants.noiseControlKind)
    }
}
