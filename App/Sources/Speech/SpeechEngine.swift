import Foundation

/// Turns one sentence into mono Float32 samples. Implementations are only ever
/// called from the playback controller's serial synthesis queue.
protocol SpeechEngine: AnyObject {
    var sampleRate: Double { get }
    func synthesize(_ text: String, voice: Int) -> [Float]
}

enum EngineKind {
    case kokoro, system
}

struct VoiceOption: Identifiable, Hashable {
    let id: Int
    let name: String
    let detail: String
}

enum VoiceCatalog {
    static let systemVoiceID = -1
    static let defaultVoiceID = 1

    /// Speaker IDs of the kokoro-en-v0_19 model (af, af_bella, af_nicole, ...).
    static let neural: [VoiceOption] = [
        VoiceOption(id: 1, name: "Bella", detail: "American · female"),
        VoiceOption(id: 3, name: "Sarah", detail: "American · female"),
        VoiceOption(id: 2, name: "Nicole", detail: "American · female, soft"),
        VoiceOption(id: 4, name: "Sky", detail: "American · female"),
        VoiceOption(id: 0, name: "Classic", detail: "American · female"),
        VoiceOption(id: 6, name: "Michael", detail: "American · male"),
        VoiceOption(id: 5, name: "Adam", detail: "American · male"),
        VoiceOption(id: 7, name: "Emma", detail: "British · female"),
        VoiceOption(id: 8, name: "Isabella", detail: "British · female"),
        VoiceOption(id: 9, name: "George", detail: "British · male"),
        VoiceOption(id: 10, name: "Lewis", detail: "British · male"),
    ]

    static let system = VoiceOption(id: systemVoiceID, name: "iPhone voice", detail: "Built-in Apple voice")

    static var all: [VoiceOption] { neural + [system] }

    static func option(for id: Int) -> VoiceOption {
        all.first { $0.id == id } ?? neural[0]
    }

    static func kind(for id: Int) -> EngineKind {
        id == systemVoiceID ? .system : .kokoro
    }
}
