import Foundation

/// The voice model pads every sentence with silence at both ends, and back to back
/// those pads add up to long dead air. This trims them and adds one short,
/// consistent pause instead.
enum SilenceTrimmer {
    static let sentencePause: Double = 0.10
    static let paragraphPause: Double = 0.32

    static func tighten(_ samples: [Float], sampleRate: Double, pauseAfter: Double) -> [Float] {
        guard !samples.isEmpty, sampleRate > 0 else { return samples }

        var peak: Float = 0
        for s in samples { peak = max(peak, abs(s)) }
        guard peak > 0 else { return [] }

        // Anything quieter than ~2% of the loudest point counts as silence.
        let threshold = max(peak * 0.02, 0.0015)
        // Look at 10 ms windows so a single quiet sample inside a word doesn't count.
        let window = max(Int(sampleRate * 0.010), 1)

        func loud(_ start: Int) -> Bool {
            let end = min(start + window, samples.count)
            var sum: Float = 0
            for i in start..<end { sum += abs(samples[i]) }
            return sum / Float(end - start) > threshold
        }

        var first = 0
        while first < samples.count, !loud(first) { first += window }
        var last = samples.count - window
        while last > first, !loud(max(last, 0)) { last -= window }
        guard first < samples.count, last >= first else { return [] }

        // Keep a little air so soft consonants at the edges aren't clipped.
        let lead = Int(sampleRate * 0.025)
        let tail = Int(sampleRate * 0.060)
        let start = max(first - lead, 0)
        let end = min(last + window + tail, samples.count)

        var out = Array(samples[start..<end])
        fadeEdges(&out, sampleRate: sampleRate)
        out.append(contentsOf: repeatElement(0, count: Int(sampleRate * pauseAfter)))
        return out
    }

    /// 5 ms fades so cutting mid-waveform never clicks.
    private static func fadeEdges(_ samples: inout [Float], sampleRate: Double) {
        let n = min(Int(sampleRate * 0.005), samples.count / 2)
        guard n > 1 else { return }
        for i in 0..<n {
            let g = Float(i) / Float(n)
            samples[i] *= g
            samples[samples.count - 1 - i] *= g
        }
    }
}
