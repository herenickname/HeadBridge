import Combine
import Foundation

struct BatteryHistorySample: Codable, Identifiable, Equatable, Sendable {
    let timestamp: Date
    let level: Int
    let isCharging: Bool
    let sessionID: UUID

    var id: String {
        "\(sessionID.uuidString)|\(timestamp.timeIntervalSinceReferenceDate)"
    }

    init(
        timestamp: Date,
        level: Int,
        isCharging: Bool,
        sessionID: UUID
    ) {
        self.timestamp = timestamp
        self.level = min(100, max(0, level))
        self.isCharging = isCharging
        self.sessionID = sessionID
    }
}

struct BatteryDeviceHistory: Codable, Identifiable, Equatable, Sendable {
    let providerID: String
    let deviceID: String
    var displayName: String
    var vendorName: String
    var samples: [BatteryHistorySample]

    var id: String {
        Self.identifier(providerID: providerID, deviceID: deviceID)
    }

    var latestSample: BatteryHistorySample? {
        samples.max(by: { $0.timestamp < $1.timestamp })
    }

    static func identifier(providerID: String, deviceID: String) -> String {
        "\(providerID.lowercased())|\(deviceID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }
}

enum BatteryHistoryRange: String, CaseIterable, Identifiable {
    case day
    case week
    case month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: "24h"
        case .week: "7d"
        case .month: "30d"
        }
    }

    var duration: TimeInterval {
        switch self {
        case .day: 24 * 60 * 60
        case .week: 7 * 24 * 60 * 60
        case .month: 30 * 24 * 60 * 60
        }
    }
}

/// Event-driven battery history with one lightweight device query every five
/// minutes while at least one control provider is ready. No timer runs, and no
/// Bluetooth discovery is started, while every provider is disconnected.
@MainActor
final class BatteryHistoryStore: ObservableObject {
    nonisolated static let samplingInterval: TimeInterval = 5 * 60
    nonisolated static let retentionInterval: TimeInterval = 90 * 24 * 60 * 60

    @Published private(set) var histories: [BatteryDeviceHistory]

    private struct Archive: Codable {
        let version: Int
        var histories: [BatteryDeviceHistory]
    }

    private let providers: [any HeadphoneProvider]
    private let storageURL: URL
    private let managesStorageDirectory: Bool
    private let now: () -> Date
    private let samplingInterval: TimeInterval
    private var activeHistoryIDByProvider: [String: String] = [:]
    private var activeSessionIDByHistory: [String: UUID] = [:]
    private var providerCancellables: Set<AnyCancellable> = []
    private var samplingCancellable: AnyCancellable?

    init(
        providers: [any HeadphoneProvider],
        storageURL: URL? = nil,
        samplingInterval: TimeInterval = BatteryHistoryStore.samplingInterval,
        now: @escaping () -> Date = Date.init
    ) {
        self.providers = providers
        self.storageURL = storageURL ?? Self.defaultStorageURL()
        managesStorageDirectory = storageURL == nil
        self.samplingInterval = max(1, samplingInterval)
        self.now = now
        histories = Self.load(from: self.storageURL)

        prune(before: now().addingTimeInterval(-Self.retentionInterval), persistChanges: false)
        observeProviders()
        providers.forEach { capture($0, at: now()) }
        updateSamplingTimer()
    }

    func history(providerID: String, deviceID: String?) -> BatteryDeviceHistory? {
        guard let deviceID else { return mostRecentHistory(providerID: providerID) }
        let id = BatteryDeviceHistory.identifier(providerID: providerID, deviceID: deviceID)
        return histories.first(where: { $0.id == id })
    }

    func mostRecentHistory(providerID: String) -> BatteryDeviceHistory? {
        histories
            .filter { $0.providerID == providerID }
            .max { lhs, rhs in
                (lhs.latestSample?.timestamp ?? .distantPast) < (rhs.latestSample?.timestamp ?? .distantPast)
            }
    }

    func clearHistory(providerID: String, deviceID: String) {
        let historyID = BatteryDeviceHistory.identifier(providerID: providerID, deviceID: deviceID)
        histories.removeAll { $0.id == historyID }
        activeSessionIDByHistory.removeValue(forKey: historyID)
        if activeHistoryIDByProvider[providerID] == historyID {
            activeHistoryIDByProvider.removeValue(forKey: providerID)
        }
        persist()
    }

    func clearAllHistory() {
        histories.removeAll()
        activeHistoryIDByProvider.removeAll()
        activeSessionIDByHistory.removeAll()
        persist()
    }

    /// Internal entry point kept deterministic for unit tests and future
    /// providers that report battery state outside ObservableObject changes.
    func recordSample(
        providerID: String,
        deviceID: String,
        displayName: String,
        vendorName: String,
        level: Int,
        isCharging: Bool,
        at timestamp: Date = Date()
    ) {
        let historyID = BatteryDeviceHistory.identifier(providerID: providerID, deviceID: deviceID)
        let sessionID: UUID
        if let active = activeSessionIDByHistory[historyID] {
            sessionID = active
        } else {
            let created = UUID()
            activeSessionIDByHistory[historyID] = created
            sessionID = created
        }

        appendSample(
            providerID: providerID,
            deviceID: deviceID,
            displayName: displayName,
            vendorName: vendorName,
            level: level,
            isCharging: isCharging,
            sessionID: sessionID,
            at: timestamp
        )
    }

    func endSession(providerID: String, deviceID: String) {
        let historyID = BatteryDeviceHistory.identifier(providerID: providerID, deviceID: deviceID)
        activeSessionIDByHistory.removeValue(forKey: historyID)
        if activeHistoryIDByProvider[providerID] == historyID {
            activeHistoryIDByProvider.removeValue(forKey: providerID)
        }
    }

    private func observeProviders() {
        for provider in providers {
            provider.objectWillChange
                .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
                .sink { [weak self] _ in
                    guard let self else { return }
                    self.capture(provider, at: self.now())
                    self.updateSamplingTimer()
                }
                .store(in: &providerCancellables)
        }
    }

    private func updateSamplingTimer() {
        let shouldSample = providers.contains { $0.connectionState == .ready }
        if shouldSample, samplingCancellable == nil {
            samplingCancellable = Timer.publish(
                every: samplingInterval,
                tolerance: min(15, samplingInterval * 0.1),
                on: .main,
                in: .common
            )
            .autoconnect()
            .sink { [weak self] timestamp in
                self?.sampleConnectedProviders(at: timestamp)
            }
        } else if !shouldSample {
            samplingCancellable?.cancel()
            samplingCancellable = nil
        }
    }

    private func sampleConnectedProviders(at timestamp: Date) {
        for provider in providers where provider.connectionState == .ready {
            // Preserve the last known value at the five-minute boundary, then
            // request a fresh battery-only value. A changed reply is recorded
            // immediately through objectWillChange.
            capture(provider, at: timestamp)
            provider.refreshBatteryStatus()
        }
    }

    private func capture(_ provider: any HeadphoneProvider, at timestamp: Date) {
        guard provider.connectionState == .ready,
            provider.capabilities.contains(.battery),
            let deviceID = provider.connectedDeviceID
        else {
            closeActiveSession(for: provider.providerID)
            return
        }

        let historyID = BatteryDeviceHistory.identifier(
            providerID: provider.providerID,
            deviceID: deviceID
        )
        if activeHistoryIDByProvider[provider.providerID] != historyID {
            closeActiveSession(for: provider.providerID)
            activeHistoryIDByProvider[provider.providerID] = historyID
            activeSessionIDByHistory[historyID] = UUID()
        }

        guard let level = provider.batteryPercent else { return }
        recordSample(
            providerID: provider.providerID,
            deviceID: deviceID,
            displayName: provider.connectedName,
            vendorName: provider.vendorName,
            level: level,
            isCharging: provider.isCharging == true,
            at: timestamp
        )
    }

    private func closeActiveSession(for providerID: String) {
        guard let historyID = activeHistoryIDByProvider.removeValue(forKey: providerID) else { return }
        activeSessionIDByHistory.removeValue(forKey: historyID)
    }

    private func appendSample(
        providerID: String,
        deviceID: String,
        displayName: String,
        vendorName: String,
        level: Int,
        isCharging: Bool,
        sessionID: UUID,
        at timestamp: Date
    ) {
        let historyID = BatteryDeviceHistory.identifier(providerID: providerID, deviceID: deviceID)
        let index: Int
        if let existing = histories.firstIndex(where: { $0.id == historyID }) {
            index = existing
            histories[index].displayName = displayName
            histories[index].vendorName = vendorName
        } else {
            histories.append(
                BatteryDeviceHistory(
                    providerID: providerID,
                    deviceID: deviceID,
                    displayName: displayName,
                    vendorName: vendorName,
                    samples: []
                ))
            index = histories.count - 1
        }

        let clampedLevel = min(100, max(0, level))
        if let previous = histories[index].samples.last(where: { $0.sessionID == sessionID }),
            previous.level == clampedLevel,
            previous.isCharging == isCharging,
            timestamp.timeIntervalSince(previous.timestamp) < samplingInterval * 0.95
        {
            return
        }

        histories[index].samples.append(
            BatteryHistorySample(
                timestamp: timestamp,
                level: clampedLevel,
                isCharging: isCharging,
                sessionID: sessionID
            ))
        histories[index].samples.sort { $0.timestamp < $1.timestamp }
        prune(before: timestamp.addingTimeInterval(-Self.retentionInterval), persistChanges: false)
        histories.sort {
            ($0.latestSample?.timestamp ?? .distantPast) > ($1.latestSample?.timestamp ?? .distantPast)
        }
        persist()
    }

    private func prune(before cutoff: Date, persistChanges: Bool) {
        let previousCount = histories.reduce(0) { $0 + $1.samples.count }
        for index in histories.indices {
            histories[index].samples.removeAll { $0.timestamp < cutoff }
        }
        histories.removeAll(where: { $0.samples.isEmpty })
        let currentCount = histories.reduce(0) { $0 + $1.samples.count }
        if persistChanges, currentCount != previousCount { persist() }
    }

    private func persist() {
        do {
            let directory = storageURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            if managesStorageDirectory {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: directory.path
                )
            }
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let data = try encoder.encode(Archive(version: 1, histories: histories))
            try data.write(to: storageURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: storageURL.path
            )
        } catch {
            // Battery history must never interfere with device control.
        }
    }

    private static func load(from url: URL) -> [BatteryDeviceHistory] {
        guard let data = try? Data(contentsOf: url),
            let archive = try? PropertyListDecoder().decode(Archive.self, from: data),
            archive.version == 1
        else { return [] }
        return archive.histories
    }

    private static func defaultStorageURL() -> URL {
        let base =
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
        return
            base
            .appendingPathComponent("HeadBridge", isDirectory: true)
            .appendingPathComponent("BatteryHistory.plist", isDirectory: false)
    }
}
