import Charts
import Combine
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var manager: HeadphoneManager
    @EnvironmentObject private var controller: BowersWilkinsProvider
    @EnvironmentObject private var sony: SonyMDRProvider
    @EnvironmentObject private var settings: AppSettings
    @State private var selection: SettingsDestination = .general

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("General", systemImage: "gearshape")
                    .tag(SettingsDestination.general)

                if !manager.recognizedDevices.isEmpty {
                    Section("Headphones") {
                        ForEach(manager.recognizedDevices) { device in
                            if let provider = manager.provider(withID: device.providerID) {
                                HeadphoneDeviceSidebarRow(device: device, provider: provider)
                                    .tag(SettingsDestination.device(device.id))
                            }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 240)
        } detail: {
            switch selection {
            case .general:
                GeneralSettingsView()
            case .device(let deviceID):
                deviceSettings(deviceID: deviceID)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: settings.developerModeEnabled) { _, enabled in
            controller.setDiagnosticsEnabled(enabled)
            sony.setDiagnosticsEnabled(enabled)
        }
        .onChange(of: manager.recognizedDevices.map(\.id)) { _, deviceIDs in
            guard case .device(let selectedID) = selection,
                !deviceIDs.contains(selectedID)
            else { return }
            selection = .general
        }
    }

    @ViewBuilder
    private func deviceSettings(deviceID: String) -> some View {
        if let device = manager.recognizedDevices.first(where: { $0.id == deviceID }),
            let provider = manager.provider(withID: device.providerID)
        {
            if device.providerID == controller.providerID {
                BWDeviceSettingsView(deviceName: device.name)
            } else if device.providerID == sony.providerID {
                SonyDeviceSettingsView(deviceName: device.name)
            } else {
                GenericProviderSettingsView(provider: provider, deviceName: device.name)
            }
        } else {
            ContentUnavailableView("Headphones unavailable", systemImage: "headphones")
        }
    }
}

private enum SettingsDestination: Hashable {
    case general
    case device(String)
}

struct HeadphoneProviderSidebarSnapshot: Equatable {
    let name: String
    let vendor: String
    let state: HeadphoneConnectionState
    let battery: Int?

    @MainActor
    init(device: RecognizedHeadphoneDevice, provider: any HeadphoneProvider) {
        name = device.name
        vendor = device.vendorName

        let representsActiveDevice =
            provider.connectedDeviceID?.lowercased() == device.deviceID.lowercased()
            || BluetoothDeviceNameMatcher.matches(provider.connectedName, device.name)
        state = representsActiveDevice ? provider.connectionState : .idle
        battery = state == .ready ? provider.batteryPercent : nil
    }
}

/// A `List` retains rows by identity, so a row backed only by a provider
/// existential does not directly participate in SwiftUI observation. Keep a
/// row-local snapshot and subscribe to that exact provider instead of relying
/// on a parent manager invalidation to rebuild retained rows.
@MainActor
final class HeadphoneProviderSidebarModel: ObservableObject {
    let device: RecognizedHeadphoneDevice
    let provider: any HeadphoneProvider
    @Published private(set) var snapshot: HeadphoneProviderSidebarSnapshot

    private var cancellable: AnyCancellable?

    init(device: RecognizedHeadphoneDevice, provider: any HeadphoneProvider) {
        self.device = device
        self.provider = provider
        snapshot = HeadphoneProviderSidebarSnapshot(device: device, provider: provider)
        cancellable = provider.objectWillChange
            // `objectWillChange` is emitted before @Published stores its new
            // value. Read the provider on the next run-loop turn.
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let updated = HeadphoneProviderSidebarSnapshot(
                    device: self.device,
                    provider: self.provider
                )
                guard updated != self.snapshot else { return }
                self.snapshot = updated
            }
    }
}

private struct HeadphoneDeviceSidebarRow: View {
    @StateObject private var model: HeadphoneProviderSidebarModel

    init(device: RecognizedHeadphoneDevice, provider: any HeadphoneProvider) {
        _model = StateObject(
            wrappedValue: HeadphoneProviderSidebarModel(device: device, provider: provider)
        )
    }

    var body: some View {
        DeviceSidebarRow(
            name: model.snapshot.name,
            vendor: model.snapshot.vendor,
            state: model.snapshot.state,
            battery: model.snapshot.battery
        )
    }
}

private struct GenericProviderSettingsView: View {
    let provider: any HeadphoneProvider
    let deviceName: String

    var body: some View {
        VStack(spacing: 0) {
            DeviceDetailHeader(
                name: provider.connectionState == .ready ? provider.connectedName : deviceName,
                vendor: provider.vendorName,
                state: provider.connectionState,
                battery: provider.batteryPercent,
                isCharging: provider.isCharging,
                codec: provider.codecName
            ) {
                if provider.connectionState.isConnecting {
                    ProgressView().controlSize(.small)
                } else if provider.connectionState == .ready {
                    Button {
                        provider.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh headphone values")
                    Button("Disconnect") { provider.disconnect() }
                } else {
                    Button("Refresh") { provider.refresh() }
                }
            }
            Divider()
            Form {
                Section("Connection") {
                    Toggle(
                        "Restore settings on connect",
                        isOn: Binding(
                            get: { provider.restoreOnConnectEnabled },
                            set: { provider.setRestoreOnConnectEnabled($0) }
                        ))
                    Text("Reapplies this Mac's saved profile after the control connection is ready.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if provider.capabilities.contains(.noiseControl) {
                    Section("Noise Control") {
                        Picker(
                            "Mode",
                            selection: Binding(
                                get: { provider.noiseMode ?? .off },
                                set: { provider.setNoiseMode($0) }
                            )
                        ) {
                            ForEach(provider.supportedNoiseModes) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                Section("Status") {
                    LabeledContent("Connection") {
                        Text(provider.connectionState.title).foregroundStyle(.secondary)
                    }
                    if let battery = provider.batteryPercent {
                        LabeledContent("Battery") {
                            HStack(spacing: 5) {
                                Image(systemName: HeadphoneBatterySymbol.name(for: battery))
                                if provider.isCharging == true { Image(systemName: "bolt.fill") }
                                Text("\(battery)%").monospacedDigit()
                            }
                        }
                    }
                    if let codec = provider.codecName {
                        LabeledContent("Codec") { Text(codec).foregroundStyle(.secondary) }
                    }
                }

                BatteryHistorySection(
                    providerID: provider.providerID,
                    deviceID: provider.connectedDeviceID,
                    currentLevel: provider.batteryPercent,
                    isCharging: provider.isCharging,
                    isConnected: provider.connectionState == .ready
                )
            }
            .formStyle(.grouped)
            .padding(.vertical, 8)
        }
        .navigationTitle(provider.vendorName)
    }
}

private struct DeviceSidebarRow: View {
    let name: String
    let vendor: String
    let state: HeadphoneConnectionState
    let battery: Int?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "headphones")
                .font(.title3)
                .foregroundStyle(state == .ready ? Color.accentColor : Color.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Circle()
                        .fill(state == .ready ? Color.green : Color.secondary.opacity(0.55))
                        .frame(width: 6, height: 6)
                    Text(vendor)
                    if state == .ready, let battery {
                        Text("·")
                        Image(systemName: HeadphoneBatterySymbol.name(for: battery))
                        Text("\(battery)%")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct GeneralSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var updates: UpdateController

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("HeadBridge")
                        .font(.title2.weight(.semibold))
                    Text("System-style controls for headphones supported by installed providers.")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section("Menu Bar") {
                Picker("Show active headphones battery", selection: $settings.batteryDisplayMode) {
                    ForEach(BatteryDisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            Section("Startup") {
                Toggle(
                    "Launch HeadBridge at login",
                    isOn: Binding(
                        get: { settings.launchAtLoginEnabled },
                        set: { settings.setLaunchAtLoginEnabled($0) }
                    ))
                if settings.launchAtLoginRequiresApproval {
                    LabeledContent {
                        Button("Open Login Items Settings") {
                            settings.openLoginItemsSettings()
                        }
                    } label: {
                        Text("Approval is required in System Settings.")
                            .foregroundStyle(.secondary)
                    }
                }
                if let error = settings.launchAtLoginError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Updates") {
                LabeledContent("Version") {
                    Text(updates.versionDescription)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Toggle(
                    "Automatically check for updates",
                    isOn: Binding(
                        get: { updates.automaticallyChecksForUpdates },
                        set: { updates.setAutomaticallyChecksForUpdates($0) }
                    ))
                Toggle(
                    "Automatically download and install updates",
                    isOn: Binding(
                        get: { updates.automaticallyDownloadsUpdates },
                        set: { updates.setAutomaticallyDownloadsUpdates($0) }
                    )
                )
                .disabled(!updates.automaticallyChecksForUpdates)
                Button("Check for Updates…") {
                    updates.checkForUpdates()
                }
            }

            Section("Advanced") {
                Toggle("Enable protocol diagnostics", isOn: $settings.developerModeEnabled)
                Text(
                    "Shows raw provider values and transport logs. These views can contain device names, serial numbers, and Bluetooth addresses."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
        .navigationTitle("General")
        .onAppear {
            settings.refreshLaunchAtLoginStatus()
            updates.refreshPreferences()
        }
    }
}

private struct DeviceDetailHeader<Actions: View>: View {
    let name: String
    let vendor: String
    let state: HeadphoneConnectionState
    let battery: Int?
    let isCharging: Bool?
    let codec: String?
    let actions: Actions

    init(
        name: String,
        vendor: String,
        state: HeadphoneConnectionState,
        battery: Int?,
        isCharging: Bool?,
        codec: String?,
        @ViewBuilder actions: () -> Actions
    ) {
        self.name = name
        self.vendor = vendor
        self.state = state
        self.battery = battery
        self.isCharging = isCharging
        self.codec = codec
        self.actions = actions()
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "headphones")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color.accentColor, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.title3.weight(.semibold))
                HStack(spacing: 6) {
                    Circle()
                        .fill(state == .ready ? Color.green : Color.secondary.opacity(0.55))
                        .frame(width: 7, height: 7)
                    Text(vendor)
                    Text("·")
                    Text(state.title)
                    if state == .ready, let battery {
                        Text("·")
                        Image(systemName: HeadphoneBatterySymbol.name(for: battery))
                        if isCharging == true { Image(systemName: "bolt.fill") }
                        Text("\(battery)%")
                    }
                    if state == .ready, let codec, !codec.isEmpty {
                        Text("· \(codec)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 12)
            actions
        }
        .padding(18)
    }
}

private struct BatteryHistorySection: View {
    @EnvironmentObject private var batteryHistory: BatteryHistoryStore

    let providerID: String
    let deviceID: String?
    let currentLevel: Int?
    let isCharging: Bool?
    let isConnected: Bool

    @State private var range: BatteryHistoryRange = .day
    @State private var showsClearConfirmation = false

    private struct ChargingInterval: Identifiable {
        var start: Date
        var end: Date

        var id: String {
            "\(start.timeIntervalSinceReferenceDate)|\(end.timeIntervalSinceReferenceDate)"
        }
    }

    private var history: BatteryDeviceHistory? {
        batteryHistory.history(providerID: providerID, deviceID: deviceID)
    }

    private var rangeEnd: Date {
        let interval = Date().timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: floor(interval))
    }
    private var rangeStart: Date { rangeEnd.addingTimeInterval(-range.duration) }

    private var visibleSamples: [BatteryHistorySample] {
        guard let history else { return [] }
        let sorted = history.samples.sorted { $0.timestamp < $1.timestamp }
        var samples = sorted.filter { $0.timestamp >= rangeStart && $0.timestamp <= rangeEnd }

        // Preserve the level at the left edge when the same connection session
        // began before the selected range.
        if let first = samples.first,
            let previous = sorted.last(where: {
                $0.timestamp < rangeStart && $0.sessionID == first.sessionID
            })
        {
            samples.insert(
                BatteryHistorySample(
                    timestamp: rangeStart,
                    level: previous.level,
                    isCharging: previous.isCharging,
                    sessionID: previous.sessionID
                ), at: 0)
        }

        // Extend an active session to "now" without persisting fake readings.
        if isConnected,
            let currentLevel,
            let latest = samples.last ?? sorted.last,
            rangeEnd.timeIntervalSince(latest.timestamp) >= 1
        {
            samples.append(
                BatteryHistorySample(
                    timestamp: rangeEnd,
                    level: currentLevel,
                    isCharging: isCharging == true,
                    sessionID: latest.sessionID
                ))
        }
        return samples
    }

    private var chartSamples: [BatteryHistorySample] {
        let samples = visibleSamples
        guard samples.count > 2 else { return samples }

        // Five-minute sampling can produce thousands of equal points. Keep
        // both ends of each flat run so the step chart remains exact and fast.
        var result = [samples[0]]
        for index in 1..<(samples.count - 1) {
            let previous = samples[index - 1]
            let current = samples[index]
            let next = samples[index + 1]
            let sameAsPrevious =
                current.level == previous.level && current.isCharging == previous.isCharging
                && current.sessionID == previous.sessionID
            let sameAsNext =
                current.level == next.level && current.isCharging == next.isCharging
                && current.sessionID == next.sessionID
            if !(sameAsPrevious && sameAsNext) { result.append(current) }
        }
        result.append(samples[samples.count - 1])
        return result
    }

    private var chargingIntervals: [ChargingInterval] {
        let samples = visibleSamples
        guard samples.count > 1 else { return [] }
        var intervals: [ChargingInterval] = []

        for pair in zip(samples, samples.dropFirst()) {
            let (start, end) = pair
            let duration = end.timestamp.timeIntervalSince(start.timestamp)
            guard start.sessionID == end.sessionID,
                start.isCharging,
                duration > 0,
                duration <= BatteryHistoryStore.samplingInterval * 1.6
            else { continue }

            if let lastIndex = intervals.indices.last,
                abs(intervals[lastIndex].end.timeIntervalSince(start.timestamp)) < 1
            {
                intervals[lastIndex].end = end.timestamp
            } else {
                intervals.append(ChargingInterval(start: start.timestamp, end: end.timestamp))
            }
        }
        return intervals
    }

    private var change: Int? {
        guard let first = visibleSamples.first, let last = visibleSamples.last else { return nil }
        return last.level - first.level
    }

    private var minimumLevel: Int? {
        visibleSamples.map(\.level).min()
    }

    private var chargingDuration: TimeInterval {
        chargingIntervals.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
    }

    var body: some View {
        Section("Battery History") {
            if visibleSamples.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "chart.xyaxis.line")
                    Text("Battery history will appear after the first reading.")
                }
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label("Every 5 minutes", systemImage: "clock.arrow.circlepath")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear…", role: .destructive) {
                            showsClearConfirmation = true
                        }
                        .buttonStyle(.borderless)
                        Picker("History range", selection: $range) {
                            ForEach(BatteryHistoryRange.allCases) { item in
                                Text(item.title).tag(item)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                    }

                    HStack(spacing: 20) {
                        BatteryMetric(
                            title: "Current",
                            value: visibleSamples.last.map { "\($0.level)%" } ?? "—",
                            systemImage: HeadphoneBatterySymbol.name(
                                for: visibleSamples.last?.level
                            )
                        )
                        BatteryMetric(
                            title: "Change",
                            value: change.map(Self.signedPercent) ?? "—"
                        )
                        BatteryMetric(
                            title: "Minimum",
                            value: minimumLevel.map { "\($0)%" } ?? "—"
                        )
                        BatteryMetric(
                            title: "Charging",
                            value: Self.durationText(chargingDuration)
                        )
                    }

                    Chart {
                        ForEach(chargingIntervals) { interval in
                            RectangleMark(
                                xStart: .value("Charging start", interval.start),
                                xEnd: .value("Charging end", interval.end),
                                yStart: .value("Battery minimum", 0),
                                yEnd: .value("Battery maximum", 100)
                            )
                            .foregroundStyle(Color.green.opacity(0.11))
                        }

                        ForEach(chartSamples) { sample in
                            AreaMark(
                                x: .value("Time", sample.timestamp),
                                yStart: .value("Empty", 0),
                                yEnd: .value("Battery", sample.level),
                                series: .value("Session", sample.sessionID.uuidString)
                            )
                            .interpolationMethod(.stepEnd)
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [Color.green.opacity(0.28), Color.green.opacity(0.03)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ))

                            LineMark(
                                x: .value("Time", sample.timestamp),
                                y: .value("Battery", sample.level),
                                series: .value("Session", sample.sessionID.uuidString)
                            )
                            .interpolationMethod(.stepEnd)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                            .foregroundStyle(Color.green)
                        }

                        if chartSamples.count == 1, let sample = chartSamples.first {
                            PointMark(
                                x: .value("Time", sample.timestamp),
                                y: .value("Battery", sample.level)
                            )
                            .symbolSize(42)
                            .foregroundStyle(Color.green)
                        }
                    }
                    .chartXScale(domain: rangeStart...rangeEnd)
                    .chartYScale(domain: 0...100)
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 6)) { value in
                            AxisGridLine().foregroundStyle(.secondary.opacity(0.22))
                            AxisTick().foregroundStyle(.secondary)
                            AxisValueLabel {
                                if let date = value.as(Date.self) {
                                    Text(date, format: axisFormat)
                                }
                            }
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .trailing, values: [0, 25, 50, 75, 100]) { value in
                            AxisGridLine().foregroundStyle(.secondary.opacity(0.22))
                            AxisValueLabel {
                                if let level = value.as(Int.self) { Text("\(level)%") }
                            }
                        }
                    }
                    .chartLegend(.hidden)
                    .chartPlotStyle { plot in
                        plot
                            .background(.secondary.opacity(0.035))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .frame(height: 190)
                }
                .padding(.vertical, 6)
            }
        }
        .confirmationDialog(
            "Clear battery history for this device?",
            isPresented: $showsClearConfirmation
        ) {
            Button("Clear History", role: .destructive) {
                guard let deviceID = history?.deviceID else { return }
                batteryHistory.clearHistory(providerID: providerID, deviceID: deviceID)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the locally stored samples and cannot be undone.")
        }
    }

    private var axisFormat: Date.FormatStyle {
        switch range {
        case .day: .dateTime.hour().minute()
        case .week, .month: .dateTime.month(.abbreviated).day()
        }
    }

    private static func signedPercent(_ value: Int) -> String {
        value > 0 ? "+\(value)%" : "\(value)%"
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        let minutes = Int(duration.rounded()) / 60
        guard minutes > 0 else { return "—" }
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours == 0 { return "\(minutes)m" }
        if remainder == 0 { return "\(hours)h" }
        return "\(hours)h \(remainder)m"
    }
}

private struct BatteryMetric: View {
    let title: String
    let value: String
    var systemImage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(value)
                    .monospacedDigit()
            }
            .font(.body.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum DeveloperDeviceSection: String, CaseIterable, Identifiable {
    case controls = "Controls"
    case values = "Values"
    case log = "Log"

    var id: String { rawValue }
}

private struct BWDeviceSettingsView: View {
    @EnvironmentObject private var controller: BowersWilkinsProvider
    @EnvironmentObject private var settings: AppSettings
    let deviceName: String
    @State private var section: DeveloperDeviceSection = .controls

    var body: some View {
        VStack(spacing: 0) {
            DeviceDetailHeader(
                name: deviceName,
                vendor: controller.vendorName,
                state: controller.connectionState,
                battery: controller.batteryPercent,
                isCharging: controller.isCharging,
                codec: controller.codecName
            ) {
                if controller.connectionState.isConnecting {
                    ProgressView().controlSize(.small)
                } else if controller.isReady {
                    Button {
                        controller.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh headphone values")
                    Button("Disconnect") { controller.disconnect() }
                }
            }
            Divider()
            if settings.developerModeEnabled {
                Picker("Bowers & Wilkins section", selection: $section) {
                    ForEach(DeveloperDeviceSection.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }

            switch section {
            case .controls:
                if controller.isReady {
                    ControlsView()
                } else {
                    BWConnectionView()
                }
            case .values:
                InspectorView()
                    .padding(.horizontal, 18)
            case .log:
                ProtocolTransportLogView(
                    entries: controller.log,
                    isReady: controller.isReady,
                    refresh: controller.refreshPrimary
                )
                .padding(.horizontal, 18)
            }
        }
        .navigationTitle("Bowers & Wilkins")
        .onAppear {
            controller.setDiagnosticsEnabled(settings.developerModeEnabled)
        }
        .onChange(of: settings.developerModeEnabled) { _, enabled in
            controller.setDiagnosticsEnabled(enabled)
            if !enabled { section = .controls }
        }
    }
}

private struct BWConnectionView: View {
    @EnvironmentObject private var controller: BowersWilkinsProvider

    var body: some View {
        Form {
            Section("Connection") {
                Toggle(
                    "Restore settings on connect",
                    isOn: Binding(
                        get: { controller.restoreOnConnectEnabled },
                        set: { controller.setRestoreOnConnectEnabled($0) }
                    ))
                if controller.connectionState.isConnecting {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Connecting…")
                    }
                } else {
                    Text("Select a nearby Bowers & Wilkins headset after starting a Bluetooth scan.")
                        .foregroundStyle(.secondary)
                    if !controller.peripherals.isEmpty {
                        Picker("Headphones", selection: $controller.selectedPeripheralID) {
                            Text("Select device").tag(Optional<UUID>.none)
                            ForEach(controller.peripherals) { item in
                                Text(item.name).tag(Optional(item.id))
                            }
                        }
                    }
                    HStack {
                        Button(controller.phase == .scanning ? "Scanning…" : "Scan") {
                            controller.startScanning()
                        }
                        .disabled(controller.phase == .scanning)
                        Button("Connect") { controller.connectSelected() }
                            .buttonStyle(.borderedProminent)
                            .disabled(controller.selectedPeripheralID == nil)
                    }
                }
            }
            BatteryHistorySection(
                providerID: controller.providerID,
                deviceID: controller.connectedDeviceID,
                currentLevel: controller.batteryPercent,
                isCharging: controller.isCharging,
                isConnected: controller.isReady
            )
        }
        .formStyle(.grouped)
    }
}

private struct SonyDeviceSettingsView: View {
    @EnvironmentObject private var sony: SonyMDRProvider
    @EnvironmentObject private var settings: AppSettings
    let deviceName: String
    @State private var section: DeveloperDeviceSection = .controls

    var body: some View {
        VStack(spacing: 0) {
            DeviceDetailHeader(
                name: deviceName,
                vendor: sony.vendorName,
                state: sony.connectionState,
                battery: sony.batteryPercent,
                isCharging: sony.isCharging,
                codec: sony.codecName
            ) {
                if sony.connectionState.isConnecting {
                    ProgressView().controlSize(.small)
                } else if sony.connectionState == .ready {
                    Button {
                        sony.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh Sony devices and values")
                    Button("Disconnect") { sony.disconnect() }
                }
            }
            Divider()
            if settings.developerModeEnabled {
                Picker("Sony section", selection: $section) {
                    ForEach(DeveloperDeviceSection.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }

            switch section {
            case .controls:
                SonyControlsView()
            case .values:
                SonyValuesView()
                    .padding(.horizontal, 18)
            case .log:
                ProtocolTransportLogView(
                    entries: sony.log,
                    isReady: sony.connectionState == .ready,
                    refresh: sony.refresh
                )
                .padding(.horizontal, 18)
            }
        }
        .navigationTitle("Sony")
        .onAppear {
            sony.setDiagnosticsEnabled(settings.developerModeEnabled)
        }
        .onChange(of: settings.developerModeEnabled) { _, enabled in
            sony.setDiagnosticsEnabled(enabled)
            if !enabled { section = .controls }
        }
    }
}

private struct SonyValuesView: View {
    @EnvironmentObject private var sony: SonyMDRProvider

    var body: some View {
        Form {
            Section("Connection") {
                value("State", sony.connectionState.title)
                value("Device", sony.connectedName)
                value("Bluetooth address", sony.connectedDeviceID ?? "—")
                value("Capabilities", String(format: "0x%05llX", sony.capabilities.rawValue))
            }

            Section("Playback") {
                value("Battery", sony.batteryPercent.map { "\($0)%" } ?? "—")
                value("Charging", optionalBoolean(sony.isCharging))
                value("Codec", sony.codecName ?? "—")
                value("Volume", sony.deviceVolume.map { "\($0) / 30" } ?? "—")
                value("Sound quality", sony.soundQualityMode?.title ?? "—")
                value("DSEE HX", optionalBoolean(sony.dseeEnabled))
            }

            Section("Noise and Sound") {
                value("Noise mode", sony.noiseMode?.title ?? "—")
                value("Ambient level", "\(sony.ambientLevel)")
                value("Equalizer preset", sony.equalizerPreset?.title ?? "—")
                value("Equalizer bands", sony.equalizerBands.map(String.init).joined(separator: ", "))
                value("Surround", sony.surroundMode?.title ?? "—")
                value("Sound position", sony.soundPosition?.title ?? "—")
            }

            Section("Hardware") {
                value("Touch sensor", optionalBoolean(sony.touchSensorEnabled))
                value("Automatic power off", sony.automaticPowerOff?.title ?? "—")
                value("Optimizer", sony.optimizerStatus?.title ?? "—")
                value(
                    "Atmospheric pressure",
                    sony.atmosphericPressure.map {
                        "\($0.formatted(.number.precision(.fractionLength(1)))) atm"
                    } ?? "—"
                )
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func value(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .monospaced()
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func optionalBoolean(_ value: Bool?) -> String {
        value.map { $0 ? "true" : "false" } ?? "—"
    }
}

private struct SonyControlsView: View {
    @EnvironmentObject private var sony: SonyMDRProvider
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("Connection") {
                Toggle(
                    "Restore settings on connect",
                    isOn: Binding(
                        get: { sony.restoreOnConnectEnabled },
                        set: { sony.setRestoreOnConnectEnabled($0) }
                    ))
                if sony.connectionState != .ready {
                    if sony.devices.isEmpty {
                        Text("Pair and power on compatible Sony MDR headphones, then refresh paired devices.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(sony.devices) { device in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(device.name)
                                    Text(device.address)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if device.isConnected { Text("Audio connected").foregroundStyle(.secondary) }
                                Button("Connect") { sony.connect(to: device) }
                                    .disabled(sony.connectionState.isConnecting)
                            }
                        }
                    }
                    Button("Refresh devices") { sony.refreshDevices() }
                        .disabled(sony.connectionState.isConnecting)
                }
            }

            if sony.capabilities.contains(.noiseControl) || sony.capabilities.contains(.ambientLevel) {
                Section("Noise Control") {
                    Picker(
                        "Mode",
                        selection: Binding(
                            get: { sony.noiseMode ?? .off },
                            set: { sony.setNoiseMode($0) }
                        )
                    ) {
                        ForEach(sony.supportedNoiseModes) { mode in Text(mode.title).tag(mode) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(sony.connectionState != .ready)

                    if sony.capabilities.contains(.ambientLevel), sony.noiseMode == .ambient {
                        LabeledContent("Ambient level") {
                            HStack {
                                Slider(
                                    value: Binding(
                                        get: { Double(sony.ambientLevel) },
                                        set: { sony.setAmbientLevel(Int($0.rounded())) }
                                    ),
                                    in: 1...20,
                                    step: 1
                                )
                                Text("\(sony.ambientLevel)").monospacedDigit().frame(width: 28)
                            }
                        }
                        .disabled(sony.connectionState != .ready)
                    }
                }
            }

            if sony.capabilities.contains(.soundQualityMode) {
                Section("Bluetooth Audio") {
                    Picker(
                        "Sound quality mode",
                        selection: Binding(
                            get: { sony.soundQualityMode ?? .prioritizeSoundQuality },
                            set: { sony.setSoundQualityMode($0) }
                        )
                    ) {
                        ForEach(SonyV1SoundQualityMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    LabeledContent("Current codec") {
                        Text(sony.codecName ?? "—")
                            .foregroundStyle(.secondary)
                    }
                    Text("Changing this mode reconnects Bluetooth audio.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if sony.capabilities.contains(.equalizer) {
                Section("Equalizer") {
                    SonyEqualizerControls(sony: sony)
                }
            }

            if sony.capabilities.contains(.surroundSound) || sony.capabilities.contains(.soundPosition) {
                Section("Virtual Sound") {
                    if sony.capabilities.contains(.surroundSound) {
                        Picker(
                            "Surround (VPT)",
                            selection: Binding(
                                get: { sony.surroundMode ?? .off },
                                set: { sony.setSurroundMode($0) }
                            )
                        ) {
                            ForEach(SonyV1SurroundMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                    }
                    if sony.capabilities.contains(.soundPosition) {
                        Picker(
                            "Sound position",
                            selection: Binding(
                                get: { sony.soundPosition ?? .off },
                                set: { sony.setSoundPosition($0) }
                            )
                        ) {
                            ForEach(SonyV1SoundPosition.allCases) { position in
                                Text(position.title).tag(position)
                            }
                        }
                    }
                }
            }

            if sony.capabilities.contains(.audioUpsampling) || sony.capabilities.contains(.touchSensor)
                || sony.capabilities.contains(.automaticPowerOff) || sony.capabilities.contains(.noiseOptimizer)
            {
                Section("Headphone Controls") {
                    if sony.capabilities.contains(.audioUpsampling) {
                        Toggle(
                            "DSEE HX (Auto)",
                            isOn: Binding(
                                get: { sony.dseeEnabled ?? false },
                                set: { sony.setDSEEEnabled($0) }
                            ))
                        if sony.dseeEnabled == true,
                            let codec = sony.codecName,
                            codec.caseInsensitiveCompare("SBC") != .orderedSame
                        {
                            Text("DSEE HX is enabled but inactive while the current codec is \(codec).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if sony.capabilities.contains(.touchSensor) {
                        Toggle(
                            "Touch sensor",
                            isOn: Binding(
                                get: { sony.touchSensorEnabled ?? true },
                                set: { sony.setTouchSensorEnabled($0) }
                            ))
                    }

                    if sony.capabilities.contains(.automaticPowerOff) {
                        Picker(
                            "Automatic power off",
                            selection: Binding(
                                get: { sony.automaticPowerOff ?? .off },
                                set: { sony.setAutomaticPowerOff($0) }
                            )
                        ) {
                            ForEach(SonyV1AutomaticPowerOff.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                    }

                    if sony.capabilities.contains(.noiseOptimizer) {
                        LabeledContent("Noise cancelling optimizer") {
                            if sony.optimizerStatus?.isRunning == true {
                                Button("Cancel") { sony.setOptimizerRunning(false) }
                            } else {
                                Button("Run…") { sony.setOptimizerRunning(true) }
                            }
                        }
                        if let status = sony.optimizerStatus {
                            LabeledContent("Optimizer status") {
                                Text(status.title).foregroundStyle(.secondary)
                            }
                        }
                        if let pressure = sony.atmosphericPressure {
                            LabeledContent("Atmospheric pressure") {
                                Text("\(pressure.formatted(.number.precision(.fractionLength(1)))) atm")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section("Volume") {
                Toggle(
                    "Synchronize with macOS",
                    isOn: Binding(
                        get: { settings.volumeSynchronizationEnabled(for: sony.providerID) },
                        set: { settings.setVolumeSynchronizationEnabled($0, for: sony.providerID) }
                    ))
                if sony.capabilities.contains(.deviceVolume) {
                    LabeledContent("Headphones volume") {
                        Text(sony.deviceVolume.map { "\($0) / 30" } ?? "—")
                            .monospacedDigit()
                    }
                }
            }

            BatteryHistorySection(
                providerID: sony.providerID,
                deviceID: sony.connectedDeviceID,
                currentLevel: sony.batteryPercent,
                isCharging: sony.isCharging,
                isConnected: sony.connectionState == .ready
            )
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}

private struct SonyEqualizerControls: View {
    @ObservedObject var sony: SonyMDRProvider
    @State private var values = Array(repeating: 0.0, count: 6)
    @State private var editingBand: Int?

    private let labels = ["400 Hz", "1 kHz", "2.5 kHz", "6.3 kHz", "16 kHz", "Clear Bass"]

    var body: some View {
        Picker(
            "Preset",
            selection: Binding(
                get: { sony.equalizerPreset ?? .off },
                set: { sony.setEqualizerPreset($0) }
            )
        ) {
            ForEach(SonyV1EqualizerPreset.allCases) { preset in
                Text(preset.title).tag(preset)
            }
        }

        ForEach(labels.indices, id: \.self) { index in
            LabeledContent(labels[index]) {
                HStack {
                    Slider(
                        value: Binding(
                            get: { values[index] },
                            set: { values[index] = $0 }
                        ),
                        in: -10...10,
                        step: 1,
                        onEditingChanged: { isEditing in
                            if isEditing {
                                editingBand = index
                            } else {
                                sony.setEqualizerBand(at: index, value: Int(values[index].rounded()))
                                editingBand = nil
                            }
                        }
                    )
                    Text(signed(Int(values[index].rounded())))
                        .monospacedDigit()
                        .frame(width: 30, alignment: .trailing)
                }
            }
        }
        .onAppear { synchronizeBands(sony.equalizerBands) }
        .onReceive(sony.$equalizerBands) { bands in
            guard editingBand == nil else { return }
            synchronizeBands(bands)
        }
    }

    private func synchronizeBands(_ bands: [Int]) {
        values = Array((bands + Array(repeating: 0, count: 6)).prefix(6)).map(Double.init)
    }

    private func signed(_ value: Int) -> String {
        value > 0 ? "+\(value)" : "\(value)"
    }
}

private struct ControlsView: View {
    @EnvironmentObject private var controller: BowersWilkinsProvider
    private let bands = ["Low", "Low-mid", "Mid", "High-mid", "High"]
    private let sleepOptions = [0, 5, 10, 15, 30, 60, 120]

    var body: some View {
        Form {
            Section("Connection") {
                Toggle(
                    "Restore settings on connect",
                    isOn: Binding(
                        get: { controller.restoreOnConnectEnabled },
                        set: { controller.setRestoreOnConnectEnabled($0) }
                    ))
                Text("Reapplies this Mac's saved profile after the control connection is ready.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Bluetooth Audio") {
                LabeledContent("Sound quality mode") {
                    Text("Automatic")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Source") {
                    Text(controller.audioSource)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Current codec") {
                    Text(controller.audioCodec)
                        .foregroundStyle(.secondary)
                }
                if controller.samplingRate != "—" {
                    LabeledContent("Sample rate") {
                        Text(controller.samplingRate)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(
                    "This Bowers & Wilkins generation negotiates Bluetooth quality automatically and does not expose a writable quality/stability preference."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if controller.capabilities.contains(.noiseControl) {
                Section("Noise Control") {
                    Picker(
                        "Mode",
                        selection: Binding(
                            get: { controller.ancMode },
                            set: { controller.setANC($0) }
                        )
                    ) {
                        ForEach(ANCMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }

            if controller.capabilities.contains(.equalizer) {
                Section("Five-band Equalizer") {
                    Toggle(
                        "Bypass EQ",
                        isOn: Binding(
                            get: { controller.eqBypassed },
                            set: { controller.setEQBypassed($0) }
                        ))
                    ForEach(0..<5, id: \.self) { index in
                        LabeledContent(bands[index]) {
                            HStack {
                                Slider(
                                    value: Binding(
                                        get: { Double(controller.eqValues[index]) },
                                        set: { controller.setEQBand(index, value: Int($0.rounded())) }
                                    ),
                                    in: -60...60,
                                    step: 1,
                                    onEditingChanged: { editing in if !editing { controller.commitEQ() } }
                                )
                                Text(String(format: "%+d", controller.eqValues[index]))
                                    .monospacedDigit()
                                    .frame(width: 38, alignment: .trailing)
                            }
                        }
                    }
                }
            }

            if controller.capabilities.contains(.wearSensor) || controller.capabilities.contains(.standbyTimer)
                || controller.capabilities.contains(.customButton) || controller.capabilities.contains(.voicePrompts)
            {
                Section("Sensors and Behavior") {
                    if controller.capabilities.contains(.wearSensor) {
                        Toggle(
                            "Wear sensor",
                            isOn: Binding(
                                get: { controller.wearSensorEnabled },
                                set: { controller.setWearSensor($0) }
                            ))
                        LabeledContent("Wear sensitivity") {
                            Picker(
                                "Sensitivity",
                                selection: Binding(
                                    get: { controller.wearSensitivity },
                                    set: { controller.setWearSensitivity($0) }
                                )
                            ) {
                                Text("Low").tag(1)
                                Text("Medium").tag(2)
                                Text("High").tag(3)
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(width: 180, alignment: .trailing)
                        }
                    }
                    if controller.capabilities.contains(.standbyTimer) {
                        LabeledContent("Standby timer") {
                            Picker(
                                "Standby",
                                selection: Binding(
                                    get: { controller.sleepMinutes },
                                    set: { controller.setSleepMinutes($0) }
                                )
                            ) {
                                ForEach(sleepOptions, id: \.self) { value in
                                    Text(value == 0 ? "Never" : "\(value) min").tag(value)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(width: 180, alignment: .trailing)
                        }
                    }
                    if controller.capabilities.contains(.customButton) {
                        LabeledContent("Quick-action button") {
                            Picker(
                                "Button",
                                selection: Binding(
                                    get: { controller.customButtonMode },
                                    set: { controller.setCustomButton($0) }
                                )
                            ) {
                                ForEach(CustomButtonMode.allCases) { Text($0.title).tag($0) }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(width: 180, alignment: .trailing)
                        }
                    }
                    if controller.capabilities.contains(.voicePrompts) {
                        Toggle(
                            "Voice prompts",
                            isOn: Binding(
                                get: { controller.voicePromptsEnabled },
                                set: { controller.setVoicePrompts($0) }
                            ))
                    }
                }
            }

            if controller.capabilities.contains(.spatialAudio) {
                Section("True Immersion") {
                    Toggle(
                        "Spatial audio",
                        isOn: Binding(
                            get: { controller.spatialAudioEnabled },
                            set: { controller.setSpatialAudio($0) }
                        ))
                    Picker(
                        "Preset",
                        selection: Binding(
                            get: { controller.spatialAudioPreset },
                            set: { controller.setSpatialAudioPreset($0) }
                        )
                    ) {
                        Text("Focused").tag(0)
                        Text("Balanced").tag(1)
                        Text("Expanded").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .disabled(!controller.spatialAudioEnabled)
                }
            }

            Section("Identity") {
                if controller.capabilities.contains(.deviceName) {
                    HStack {
                        TextField("Headphone name", text: $controller.localName)
                            .textFieldStyle(.roundedBorder)
                        Button("Rename") { controller.commitLocalName() }
                            .disabled(controller.localName.isEmpty)
                    }
                }
                infoRow("Firmware", controller.softwareVersion)
                infoRow("Serial", controller.serialNumber)
                infoRow("MAC", controller.macAddress)
                if !controller.pairedDevices.isEmpty {
                    Text("Paired sources").font(.subheadline.weight(.semibold))
                    ForEach(controller.pairedDevices) { device in
                        HStack {
                            Circle()
                                .fill(device.connected ? Color.green : Color.secondary.opacity(0.35))
                                .frame(width: 7, height: 7)
                            VStack(alignment: .leading) {
                                Text(device.name)
                                Text(device.address).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if device.connected { Text("Connected").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }

            BatteryHistorySection(
                providerID: controller.providerID,
                deviceID: controller.connectedDeviceID,
                currentLevel: controller.batteryPercent,
                isCharging: controller.isCharging,
                isConnected: controller.isReady
            )
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
        .disabled(!controller.isReady)
    }

    private func infoRow(_ name: String, _ value: String) -> some View {
        LabeledContent(name) { Text(value).textSelection(.enabled).foregroundStyle(.secondary) }
    }
}

private struct InspectorView: View {
    @EnvironmentObject private var controller: BowersWilkinsProvider

    private var readings: [ProbeReading] {
        controller.readings.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Read-only protocol inspector").font(.headline)
                    Text(
                        "Queries all safe no-argument values found in the APK. Unsupported commands are shown with their device error code."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Read all") { controller.probeEverything() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!controller.isReady)
            }
            List(readings) { reading in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(reading.name)
                        Text(reading.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if reading.errorCode == 0 {
                        Text(reading.value).monospaced().textSelection(.enabled)
                    } else {
                        Text("error \(reading.errorCode)").foregroundStyle(.red).monospaced()
                    }
                }
            }
            .overlay {
                if readings.isEmpty {
                    ContentUnavailableView(
                        "No readings yet", systemImage: "waveform.path.ecg",
                        description: Text("Connect the headphones and press Read all."))
                }
            }
        }
        .padding(.vertical, 12)
    }
}

private struct ProtocolTransportLogView: View {
    let entries: [TransportLogEntry]
    let isReady: Bool
    let refresh: () -> Void

    var body: some View {
        Group {
            if entries.isEmpty {
                ContentUnavailableView {
                    Label("No protocol events yet", systemImage: "terminal")
                } description: {
                    Text(
                        isReady
                            ? "Request the current values to generate a protocol trace."
                            : "Connect the headphones to begin recording protocol events."
                    )
                } actions: {
                    if isReady {
                        Button("Refresh Values", action: refresh)
                    }
                }
            } else {
                List(entries.reversed()) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Text(entry.direction.rawValue)
                            .font(.caption.bold().monospaced())
                            .foregroundStyle(
                                entry.direction == .incoming
                                    ? .green : entry.direction == .outgoing ? .blue : .secondary
                            )
                            .frame(width: 34, alignment: .leading)
                        Text(entry.time, style: .time).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text(entry.text).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
        }
        .padding(.vertical, 12)
    }
}
