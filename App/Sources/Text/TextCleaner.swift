import Foundation

/// PDFs and OCR return text with a hard line break at the end of every printed line.
/// `reflow` joins those lines back into paragraphs so sentences aren't cut in half.
enum TextCleaner {
    static func reflow(_ text: String) -> String {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        let typical = typicalLineLength(lines)
        var paragraphs: [String] = []
        var current = ""
        var previousLength = 0

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { paragraphs.append(trimmed) }
            current = ""
            previousLength = 0
        }

        for line in lines {
            if line.isEmpty {
                flush()
                continue
            }
            // Bare page numbers.
            if line.count <= 4, line.allSatisfy({ $0.isNumber }) {
                continue
            }
            if current.isEmpty {
                current = line
                previousLength = line.count
                continue
            }

            let endsSentence = current.last.map { ".!?:\"”’)".contains($0) } ?? false
            let wasShort = Double(previousLength) < Double(typical) * 0.75
            let wasVeryShort = Double(previousLength) < Double(typical) * 0.5
            let startsNew = line.first.map { $0.isUppercase || $0.isNumber || "•-–—\"“".contains($0) } ?? false

            if (endsSentence && wasShort && startsNew) || (wasVeryShort && startsNew && !endsSentence && previousLength < 60) {
                flush()
                current = line
            } else if current.hasSuffix("-"), let first = line.first, first.isLowercase {
                current.removeLast()
                current += line
            } else {
                current += " " + line
            }
            previousLength = line.count
        }
        flush()
        return paragraphs.joined(separator: "\n")
    }

    /// A short, readable title from the first meaningful line of text.
    static func title(fromText text: String) -> String? {
        let firstLine = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.rangeOfCharacter(from: .letters) != nil }
        guard let line = firstLine else { return nil }
        if line.count <= 70 { return line }
        let cut = line.prefix(70)
        if let space = cut.lastIndex(of: " ") {
            return String(cut[..<space]) + "…"
        }
        return String(cut) + "…"
    }

    private static func typicalLineLength(_ lines: [String]) -> Int {
        let lengths = lines.map(\.count).filter { $0 > 0 }.sorted()
        guard !lengths.isEmpty else { return 80 }
        // 80th percentile: the length of a full printed line.
        return max(lengths[min(lengths.count - 1, Int(Double(lengths.count) * 0.8))], 20)
    }
}
