import SwiftUI

struct CustomEQEditorView: View {
    @EnvironmentObject private var provider: OppoProvider
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var bands: [OppoEQBand] = []
    @State private var editingID: UInt8?
    @State private var loaded = false
    private static let defaultFrequencies = [31, 62, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Custom Equalizer").font(.title3.weight(.semibold))
                Spacer()
                Button("Close") { dismiss() }
            }

            Form {
                Section("Preset") {
                    TextField("Name", text: $name)
                    Text("Gain range −6…+6 dB. The earbuds store up to three custom presets.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Bands") {
                    ForEach(bands.indices, id: \.self) { index in
                        HStack(spacing: 10) {
                            Text(Self.frequencyLabel(bands[index].frequency))
                                .frame(width: 42, alignment: .leading)
                                .font(.caption.monospaced())
                            Slider(
                                value: Binding(
                                    get: { Double(bands[index].gain) },
                                    set: { value in
                                        guard bands.indices.contains(index) else { return }
                                        bands[index] = OppoEQBand(
                                            frequency: bands[index].frequency,
                                            gain: Int(value.rounded())
                                        )
                                    }
                                ),
                                in: -6...6,
                                step: 1
                            )
                            Text(Self.gainLabel(bands[index].gain))
                                .frame(width: 34, alignment: .trailing)
                                .font(.caption.monospaced())
                        }
                    }
                }

                Section {
                    if let editingID {
                        Button("Update “\(name)”") {
                            provider.updateCustomEQ(id: editingID, name: name, bands: bands)
                            dismiss()
                        }
                        Button("Delete this preset", role: .destructive) {
                            provider.deleteCustomEQ(id: editingID)
                            dismiss()
                        }
                    }
                    Button("Save as new preset") {
                        provider.createCustomEQ(name: name, bands: bands)
                        dismiss()
                    }
                }
            }
            .formStyle(.grouped)
        }
        .padding(16)
        .frame(width: 520, height: 660)
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true

        let current =
            provider.customEQPresets.first(where: { $0.id == provider.eqCurrentID })
            ?? provider.customEQPresets.first

        if let current, current.bands.count == Self.defaultFrequencies.count {
            name = current.name
            bands = current.bands
            editingID = current.id
        } else {
            name = "Custom"
            bands = Self.defaultFrequencies.map { OppoEQBand(frequency: $0, gain: 0) }
            editingID = nil
        }
    }

    private static func frequencyLabel(_ hz: Int) -> String {
        hz >= 1_000 ? "\(hz / 1_000)k" : "\(hz)"
    }

    private static func gainLabel(_ gain: Int) -> String {
        gain > 0 ? "+\(gain)" : "\(gain)"
    }
}
