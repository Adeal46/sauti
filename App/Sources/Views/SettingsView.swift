import AVFoundation
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var player: PlaybackController
    @AppStorage("readerFontSize") private var fontSize: Double = 19
    @AppStorage("listenerName") private var listenerName = ""
    @AppStorage("appearance") private var appearance = "night"
    @State private var appleVoices: [VoiceOption] = VoiceCatalog.appleVoices()
    @State private var personalVoiceStatus = AVSpeechSynthesizer.personalVoiceAuthorizationStatus

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
                ForEach(VoiceCatalog.premium) { voice in
                    voiceRow(voice)
                }
            } header: {
                Text("Premium voices")
            } footer: {
                Text(KokoroEngine.isModelBundled
                     ? "Full-quality Kokoro voices, generated entirely on this iPhone. The first sentence takes a few seconds while the voice wakes up."
                     : "The voice model isn't included in this build, so an iPhone voice is used instead.")
            }

            Section {
                DisclosureGroup("More voices (\(VoiceCatalog.standard.count))") {
                    ForEach(VoiceCatalog.standard) { voice in
                        voiceRow(voice)
                    }
                }
            }

            Section {
                ForEach(appleVoices) { voice in
                    voiceRow(voice)
                }
                if personalVoiceStatus != .authorized {
                    Button {
                        AVSpeechSynthesizer.requestPersonalVoiceAuthorization { status in
                            DispatchQueue.main.async {
                                personalVoiceStatus = status
                                appleVoices = VoiceCatalog.appleVoices()
                            }
                        }
                    } label: {
                        Label("Use my Personal Voice", systemImage: "person.crop.circle.badge.checkmark")
                    }
                }
            } header: {
                Text("iPhone voices")
            } footer: {
                Text("For Apple's best voices, open iPhone Settings → Accessibility → Spoken Content → Voices → English and download a \"Premium\" voice (for example Ava, Zoe or Evan). To read in your own voice, set up Personal Voice under Accessibility first. New voices appear here automatically.")
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
                LabeledContent("Voice engine", value: "Kokoro-82M v1.0 · sherpa-onnx")
                LabeledContent("Text recognition", value: "Apple Vision")
                LabeledContent("Article extraction", value: "Mozilla Readability")
            }
        }
        .scrollContentBackground(.hidden)
        .background(ScreenBackground())
        .navigationTitle("Settings")
        .onAppear { appleVoices = VoiceCatalog.appleVoices() }
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
