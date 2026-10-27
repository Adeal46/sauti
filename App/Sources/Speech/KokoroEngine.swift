import Foundation
#if canImport(SherpaOnnx)
import SherpaOnnx
#elseif canImport(SherpaOnnxShared)
import SherpaOnnxShared
#else
#error("SherpaOnnx module not found. Check the sherpa-onnx package dependency.")
#endif

/// Kokoro-82M (int8) running on-device through sherpa-onnx.
final class KokoroEngine: SpeechEngine {
    static let modelFolderName = "KokoroModel"
    static let requiredFiles = ["model.int8.onnx", "voices.bin", "tokens.txt", "lexicon-en-us.txt"]

    private let tts: SherpaOnnxOfflineTtsWrapper
    let sampleRate: Double
    private let speakerCount: Int

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
    static func load() -> KokoroEngine? {
        guard isModelBundled, let dir = modelDirectory else { return nil }
        return KokoroEngine(directory: dir)
    }

    private init?(directory dir: URL) {
        func path(_ name: String) -> String { dir.appendingPathComponent(name).path }

        let kokoro = sherpaOnnxOfflineTtsKokoroModelConfig(
            model: path("model.int8.onnx"),
            voices: path("voices.bin"),
            tokens: path("tokens.txt"),
            lexicon: path("lexicon-en-us.txt")
        )
        let modelConfig = sherpaOnnxOfflineTtsModelConfig(kokoro: kokoro, numThreads: 4)
        var config = sherpaOnnxOfflineTtsConfig(model: modelConfig)
        let wrapper = SherpaOnnxOfflineTtsWrapper(config: &config)
        guard wrapper.tts != nil else { return nil }

        tts = wrapper
        sampleRate = Double(wrapper.sampleRate)
        speakerCount = Int(wrapper.numSpeakers)
    }

    func synthesize(_ text: String, voice: Int) -> [Float] {
        let sid = (0..<max(speakerCount, 1)).contains(voice) ? voice : 0
        let audio = tts.generate(text: text, sid: sid, speed: 1.0)
        return audio.samples
    }
}
