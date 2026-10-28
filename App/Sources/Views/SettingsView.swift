import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var player: PlaybackController
    @AppStorage("readerFontSize") private var fontSize: Double = 19
    @AppStorage("listenerName") private var listenerName = ""
    @AppStorage("appearance") private var appearance = "night"

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image("WolfMark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Wolf Companion")
                            .font(.system(.headline, design: .serif))
                        Text("Reads to you, entirely on this iPhone")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                TextField("Your name (for the greeting)", text: $listenerName)
                    .textContentType(.givenName)
            }

            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    Text("Night").tag("night")
                    Text("Day").tag("day")
                    Text("Match iPhone").tag("system")
                }
                .pickerStyle(.segmented)
            }

            Section {
                ForEach(VoiceCatalog.neural) { voice in
                    voiceRow(voice)
                }
            } header: {
                Text("Neural voices")
            } footer: {
                Text(KokoroEngine.isModelBundled
                     ? "Kokoro voices run entirely on this iPhone. The first sentence after launch takes a few seconds while the voice wakes up."
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
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                LabeledContent("Voice engine", value: "Kokoro-82M · sherpa-onnx")
                LabeledContent("Text recognition", value: "Apple Vision")
                LabeledContent("Article extraction", value: "Mozilla Readability")
            }
        }
        .scrollContentBackground(.hidden)
        .background(ScreenBackground())
        .navigationTitle("Settings")
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
