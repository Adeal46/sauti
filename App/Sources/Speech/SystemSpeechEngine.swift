import AVFoundation

/// Apple voices (including Premium, Enhanced and Personal Voice), rendered to samples
/// so they go through the same player (speed control, highlighting) as Kokoro.
final class SystemSpeechEngine: SpeechEngine {
    let sampleRate: Double = 24_000
    let maxNativeSpeed: Float = 1.0

    private let synthesizer = AVSpeechSynthesizer()
    private let fallbackVoice: AVSpeechSynthesisVoice?

    init() {
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        let preferred = english.filter { $0.language == "en-US" || $0.language == "en-GB" }
        let pool = preferred.isEmpty ? english : preferred
        fallbackVoice = pool.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    func synthesize(_ text: String, voice option: VoiceOption, speed _: Float) -> [Float] {
        let utterance = AVSpeechUtterance(string: text)
        if case .apple(let identifier) = option.source, !identifier.isEmpty,
           let chosen = AVSpeechSynthesisVoice(identifier: identifier) {
            utterance.voice = chosen
        } else {
            utterance.voice = fallbackVoice
        }

        let lock = NSLock()
        let done = DispatchSemaphore(value: 0)
        var chunks: [AVAudioPCMBuffer] = []
        var finished = false

        // Kick off on the main queue so the callback can never target the (blocked) caller queue.
        DispatchQueue.main.async { [synthesizer] in
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                lock.lock()
                defer { lock.unlock() }
                if pcm.frameLength == 0 {
                    if !finished {
                        finished = true
                        done.signal()
                    }
                } else if let copy = AudioBufferTools.concatenate([pcm]) {
                    chunks.append(copy)
                }
            }
        }

        _ = done.wait(timeout: .now() + 60)
        lock.lock()
        let collected = chunks
        lock.unlock()

        guard let source = AudioBufferTools.concatenate(collected) else { return [] }
        return AudioBufferTools.convertToMonoFloat(source, sampleRate: sampleRate)
    }
}

enum AudioBufferTools {
    /// Joins buffers that share one format into a single buffer (also used as a deep copy).
    static func concatenate(_ buffers: [AVAudioPCMBuffer]) -> AVAudioPCMBuffer? {
        guard let first = buffers.first else { return nil }
        let format = first.format
        let total = buffers.reduce(0) { $0 + Int($1.frameLength) }
        guard total > 0,
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total))
        else { return nil }

        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        let destination = UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
        var offset = 0
        for buffer in buffers where buffer.format == format {
            let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
            let bytes = Int(buffer.frameLength) * bytesPerFrame
            for channel in 0..<min(source.count, destination.count) {
                guard let src = source[channel].mData, let dst = destination[channel].mData else { continue }
                memcpy(dst + offset * bytesPerFrame, src, bytes)
            }
            offset += Int(buffer.frameLength)
        }
        out.frameLength = AVAudioFrameCount(offset)
        return out
    }

    static func convertToMonoFloat(_ source: AVAudioPCMBuffer, sampleRate: Double) -> [Float] {
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source.format, to: target)
        else { return [] }

        let ratio = sampleRate / source.format.sampleRate
        let capacity = AVAudioFrameCount(Double(source.frameLength) * ratio) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }

        var fed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .endOfStream
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return source
        }
        guard status != .error, let channel = output.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }

    static func makeBuffer(_ samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData
        else { return nil }
        samples.withUnsafeBufferPointer { pointer in
            if let base = pointer.baseAddress {
                memcpy(channel[0], base, samples.count * MemoryLayout<Float>.size)
            }
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }
}
