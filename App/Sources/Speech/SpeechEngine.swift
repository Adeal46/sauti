import AVFoundation
import Foundation

/// Turns one sentence into mono Float32 samples. Implementations are only ever
/// called from the playback controller's serial synthesis queue.
protocol SpeechEngine: AnyObject {
    var sampleRate: Double { get }
    /// Highest speed the engine can speak at by itself. Anything faster is made up
    /// with time-stretching, which sounds less natural.
    var maxNativeSpeed: Float { get }
    func synthesize(_ text: String, voice: VoiceOption, speed: Float) -> [Float]
}

enum Accent: String, Hashable {
    case us, gb
}

enum EngineKind: Hashable {
    case kokoro(Accent)
    case apple
}

struct VoiceOption: Identifiable, Hashable {
    enum Tier: Hashable {
        case premium, standard, apple
    }

    enum Source: Hashable {
        case kokoro(sid: Int, accent: Accent)
        /// Empty identifier means "best installed English voice".
        case apple(identifier: String)
    }

    let id: String
    let name: String
    let detail: String
    let tier: Tier
    let source: Source

    var engineKind: EngineKind {
        switch source {
        case .kokoro(_, let accent): return .kokoro(accent)
        case .apple: return .apple
        }
    }
}

enum VoiceCatalog {
    static let defaultVoiceID = "kokoro:3"
    static let bestAppleVoiceID = "apple:"

    private static func k(_ sid: Int, _ name: String, _ detail: String, _ tier: VoiceOption.Tier, _ accent: Accent = .us) -> VoiceOption {
        VoiceOption(id: "kokoro:\(sid)", name: name, detail: detail, tier: tier, source: .kokoro(sid: sid, accent: accent))
    }

    /// English speakers of Kokoro v1.0. "Premium" are the voices Kokoro's authors grade highest.
    static let kokoro: [VoiceOption] = [
        k(41, "Ridge", "Deep storyteller · Wolf original", .premium),
        k(3, "Heart", "American · warm, expressive", .premium),
        k(2, "Bella", "American · bright, clear", .premium),
        k(6, "Nicole", "American · soft, close", .premium),
        k(21, "Emma", "British · calm narrator", .premium, .gb),
        k(16, "Michael", "American · steady male", .premium),
        k(14, "Fenrir", "American · deep male", .premium),
        k(18, "Puck", "American · lively male", .premium),
        k(26, "George", "British · classic male", .premium, .gb),

        k(1, "Aoede", "American · female", .standard),
        k(5, "Kore", "American · female", .standard),
        k(9, "Sarah", "American · female", .standard),
        k(0, "Alloy", "American · female", .standard),
        k(7, "Nova", "American · female", .standard),
        k(10, "Sky", "American · female", .standard),
        k(4, "Jessica", "American · female", .standard),
        k(8, "River", "American · female", .standard),
        k(11, "Adam", "American · male", .standard),
        k(12, "Echo", "American · male", .standard),
        k(13, "Eric", "American · male", .standard),
        k(15, "Liam", "American · male", .standard),
        k(17, "Onyx", "American · male", .standard),
        k(20, "Alice", "British · female", .standard, .gb),
        k(22, "Isabella", "British · female", .standard, .gb),
        k(23, "Lily", "British · female", .standard, .gb),
        k(24, "Daniel", "British · male", .standard, .gb),
        k(25, "Fable", "British · male", .standard, .gb),
        k(27, "Lewis", "British · deep narrator", .standard, .gb),
    ]

    static var premium: [VoiceOption] { kokoro.filter { $0.tier == .premium } }
    static var standard: [VoiceOption] { kokoro.filter { $0.tier == .standard } }

    /// Installed Apple voices worth listening to: Personal Voice, Premium and Enhanced.
    static func appleVoices() -> [VoiceOption] {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { voice in
            voice.language.hasPrefix("en")
                && !voice.identifier.contains("speech.synthesis")   // novelty voices
                && !voice.identifier.contains("eloquence")
        }
        let good = voices.filter { $0.voiceTraits.contains(.isPersonalVoice) || $0.quality != .default }
        let ranked = good.sorted { rank($0) > rank($1) || (rank($0) == rank($1) && $0.name < $1.name) }
        var options = ranked.map(option(for:))
        if options.isEmpty {
            options = [VoiceOption(id: bestAppleVoiceID, name: "iPhone voice", detail: "Built-in Apple voice",
                                   tier: .apple, source: .apple(identifier: ""))]
        }
        return options
    }

    static func option(for id: String) -> VoiceOption {
        if let match = kokoro.first(where: { $0.id == id }) { return match }
        if id.hasPrefix("apple:") {
            let identifier = String(id.dropFirst("apple:".count))
            if !identifier.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: identifier) {
                return option(for: voice)
            }
            return VoiceOption(id: bestAppleVoiceID, name: "iPhone voice", detail: "Built-in Apple voice",
                               tier: .apple, source: .apple(identifier: ""))
        }
        return kokoro[0]
    }

    private static func option(for voice: AVSpeechSynthesisVoice) -> VoiceOption {
        let region = voice.language.split(separator: "-").last.map(String.init) ?? voice.language
        let quality: String
        if voice.voiceTraits.contains(.isPersonalVoice) {
            quality = "Your Personal Voice"
        } else {
            switch voice.quality {
            case .premium: quality = "Apple Premium"
            case .enhanced: quality = "Apple Enhanced"
            default: quality = "Apple"
            }
        }
        return VoiceOption(id: "apple:\(voice.identifier)", name: voice.name, detail: "\(quality) · \(region)",
                           tier: .apple, source: .apple(identifier: voice.identifier))
    }

    private static func rank(_ voice: AVSpeechSynthesisVoice) -> Int {
        if voice.voiceTraits.contains(.isPersonalVoice) { return 4 }
        switch voice.quality {
        case .premium: return 3
        case .enhanced: return 2
        default: return 1
        }
    }
}
