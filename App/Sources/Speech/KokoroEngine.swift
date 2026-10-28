import Foundation
#if canImport(SherpaOnnx)
import SherpaOnnx
#elseif canImport(SherpaOnnxShared)
import SherpaOnnxShared
#else
#error("SherpaOnnx module not found. Check the sherpa-onnx package dependency.")
#endif

/// Kokoro-82M v1.0 (full precision) running on-device through sherpa-onnx.
final class KokoroEngine: SpeechEngine {
    static let modelFolderName = "KokoroModel"
    static let modelFile = "model.onnx"
    static let requiredFiles = [modelFile, "voices.bin", "tokens.txt", "lexicon-us-en.txt", "lexicon-gb-en.txt"]

    private let tts: SherpaOnnxOfflineTtsWrapper
    private let speakerCount: Int
    let sampleRate: Double
    let maxNativeSpeed: Float = 2.0
    let accent: Accent

    static var modelDirectory: URL? {
        Bundle.main.url(forResource: modelFolderName, withExtension: nil)
    }

    static var isModelBundled: Bool {
        guard let dir = modelDirectory else { return false }
        return requiredFiles.allSatisfy {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
    }

    /// Loading takes a few seconds; call it off the main thread.
    static func load(accent: Accent) -> KokoroEngine? {
        guard isModelBundled, let dir = modelDirectory else { return nil }
        return KokoroEngine(directory: dir, accent: accent)
    }

    private init?(directory dir: URL, accent: Accent) {
        func path(_ name: String) -> String { dir.appendingPathComponent(name).path }

        // The pronunciation dictionary decides the accent (e.g. "tomato", "schedule").
        let lexicon = accent == .gb ? "lexicon-gb-en.txt" : "lexicon-us-en.txt"
        let kokoro = sherpaOnnxOfflineTtsKokoroModelConfig(
            model: path(Self.modelFile),
            voices: path("voices.bin"),
            tokens: path("tokens.txt"),
            lexicon: path(lexicon)
        )
        let modelConfig = sherpaOnnxOfflineTtsModelConfig(kokoro: kokoro, numThreads: 4)
        var config = sherpaOnnxOfflineTtsConfig(model: modelConfig)
        let wrapper = SherpaOnnxOfflineTtsWrapper(config: &config)
        guard wrapper.tts != nil else { return nil }

        tts = wrapper
        sampleRate = Double(wrapper.sampleRate)
        speakerCount = Int(wrapper.numSpeakers)
        self.accent = accent
    }

    func synthesize(_ text: String, voice: VoiceOption, speed: Float) -> [Float] {
        guard case .kokoro(let sid, _) = voice.source else { return [] }
        let speaker = (0..<max(speakerCount, 1)).contains(sid) ? sid : 0
        let audio = tts.generate(text: text, sid: speaker, speed: min(max(speed, 0.5), maxNativeSpeed))
        return audio.samples
    }
}
