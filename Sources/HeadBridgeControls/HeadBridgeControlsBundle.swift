import SwiftUI
import WidgetKit

@main
struct HeadBridgeControlsBundle: WidgetBundle {
    var body: some Widget {
        NoiseControlWidget()
        StickyInputWidget()
    }
}

struct NoiseControlProvider: ControlValueProvider {
    var previewValue: Int { 1 }

    func currentValue() async throws -> Int {
        HeadBridgeControlStateStore.noiseMode
    }
}

struct NoiseControlWidget: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: HeadBridgeControlConstants.noiseControlKind,
            provider: NoiseControlProvider()
        ) { mode in
            ControlWidgetButton(action: CycleNoiseControlIntent()) {
                Label(Self.title(for: mode), systemImage: Self.icon(for: mode))
                    .controlWidgetStatus(Self.title(for: mode))
            }
        }
        .displayName("Headphones Noise Control")
        .description("Cycle through the active headphones’ noise-control modes.")
    }

    private static func title(for mode: Int) -> String {
        switch mode {
        case 1: "Noise Cancellation"
        case 2: "Pass-Through"
        case 3: "Wind Reduction"
        default: "Noise Control Off"
        }
    }

    private static func icon(for mode: Int) -> String {
        switch mode {
        case 1: "waveform.badge.minus"
        case 2: "ear"
        case 3: "wind"
        default: "person.fill"
        }
    }
}

struct StickyInputProvider: ControlValueProvider {
    var previewValue: Bool { true }

    func currentValue() async throws -> Bool {
        HeadBridgeControlStateStore.stickyInputEnabled
    }
}

struct StickyInputWidget: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: HeadBridgeControlConstants.stickyInputKind,
            provider: StickyInputProvider()
        ) { isEnabled in
            ControlWidgetToggle(
                isOn: isEnabled,
                action: SetStickyInputControlIntent()
            ) {
                Label("Sticky Input", systemImage: "pin.fill")
            }
        }
        .displayName("HeadBridge Sticky Input")
        .description("Prevent macOS from automatically changing the microphone.")
    }
}
