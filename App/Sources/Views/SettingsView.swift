import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var player: PlaybackController
    @Environment(\.dismiss) private var dismiss
    @AppStorage("readerFontSize") private var fontSize: Double = 19

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(VoiceCatalog.neural) { voice in
                        voiceRow(voice)
                    }
                } header: {
                    Text("Neural voices")
                } footer: {
                    Text(KokoroEngine.isModelBundled
                         ? "Kokoro voices run entirely on this iPhone. The first sentence after launch takes a few seconds while the voice loads."
                         : "The neural voice model isn't included in this build, so the iPhone voice is used instead.")
                }

                Section("Other") {
                    voiceRow(VoiceCatalog.system)
                }

                Section("Reading") {
                    Picker("Default speed", selection: $player.rate) {
                        ForEach(PlaybackController.rates, id: \.self) { rate in
                            Text(PlayerControls.rateLabel(rate)).tag(rate)
                        }
                    }
                    VStack(alignment: .leading) {
                        Text("Text size")
                        Slider(value: $fontSize, in: 14...30, step: 1) {
                            Text("Text size")
                        } minimumValueLabel: {
                            Image(systemName: "textformat.size.smaller")
                        } maximumValueLabel: {
                            Image(systemName: "textformat.size.larger")
                        }
                    }
                }

                Section("About") {
                    LabeledContent("Voice engine", value: "Kokoro-82M · sherpa-onnx")
                    LabeledContent("Text recognition", value: "Apple Vision")
                    LabeledContent("Article extraction", value: "Mozilla Readability")
                    Text("Everything is processed on-device. Web articles are downloaded once when you add them.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func voiceRow(_ voice: VoiceOption) -> some View {
        Button {
            player.voiceID = voice.id
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(voice.name).foregroundStyle(.primary)
                    Text(voice.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if player.voiceID == voice.id {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
        }
    }
}
