import Foundation
import NaturalLanguage

/// One unit of speech, usually a sentence. `display` covers the original text exactly
/// (including trailing spaces) so a paragraph can be rebuilt from its segments.
struct Segment: Identifiable {
    let id: Int
    let paragraph: Int
    let display: String
    /// Normalized text sent to the voice. Empty when there is nothing to say.
    let speakText: String
    let wordCount: Int

    var isSpeakable: Bool { !speakText.isEmpty }
}

struct Paragraph: Identifiable {
    let id: Int
    let segmentRange: Range<Int>
}

struct ReaderContent {
    let paragraphs: [Paragraph]
    let segments: [Segment]
    /// wordPrefix[i] = words in segments 0..<i
    let wordPrefix: [Int]

    var totalWords: Int { wordPrefix.last ?? 0 }

    func wordsRemaining(from index: Int) -> Int {
        let i = min(max(index, 0), segments.count)
        return totalWords - wordPrefix[i]
    }
}

enum TextSegmenter {
    /// Longer sentences are cut at commas/semicolons so the first audio arrives quickly.
    static let maxSegmentLength = 260

    static func segment(_ text: String) -> ReaderContent {
        var paragraphs: [Paragraph] = []
        var segments: [Segment] = []
        var wordPrefix: [Int] = [0]

        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let tokenizer = NLTokenizer(unit: .sentence)

        for line in lines {
            tokenizer.string = line
            var starts: [String.Index] = []
            tokenizer.enumerateTokens(in: line.startIndex..<line.endIndex) { range, _ in
                starts.append(range.lowerBound)
                return true
            }
            if starts.first != line.startIndex {
                starts.insert(line.startIndex, at: 0)
            }

            let paragraphIndex = paragraphs.count
            let firstSegment = segments.count

            for (k, start) in starts.enumerated() {
                let end = k + 1 < starts.count ? starts[k + 1] : line.endIndex
                guard start < end else { continue }
                let sentence = String(line[start..<end])
                for piece in splitLong(sentence) {
                    let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                    let speakable = trimmed.rangeOfCharacter(from: .alphanumerics) != nil
                    let speak = speakable ? SpeechNormalizer.normalize(trimmed) : ""
                    let words = speakable ? trimmed.split(whereSeparator: { $0.isWhitespace }).count : 0
                    segments.append(Segment(
                        id: segments.count,
                        paragraph: paragraphIndex,
                        display: piece,
                        speakText: speak,
                        wordCount: words
                    ))
                    wordPrefix.append(wordPrefix[wordPrefix.count - 1] + words)
                }
            }

            if segments.count > firstSegment {
                paragraphs.append(Paragraph(id: paragraphIndex, segmentRange: firstSegment..<segments.count))
            }
        }

        return ReaderContent(paragraphs: paragraphs, segments: segments, wordPrefix: wordPrefix)
    }

    static func splitLong(_ sentence: String, limit: Int = maxSegmentLength) -> [String] {
        guard sentence.count > limit else { return [sentence] }
        let softBreaks: Set<Character> = [",", ";", ":", "—", "–", ")"]
        var parts: [String] = []
        var current = ""
        var length = 0
        var pendingBreak = false

        for ch in sentence {
            // Break *after* the whitespace that follows a soft break, so pieces end cleanly.
            if pendingBreak && !ch.isWhitespace {
                parts.append(current)
                current = ""
                length = 0
                pendingBreak = false
            }
            current.append(ch)
            length += 1
            if (length >= limit / 2 && softBreaks.contains(ch)) || (length >= limit && ch.isWhitespace) {
                pendingBreak = true
            }
        }
        if !current.isEmpty {
            if current.trimmingCharacters(in: .whitespaces).isEmpty, !parts.isEmpty {
                parts[parts.count - 1] += current
            } else {
                parts.append(current)
            }
        }
        return parts
    }
}

/// The voice model reads words from a pronunciation dictionary, so digits and a few
/// symbols are spelled out before synthesis.
enum SpeechNormalizer {
    private static let numberRegex = try! NSRegularExpression(pattern: "\\d{1,3}(?:,\\d{3})+|\\d+")

    private static let spellOut: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .spellOut
        f.locale = Locale(identifier: "en_US")
        return f
    }()

    static func normalize(_ input: String) -> String {
        var out = input
            // Typographic quotes (common in books) → plain ones the dictionary knows.
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{2026}", with: "...")
            .replacingOccurrences(of: "%", with: " percent")
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "+", with: " plus ")
            .replacingOccurrences(of: "@", with: " at ")

        let ns = out as NSString
        let matches = numberRegex.matches(in: out, range: NSRange(location: 0, length: ns.length))
        for match in matches.reversed() {
            let raw = (out as NSString).substring(with: match.range)
            let digits = raw.replacingOccurrences(of: ",", with: "")
            guard digits.count <= 12, let value = Int(digits) else { continue }
            let words: String?
            if !raw.contains(","), digits.count == 4, let year = yearWords(value) {
                words = year
            } else {
                words = spell(value)
            }
            if let words {
                out = (out as NSString).replacingCharacters(in: match.range, with: words)
            }
        }
        return out
    }

    private static func spell(_ n: Int) -> String? {
        spellOut.string(from: NSNumber(value: n))
    }

    /// 1984 -> "nineteen eighty-four", 2026 -> "twenty twenty-six", 1905 -> "nineteen oh five".
    private static func yearWords(_ n: Int) -> String? {
        guard (1100...2099).contains(n), !(2000...2009).contains(n) else { return nil }
        let high = n / 100, low = n % 100
        guard let h = spell(high) else { return nil }
        if low == 0 { return "\(h) hundred" }
        guard let l = spell(low) else { return nil }
        return low < 10 ? "\(h) oh \(l)" : "\(h) \(l)"
    }
}
