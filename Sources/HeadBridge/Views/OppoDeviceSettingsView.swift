import Foundation
import SwiftUI

struct OppoDeviceSettingsView: View {
    @EnvironmentObject private var provider: OppoProvider
    let deviceName: String
    @State private var showsEQEditor = false
    var body: some View {
        VStack(spacing: 0) {
            DeviceDetailHeader(
                name: provider.connectionState == .ready ? provider.connectedName : deviceName,
                vendor: "OPPO",
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
                    .help("Refresh all OPPO values")
                    Button("Disconnect") { provider.disconnect() }
                } else {
                    Button("Refresh") { provider.refresh() }
                }
            }

            Divider()

            Form {
                connectionSection
                soundSection
                equalizerSection
                statusSection
                featureSection
                dualConnectionSection
                gestureSection
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
        .navigationTitle("OPPO")
        .sheet(isPresented: $showsEQEditor) {
            CustomEQEditorView().environmentObject(provider)
        }
    }

    private var connectionSection: some View {
        Section("Connection") {
            Toggle(
                "Restore settings on connect",
                isOn: Binding(
                    get: { provider.restoreOnConnectEnabled },
                    set: { provider.setRestoreOnConnectEnabled($0) }
                )
            )
            Text("Reapplies the saved noise-control mode after the control connection is ready.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var soundSection: some View {
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
                        Text(noiseTitle(mode)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if provider.noiseMode == .noiseCancellation, !provider.supportedNoiseLevels.isEmpty {
                    Picker(
                        "Noise depth",
                        selection: Binding(
                            get: { provider.noiseLevel ?? .deep },
                            set: { provider.setNoiseLevel($0) }
                        )
                    ) {
                        ForEach(provider.supportedNoiseLevels) { level in
                            Text(noiseLevelTitle(level)).tag(level)
                        }
                    }
                    .pickerStyle(.segmented)

                    if provider.noiseLevel == .smart, let smart = provider.smartNoiseLevel {
                        Text("Smart is currently using: \(noiseLevelTitle(smart))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("The firmware exposes three depth levels only; a continuous strength write is rejected by the earbuds.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    DisclosureGroup("Touch-and-hold cycle") {
                        ForEach(holdCycleLevels, id: \.0) { item in
                            Toggle(item.1, isOn: Binding(
                                get: { provider.holdCycleMask & item.0 != 0 },
                                set: { enabled in
                                    var mask = provider.holdCycleMask
                                    if enabled { mask |= item.0 } else { mask &= ~item.0 }
                                    if mask.nonzeroBitCount >= 2 {
                                        provider.setHoldCycleMask(mask)
                                    }
                                }
                            ))
                        }
                        Text("Pick at least two modes. The earbuds cycle these while you touch and hold.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }

        if provider.spatialAudioSupported || provider.gameModeSupported || provider.gameSound != nil {
            Section("Sound") {
                if provider.spatialAudioSupported {
                    Toggle(
                        "Spatial audio",
                        isOn: Binding(
                            get: { provider.spatialEnabled ?? false },
                            set: { provider.setSpatialEnabled($0) }
                        )
                    )
                    Text(spatialSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if provider.spatialEnabled == true {
                        Picker(
                            "Spatial mode",
                            selection: Binding(
                                get: { provider.spatialType ?? 1 },
                                set: { provider.setSpatialType($0) }
                            )
                        ) {
                            Text("Fixed").tag(1)
                            Text("Head tracking (experimental)").tag(2)
                        }
                        .pickerStyle(.menu)
                        if provider.spatialType == 2 {
                            Text("The firmware accepts type 2, but this model has no head-tracking sensor and reports no head-motion commands. Expect no audible change; use Fixed.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    if provider.featureStates[0x18] == 0x01 {
                        Text("Hi-Res is on. Spatial and Hi-Res are mutually exclusive; turning spatial on switches Hi-Res off and restarts Bluetooth.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if provider.gameModeSupported {
                    Toggle(
                        "Game mode (low latency)",
                        isOn: Binding(
                            get: { provider.gameModeEnabled ?? false },
                            set: { provider.setGameModeEnabled($0) }
                        )
                    )
                    Text("Reduces audio latency. Independent of the game sound effect.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let gameSound = provider.gameSound, !gameSound.options.isEmpty {
                    Picker(
                        "Game sound effects",
                        selection: Binding(
                            get: { gameSound.selected },
                            set: { provider.setGameSoundType($0) }
                        )
                    ) {
                        ForEach(gameSound.options, id: \.self) { type in
                            Text(gameSoundLabel(type)).tag(type)
                        }
                    }
                    .pickerStyle(.menu)
                    Text("Applies the shooting-game sound effect. Independent of game mode.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !codecOptions.isEmpty {
                    Picker(
                        "Codec",
                        selection: Binding(
                            get: { provider.currentCodec ?? 2 },
                            set: { provider.setCodec($0) }
                        )
                    ) {
                        ForEach(codecOptions, id: \.self) { codec in
                            Text(OppoCodecName.name(for: codec)).tag(codec)
                        }
                    }
                    .pickerStyle(.menu)
                    Text("Changing codec restarts Bluetooth. The other multipoint device still negotiates its own codec.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if provider.featureStates[0x18] != nil {
                    Toggle(
                        "Hi-Res (LHDC only)",
                        isOn: Binding(
                            get: { provider.featureStates[0x18] == 0x01 },
                            set: { provider.setHiResEnabled($0) }
                        )
                    )
                    Text("Changing Hi-Res restarts the Bluetooth link and turns spatial audio off. It only applies to LHDC.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if provider.featureStates[0x18] == 0x01,
                        let codec = provider.currentCodec,
                        codec != 3, codec != 7, codec != 8
                    {
                        Text("Hi-Res is flagged on, but this link is \(provider.codecName ?? "not LHDC"). macOS must negotiate LHDC or LDAC for it to take effect.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var equalizerSection: some View {
        if !provider.eqPresets.isEmpty {
            Section("Equalizer") {
                Picker(
                    "Preset",
                    selection: Binding<UInt8?>(
                        get: { provider.eqCurrentID },
                        set: { identifier in
                            if let identifier { provider.setEQPreset(id: identifier) }
                        }
                    )
                ) {
                    ForEach(provider.eqPresets) { preset in
                        Text(eqPresetName(preset)).tag(Optional(preset.id))
                    }
                }
                .pickerStyle(.menu)

                if let preset = selectedEQPreset, !preset.bands.isEmpty {
                    Text(Self.bandSummary(preset))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Button("Edit custom EQ…") { showsEQEditor = true }
            }
        }
    }

    private var selectedEQPreset: OppoEQPreset? {
        provider.eqPresets.first { $0.id == provider.eqCurrentID }
    }

    @ViewBuilder
    private var statusSection: some View {
        Section("Status") {
            LabeledContent("Connection") {
                Text(connectionTitle(provider.connectionState)).foregroundStyle(.secondary)
            }
            if let left = provider.leftBatteryPercent {
                batteryRow("Left", level: left)
            }
            if let right = provider.rightBatteryPercent {
                batteryRow("Right", level: right)
            }
            if let caseLevel = provider.caseBatteryPercent {
                batteryRow("Case", level: caseLevel)
            }
            if let firmware = provider.firmwareVersion {
                LabeledContent("Firmware") { Text(firmware).foregroundStyle(.secondary) }
            }
            if let productID = provider.productID {
                LabeledContent("Product ID") {
                    Text(String(format: "0x%06X", productID))
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            if let codec = provider.codecName {
                LabeledContent("Codec") { Text(codec).foregroundStyle(.secondary) }
                Text("Reported by the earbuds' A2DP link.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let volume = provider.alertVolume {
                Picker(
                    "Alert volume",
                    selection: Binding(
                        get: { volume },
                        set: { provider.setAlertVolume($0) }
                    )
                ) {
                    ForEach(1...10, id: \.self) { level in
                        Text("\(level) / 10").tag(level)
                    }
                }
                .pickerStyle(.menu)
                Text("Changing this plays a short prompt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(provider.isRinging ? "Ringing…" : "Ring earbuds (5 s)") {
                provider.ringEarbuds()
            }
            .disabled(!provider.canRingEarbuds || provider.isRinging)
            if provider.ringBlockedByWearing {
                Text("Take both earbuds out of your ears before ringing. The ring is blocked while either bud is worn.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if provider.wearing == nil {
                Text("Wearing status is not known yet; ringing stays disabled until both earbuds are confirmed out of ear.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Both earbuds are out of ear; ringing is safe.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let wearing = provider.wearing {
                LabeledContent("Left earbud") {
                    Text(
                        wearingStatusLabel(
                            status: wearing.left,
                            inEar: wearing.leftInEar,
                            inCase: wearing.leftInCase
                        )
                    )
                    .foregroundStyle(.secondary)
                }
                LabeledContent("Right earbud") {
                    Text(
                        wearingStatusLabel(
                            status: wearing.right,
                            inEar: wearing.rightInEar,
                            inCase: wearing.rightInCase
                        )
                    )
                    .foregroundStyle(.secondary)
                }
                LabeledContent("Case lid") {
                    Text(wearing.lidOpen ? "Open" : "Closed").foregroundStyle(.secondary)
                }
                DisclosureGroup("Wearing sensor bits") {
                    LabeledContent("Left") {
                        Text(wearingBitSummary(wearing.left))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Right") {
                        Text(wearingBitSummary(wearing.right))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Case") {
                        Text(wearingBitSummary(wearing.caseStatus))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Text("The protocol exposes one in-ear bit per bud, not individual capacitive points.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var featureSection: some View {
        Section("Feature switches") {
            if provider.featureStates[0x04] != nil {
                featureToggle("Auto play/pause", identifier: 0x04) {
                    provider.setAutoPauseEnabled($0)
                }
            }
            if provider.featureStates[0x11] != nil {
                featureToggle("Dual connection", identifier: 0x11) {
                    provider.setDualConnectionEnabled($0)
                }
            }
            if provider.featureStates[0x37] != nil {
                featureToggle("Windows Swift Pair", identifier: 0x37) {
                    provider.setSwiftPairEnabled($0)
                }
            }

            Text(
                "Dual connection off disables multipoint until you turn it back on. Hi-Res lives in the Sound section because changing it restarts the Bluetooth link."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func featureToggle(
        _ title: String,
        identifier: UInt8,
        setter: @escaping (Bool) -> Void
    ) -> some View {
        Toggle(
            title,
            isOn: Binding(
                get: { provider.featureStates[identifier] == 0x01 },
                set: { setter($0) }
            )
        )
    }

    @ViewBuilder
    private var dualConnectionSection: some View {
        if !provider.dualDevices.isEmpty {
            Section("Dual Connection") {
                ForEach(provider.dualDevices) { device in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(device.name)
                            if device.isThisHost { badge("This Mac") }
                            if device.isMainAudio { badge("Audio") }
                            if device.mac == provider.preferredDeviceMAC { badge("Preferred") }
                        }
                        Text(device.mac)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                        if !device.isThisHost {
                            HStack(spacing: 8) {
                                if device.isConnected {
                                    Button("Disconnect") {
                                        provider.disconnectDualDevice(device.mac)
                                    }
                                } else {
                                    Button("Connect") {
                                        provider.connectDualDevice(device.mac)
                                    }
                                }
                                if device.mac != provider.preferredDeviceMAC {
                                    Button("Make preferred") {
                                        provider.setPreferredDevice(device.mac)
                                    }
                                }
                            }
                            .buttonStyle(.link)
                        }
                    }
                    .padding(.vertical, 1)
                }
                if provider.preferredDeviceMAC != nil {
                    Button("Automatic preferred device") {
                        provider.clearPreferredDevice()
                    }
                    .buttonStyle(.link)
                }
                Text("Connect/disconnect affects multipoint audio. The preferred device is what the earbuds try first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var gestureSection: some View {
        if !provider.gestures.isEmpty {
            Section("Gesture Bindings") {
                ForEach(["Left", "Right", "Both"], id: \.self) { sideKey in
                    let rows = gestureRows.filter { $0.sideKey == sideKey }
                    if !rows.isEmpty {
                        DisclosureGroup(gestureSideLabel(sideKey)) {
                            ForEach(rows) { row in
                                let options = gestureFunctions(for: row.entries[0])
                                HStack {
                                    Text(row.actionLabel)
                                    Spacer()
                                    Picker(
                                        "",
                                        selection: Binding(
                                            get: { row.function },
                                            set: {
                                                provider.setGestureFunction(
                                                    bindingIDs: row.entries.map(\.id),
                                                    function: $0
                                                )
                                            }
                                        )
                                    ) {
                                        ForEach(options.indices, id: \.self) { index in
                                            Text(options[index].1).tag(options[index].0)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(width: 200)
                                }
                            }
                        }
                    }
                }
                Text("14 slots: single, double, triple, hold, and slide on each bud, plus call gestures. Every function is offered for every slot. The firmware accepts the write and the table is read back; combinations it does not implement may have no audible effect. The table is stored on the earbuds, so it survives a case/reconnect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var gestureRows: [OppoGestureRow] {
        let grouped = Dictionary(grouping: provider.gestures) { binding in
            let group = binding.button == 6 ? "call" : "main"
            let action = binding.action == 5 ? "slide" : "\(binding.action)"
            return "\(binding.sideLabel)|\(group)|\(action)"
        }

        return grouped.map { key, entries in
            let first = entries[0]
            let isCall = first.button == 6
            let groupLabel = isCall ? "Call" : "Main"
            let actionLabel = gestureActionLabel(first.action)
            let display = isCall ? "\(groupLabel) · \(actionLabel)" : actionLabel
            return OppoGestureRow(
                id: key,
                sideKey: first.sideLabel,
                groupRank: isCall ? 1 : 0,
                actionRank: Int(first.action),
                actionLabel: display,
                entries: entries,
                function: first.function
            )
        }
        .sorted { lhs, rhs in
            let leftOrder = ["Left": 0, "Right": 1, "Both": 2]
            let lhsSide = leftOrder[lhs.sideKey] ?? 3
            let rhsSide = leftOrder[rhs.sideKey] ?? 3
            if lhsSide != rhsSide { return lhsSide < rhsSide }
            if lhs.groupRank != rhs.groupRank { return lhs.groupRank < rhs.groupRank }
            return lhs.actionRank < rhs.actionRank
        }
    }

    private func gestureSideLabel(_ key: String) -> String {
        switch key {
        case "Left": "Left"
        case "Right": "Right"
        case "Both": "Both"
        default: key
        }
    }

    private func batteryRow(_ title: String, level: Int) -> some View {
        LabeledContent(title) {
            HStack(spacing: 5) {
                Image(systemName: HeadphoneBatterySymbol.name(for: level))
                if provider.isCharging == true {
                    Image(systemName: "bolt.fill")
                }
                Text("\(level)%").monospacedDigit()
            }
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.14), in: Capsule())
    }

    private var codecOptions: [Int] {
        var options = Set(provider.availableCodecs)
        options.formUnion([2, 3, 7, 8])
        if let current = provider.currentCodec { options.insert(current) }
        return options.sorted()
    }

    private var spatialSubtitle: String {
        switch provider.spatialType {
        case 0: "Off."
        case 1: "Fixed spatial audio is on. This model has no head tracking."
        case 2: "Head tracking mode is selected, but this model has no head-tracking sensor."
        default: "Fixed spatial audio; this model has no head tracking."
        }
    }

    private func connectionTitle(_ state: HeadphoneConnectionState) -> String {
        switch state {
        case .idle: "Not connected"
        case .scanning: "Scanning…"
        case .connecting: "Connecting…"
        case .ready: "Connected"
        case .failed(let message): message
        }
    }

    private var holdCycleLevels: [(UInt16, String)] {
        [
            (0x01, "Off"),
            (0x02, "Noise Cancellation"),
            (0x04, "Ambient"),
        ]
    }

    private func noiseLevelTitle(_ level: OppoNoiseLevel) -> String {
        switch level {
        case .light: "Light"
        case .deep: "Deep"
        case .smart: "Smart"
        }
    }

    private func noiseTitle(_ mode: HeadphoneNoiseMode) -> String {
        switch mode {
        case .off: "Off"
        case .noiseCancellation: "Noise Cancellation"
        case .ambient: "Ambient"
        case .windReduction: "Wind Reduction"
        }
    }

    private func eqPresetName(_ preset: OppoEQPreset) -> String {
        switch preset.name {
        case "Ultimate": "Ultimate"
        case "Thundering Bass": "Thundering Bass"
        case "Pure Vocals": "Pure Vocals"
        default: preset.name
        }
    }

    private func gameSoundLabel(_ type: Int) -> String {
        switch type {
        case 0: "Off"
        case 3: "Shooting game"
        default: "Type \(type)"
        }
    }

    private func wearingBitSummary(_ status: UInt8?) -> String {
        guard let status else { return "No data" }
        let yes = "true"
        let no = "false"
        return [
            String(format: "0x%02X", status),
            "outOfCase \(status & 0x01 != 0 ? yes : no)",
            "inEar \(status & 0x02 != 0 ? yes : no)",
            "lidOpen \(status & 0x04 != 0 ? yes : no)",
            "flag \(status & 0x08 != 0 ? yes : no)",
        ].joined(separator: " · ")
    }

    private func wearingStatusLabel(status: UInt8?, inEar: Bool, inCase: Bool) -> String {
        guard status != nil else { return "Unknown" }
        if inEar { return "In ear" }
        if inCase { return "In case" }
        return "Out of ear"
    }

    private func gestureActionLabel(_ action: UInt8) -> String {
        switch action {
        case 1: "Single"
        case 2: "Double"
        case 3: "Triple"
        case 4: "Touch and hold"
        case 5: "Slide"
        case 6: "Long hold"
        default: "Action \(action)"
        }
    }

    private func gestureFunctionLabel(_ function: UInt8) -> String {
        switch function {
        case 0x00: "None"
        case 0x01: "Play / pause"
        case 0x03: "Voice assistant"
        case 0x05: "Previous track"
        case 0x06: "Next track"
        case 0x07: "Volume"
        case 0x08: "Noise control cycle"
        case 0x09: "Favourite music"
        case 0x0A: "Switch track"
        case 0x0B: "Volume up"
        case 0x0C: "Volume down"
        case 0x0D: "Switch devices"
        case 0x11: "Game mode"
        case 0x12: "Zen mode"
        case 0x16: "Collect music"
        case 0x1C: "Decline call"
        case 0x1D: "Answer / end call"
        default: String(format: "Function %02X", function)
        }
    }

    private func gestureFunctions(
        for binding: OppoGestureBinding
    ) -> [(UInt8, String)] {
        // The firmware accepts any function code for any slot and reads the
        // table back. The vendor app only offers a recommended subset; the
        // table itself is free-form, but combinations the gesture engine does
        // not implement may have no audible effect.
        var options: [(UInt8, String)] = [
            (0x00, "None"),
            (0x01, "Play / pause"),
            (0x03, "Voice assistant"),
            (0x05, "Previous track"),
            (0x06, "Next track"),
            (0x07, "Volume"),
            (0x08, "Noise control cycle"),
            (0x09, "Favourite music"),
            (0x0A, "Switch track"),
            (0x0B, "Volume up"),
            (0x0C, "Volume down"),
            (0x0D, "Switch devices"),
            (0x11, "Game mode"),
            (0x12, "Zen mode"),
            (0x16, "Collect music"),
            (0x1C, "Decline call"),
            (0x1D, "Answer / end call"),
        ]
        if !options.contains(where: { $0.0 == binding.function }) {
            options.insert((binding.function, gestureFunctionLabel(binding.function)), at: 0)
        }
        return options
    }

    private static func bandSummary(_ preset: OppoEQPreset) -> String {
        preset.bands
            .map { band in
                let frequency =
                    band.frequency >= 1_000
                    ? "\(band.frequency / 1_000)k"
                    : "\(band.frequency)"
                let gain = band.gain > 0 ? "+\(band.gain)" : "\(band.gain)"
                return "\(frequency) \(gain)"
            }
            .joined(separator: " · ")
    }
}

private struct OppoGestureRow: Identifiable {
    let id: String
    let sideKey: String
    let groupRank: Int
    let actionRank: Int
    let actionLabel: String
    let entries: [OppoGestureBinding]
    let function: UInt8
}
