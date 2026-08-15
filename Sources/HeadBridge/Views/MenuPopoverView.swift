import AppKit
import CoreAudio
import SwiftUI

struct MenuPopoverView: View {
    @EnvironmentObject private var manager: HeadphoneManager
    @EnvironmentObject private var controller: BowersWilkinsProvider
    @EnvironmentObject private var sony: SonyMDRProvider
    @EnvironmentObject private var systemAudio: SystemAudioController
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme
    @State private var expandedDeviceID: AudioDeviceID?
    @State private var showsInputDevices = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                soundHeader
                Divider().padding(.horizontal, 14)
                outputSection

                if showsInputDevices {
                    if expandedDeviceID != systemAudio.defaultDeviceID {
                        Divider().padding(.horizontal, 14)
                    }
                    inputSection
                }

                if let provider = activeProvider, provider.connectionState != .ready {
                    Divider().padding(.horizontal, 14)
                    connectionSection(provider)
                }
            }

            Divider()
            footer
        }
        .frame(width: 310)
        .background(.ultraThinMaterial)
        .onAppear {
            showsInputDevices = NSEvent.modifierFlags.contains(.option)
            expandedDeviceID = nil
            systemAudio.refresh()
            if activeProvider?.providerID == controller.providerID,
                !controller.isReady && controller.peripherals.isEmpty
            {
                controller.startScanning()
            }
        }
    }

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Input")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 9)
                .padding(.bottom, 3)

            if systemAudio.inputDevices.isEmpty {
                Text("No input devices")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            } else {
                ForEach(systemAudio.inputDevices) { device in
                    inputRow(device)
                }
            }
        }
        .padding(.bottom, 6)
    }

    private func inputRow(_ device: SystemAudioDevice) -> some View {
        let selected = systemAudio.defaultInputDeviceID == device.id
        let sticky = systemAudio.isStickyInput(device)

        return HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(selected ? Color.accentColor : Color.secondary.opacity(0.14))
                Image(systemName: device.inputIconName)
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? .white : .primary)
            }
            .frame(width: 26, height: 26)

            Text(device.name)
                .font(.system(size: 14))
                .lineLimit(1)

            Spacer(minLength: 6)

            if sticky {
                Label("Sticky", systemImage: "pin.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 14)
        .padding(.vertical, 3)
        .gesture(
            TapGesture(count: 2)
                .exclusively(before: TapGesture(count: 1))
                .onEnded { value in
                    switch value {
                    case .first:
                        systemAudio.toggleStickyInput(device)
                    case .second:
                        systemAudio.selectInput(device)
                    }
                }
        )
        .help(
            sticky
                ? "Double-click to let macOS switch input automatically"
                : "Double-click to keep macOS on this input"
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var soundHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sound")
                .font(.system(size: 14, weight: .semibold))

            HStack(spacing: 10) {
                Image(systemName: "speaker.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Slider(
                    value: Binding(
                        get: { Double(systemAudio.volume) },
                        set: { systemAudio.setVolume(Float($0)) }
                    ),
                    in: 0...1
                )
                .disabled(!systemAudio.volumeCanBeChanged)
                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            if let message = systemAudio.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Output")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 9)
                .padding(.bottom, 3)

            if systemAudio.devices.isEmpty {
                Text("No output devices")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            } else {
                ForEach(systemAudio.devices) { device in
                    outputDevice(device)
                }
            }
        }
        .padding(.bottom, 6)
    }

    private func outputDevice(_ device: SystemAudioDevice) -> some View {
        let provider = manager.provider(for: device)
        let showsControls =
            systemAudio.defaultDeviceID == device.id && expandedDeviceID == device.id
            && provider?.connectionState == .ready

        return VStack(alignment: .leading, spacing: 0) {
            outputRow(device)

            VStack(spacing: 0) {
                if let provider, showsControls {
                    providerControls(provider)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .clipped()
        }
    }

    private func outputRow(_ device: SystemAudioDevice) -> some View {
        let selected = systemAudio.defaultDeviceID == device.id
        let provider = manager.provider(for: device)
        let providerReady = provider?.connectionState == .ready
        let expanded = expandedDeviceID == device.id

        return Button {
            if provider != nil && selected && providerReady {
                withAnimation(.easeInOut(duration: 0.18)) {
                    expandedDeviceID = expanded ? nil : device.id
                }
            } else {
                systemAudio.select(device)
                if providerReady {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        expandedDeviceID = device.id
                    }
                }
            }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(selected ? Color.accentColor : Color.secondary.opacity(0.14))
                    Image(systemName: device.iconName)
                        .font(.system(size: 13))
                        .foregroundStyle(selected ? .white : .primary)
                }
                .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .font(.system(size: 14))
                        .lineLimit(1)
                    if let provider, let battery = provider.batteryPercent {
                        HStack(spacing: 4) {
                            Image(systemName: HeadphoneBatterySymbol.name(for: battery))
                            if provider.isCharging == true {
                                Image(systemName: "bolt.fill")
                            }
                            Text("\(battery)%")
                            if let codec = provider.codecName {
                                Text("· \(codec)")
                            }
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }
                }

                Spacer()
                if provider != nil && selected && providerReady {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 14)
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
    }

    private var bowersWilkinsControls: some View {
        VStack(alignment: .leading, spacing: 0) {
            if controller.capabilities.contains(.noiseControl) {
                menuSection("Noise Control") {
                    modeRow("Off", icon: "person.fill", selected: controller.ancMode == .off) {
                        controller.setANC(.off)
                    }
                    modeRow("Pass-Through", icon: "ear", selected: controller.ancMode == .passThrough) {
                        controller.setANC(.passThrough)
                    }
                    modeRow(
                        "Noise Cancellation", icon: "waveform.badge.minus",
                        selected: controller.ancMode == .noiseCancellation
                    ) {
                        controller.setANC(.noiseCancellation)
                    }
                }
            }

            if controller.capabilities.contains(.spatialAudio) {
                if controller.capabilities.contains(.noiseControl) {
                    Divider().padding(.horizontal, 14)
                }
                menuSection("True Immersion") {
                    modeRow("Off", icon: "wave.3.right.circle", selected: !controller.spatialAudioEnabled) {
                        controller.setSpatialAudio(false)
                    }
                    modeRow(
                        "Focused", icon: "dot.radiowaves.left.and.right",
                        selected: controller.spatialAudioEnabled && controller.spatialAudioPreset == 0
                    ) {
                        selectSpatialAudioPreset(0)
                    }
                    modeRow(
                        "Balanced", icon: "circle.grid.cross",
                        selected: controller.spatialAudioEnabled && controller.spatialAudioPreset == 1
                    ) {
                        selectSpatialAudioPreset(1)
                    }
                    modeRow(
                        "Expanded", icon: "arrow.up.left.and.arrow.down.right",
                        selected: controller.spatialAudioEnabled && controller.spatialAudioPreset == 2
                    ) {
                        selectSpatialAudioPreset(2)
                    }
                }
            }

            if controller.capabilities.contains(.wearSensor) || controller.capabilities.contains(.voicePrompts) {
                if controller.capabilities.contains(.noiseControl) || controller.capabilities.contains(.spatialAudio) {
                    Divider().padding(.horizontal, 14)
                }
                menuSection("Headphone Controls") {
                    if controller.capabilities.contains(.wearSensor) {
                        toggleRow(
                            "Wear sensor",
                            icon: "ear",
                            isOn: controller.wearSensorEnabled,
                            action: controller.setWearSensor
                        )
                    }
                    if controller.capabilities.contains(.voicePrompts) {
                        toggleRow(
                            "Voice prompts",
                            icon: "waveform",
                            isOn: controller.voicePromptsEnabled,
                            action: controller.setVoicePrompts
                        )
                    }
                }
            }
        }
        .background(expandedControlsSurface)
    }

    @ViewBuilder
    private func providerControls(_ provider: any HeadphoneProvider) -> some View {
        if provider.providerID == controller.providerID {
            bowersWilkinsControls
        } else if provider.providerID == sony.providerID {
            sonyControls
        }
    }

    private var sonyControls: some View {
        VStack(alignment: .leading, spacing: 0) {
            if sony.capabilities.contains(.noiseControl) || sony.capabilities.contains(.ambientLevel) {
                menuSection("Noise Control") {
                    ForEach(sony.supportedNoiseModes) { mode in
                        modeRow(mode.title, icon: mode.icon, selected: sony.noiseMode == mode) {
                            sony.setNoiseMode(mode)
                        }
                    }
                }
            }

            if sony.noiseMode == .ambient,
                sony.capabilities.contains(.ambientLevel)
            {
                Divider().padding(.horizontal, 14)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Ambient Sound")
                        .font(.system(size: 13, weight: .semibold))
                    HStack {
                        Image(systemName: "ear")
                        Slider(
                            value: Binding(
                                get: { Double(sony.ambientLevel) },
                                set: { sony.setAmbientLevel(Int($0.rounded())) }
                            ),
                            in: 1...20,
                            step: 1
                        )
                        Text("\(sony.ambientLevel)")
                            .monospacedDigit()
                            .frame(width: 24)
                    }
                }
                .padding(14)
            }

            Divider().padding(.horizontal, 14)
            menuSection("Sony Controls") {
                if sony.capabilities.contains(.soundQualityMode) {
                    SelectionPopoverRow(
                        "Sound Quality",
                        value: soundQualityMenuValue,
                        icon: "antenna.radiowaves.left.and.right",
                        options: SonyV1SoundQualityMode.allCases,
                        selected: sony.soundQualityMode,
                        optionTitle: { $0.title },
                        footer: "Current codec: \(sony.codecName ?? "—")",
                        onSelect: sony.setSoundQualityMode
                    )
                }

                if sony.capabilities.contains(.equalizer) {
                    SelectionPopoverRow(
                        "Equalizer",
                        value: sony.equalizerPreset?.title ?? "—",
                        icon: "slider.horizontal.3",
                        options: SonyV1EqualizerPreset.allCases,
                        selected: sony.equalizerPreset,
                        optionTitle: { $0.title },
                        onSelect: sony.setEqualizerPreset
                    )
                }

                if sony.capabilities.contains(.surroundSound) {
                    SelectionPopoverRow(
                        "Surround (VPT)",
                        value: sony.surroundMode?.title ?? "—",
                        icon: "dot.radiowaves.left.and.right",
                        options: SonyV1SurroundMode.allCases,
                        selected: sony.surroundMode,
                        optionTitle: { $0.title },
                        onSelect: sony.setSurroundMode
                    )
                }

                if sony.capabilities.contains(.soundPosition) {
                    SelectionPopoverRow(
                        "Sound Position",
                        value: sony.soundPosition?.title ?? "—",
                        icon: "scope",
                        options: SonyV1SoundPosition.allCases,
                        selected: sony.soundPosition,
                        optionTitle: { $0.title },
                        onSelect: sony.setSoundPosition
                    )
                }

                if sony.capabilities.contains(.audioUpsampling) {
                    toggleRow(
                        "DSEE HX (Auto)",
                        icon: "waveform.path.ecg",
                        isOn: sony.dseeEnabled ?? false,
                        action: sony.setDSEEEnabled
                    )
                }

                if sony.capabilities.contains(.touchSensor) {
                    toggleRow(
                        "Touch Sensor",
                        icon: "hand.tap",
                        isOn: sony.touchSensorEnabled ?? true,
                        action: sony.setTouchSensorEnabled
                    )
                }

                if sony.capabilities.contains(.automaticPowerOff) {
                    SelectionPopoverRow(
                        "Automatic Power Off",
                        value: sony.automaticPowerOff?.title ?? "—",
                        icon: "timer",
                        options: SonyV1AutomaticPowerOff.allCases,
                        selected: sony.automaticPowerOff,
                        optionTitle: { $0.title },
                        onSelect: sony.setAutomaticPowerOff
                    )
                }

                if sony.capabilities.contains(.noiseOptimizer) {
                    actionRow(
                        sony.optimizerStatus?.isRunning == true ? "Cancel NC Optimizer" : "Run NC Optimizer…",
                        icon: "waveform.badge.magnifyingglass"
                    ) {
                        sony.setOptimizerRunning(sony.optimizerStatus?.isRunning != true)
                    }
                }

                toggleRow(
                    "Sync volume with macOS",
                    icon: "speaker.wave.2.fill",
                    isOn: settings.volumeSynchronizationEnabled(for: sony.providerID),
                    action: {
                        settings.setVolumeSynchronizationEnabled($0, for: sony.providerID)
                    }
                )
            }
        }
        .background(expandedControlsSurface)
    }

    private var soundQualityMenuValue: String {
        switch sony.soundQualityMode {
        case .prioritizeSoundQuality: "Quality"
        case .prioritizeStableConnection: "Stable"
        case nil: "—"
        }
    }

    private var expandedControlsSurface: some View {
        Rectangle()
            .fill(Color.primary.opacity(colorScheme == .dark ? 0.055 : 0.035))
            .overlay(alignment: .top) {
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.black.opacity(colorScheme == .dark ? 0.30 : 0.16))
                        .frame(height: 0.5)
                    Rectangle()
                        .fill(Color.white.opacity(colorScheme == .dark ? 0.10 : 0.65))
                        .frame(height: 0.5)
                }
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.55))
                        .frame(height: 0.5)
                    Rectangle()
                        .fill(Color.black.opacity(colorScheme == .dark ? 0.32 : 0.14))
                        .frame(height: 0.5)
                }
            }
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.10),
                radius: 3,
                y: -1
            )
    }

    private func selectSpatialAudioPreset(_ preset: Int) {
        if !controller.spatialAudioEnabled {
            controller.setSpatialAudio(true)
        }
        controller.setSpatialAudioPreset(preset)
    }

    private var activeProvider: (any HeadphoneProvider)? {
        manager.activeProvider(systemAudio: systemAudio)
    }

    @ViewBuilder
    private func connectionSection(_ provider: any HeadphoneProvider) -> some View {
        Group {
            if provider.connectionState.isConnecting {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Connecting…")
                        .font(.system(size: 13))
                }
                .frame(maxWidth: .infinity)
                .padding(14)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("\(provider.vendorName) controls")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text(provider.connectionState.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if provider.providerID == controller.providerID && !controller.peripherals.isEmpty {
                        Picker("Headphones", selection: $controller.selectedPeripheralID) {
                            Text("Select headphones…").tag(nil as UUID?)
                            ForEach(controller.peripherals) { peripheral in
                                Text(peripheral.name)
                                    .tag(Optional(peripheral.id))
                            }
                        }
                        .labelsHidden()
                    }

                    if provider.providerID == controller.providerID {
                        HStack {
                            Button("Scan") { controller.startScanning() }
                            Button("Connect") { controller.connectSelected() }
                                .buttonStyle(.borderedProminent)
                                .disabled(controller.selectedPeripheralID == nil)
                        }
                    } else if provider.providerID == sony.providerID {
                        ForEach(sony.devices) { device in
                            Button("Connect \(device.name)") { sony.connect(to: device) }
                                .buttonStyle(.borderedProminent)
                        }
                        Button("Refresh paired devices") { sony.refreshDevices() }
                    }
                }
                .font(.system(size: 13))
                .padding(14)
            }
        }
    }

    private func menuSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 3)
            content()
        }
        .padding(.bottom, 8)
    }

    private func modeRow(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Group {
                    if selected {
                        Image(systemName: "checkmark")
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 18)

                Image(systemName: icon)
                    .font(.system(size: 13))
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: 14))
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
            .background(selected ? Color.accentColor.opacity(0.14) : Color.clear)
        }
        .buttonStyle(.plain)
    }

    private func toggleRow(_ title: String, icon: String, isOn: Bool, action: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .frame(width: 22)
            Text(title)
                .font(.system(size: 14))
            Spacer()
            Toggle("", isOn: Binding(get: { isOn }, set: action))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
    }

    private func actionRow(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: 14))
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack {
            Button("HeadBridge Settings…") {
                if !HeadBridgeWindowCoordinator.focusSettingsWindow() {
                    openWindow(id: "settings")
                    DispatchQueue.main.async {
                        _ = HeadBridgeWindowCoordinator.focusSettingsWindow()
                    }
                }
            }
            Spacer()
            Button("Refresh") {
                systemAudio.refresh()
                manager.refreshAll()
            }
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .font(.system(size: 13))
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct SelectionPopoverRow<Option: Identifiable & Equatable>: View {
    let title: String
    let value: String
    let icon: String
    let options: [Option]
    let selected: Option?
    let optionTitle: (Option) -> String
    let footer: String?
    let onSelect: (Option) -> Void

    @State private var isPresented = false

    init(
        _ title: String,
        value: String,
        icon: String,
        options: [Option],
        selected: Option?,
        optionTitle: @escaping (Option) -> String,
        footer: String? = nil,
        onSelect: @escaping (Option) -> Void
    ) {
        self.title = title
        self.value = value
        self.icon = icon
        self.options = options
        self.selected = selected
        self.optionTitle = optionTitle
        self.footer = footer
        self.onSelect = onSelect
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: 14))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(value)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(options) { option in
                    Button {
                        onSelect(option)
                        isPresented = false
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .semibold))
                                .opacity(selected == option ? 1 : 0)
                                .frame(width: 14)
                            Text(optionTitle(option))
                                .font(.system(size: 13))
                            Spacer(minLength: 12)
                        }
                        .contentShape(Rectangle())
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                }

                if let footer {
                    Divider().padding(.vertical, 4)
                    Text(footer)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.bottom, 4)
                }
            }
            .padding(7)
            .frame(minWidth: 210)
        }
    }
}
