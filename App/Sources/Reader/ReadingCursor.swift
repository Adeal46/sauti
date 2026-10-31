import Foundation
import PDFKit
import UIKit

/// Estimates which word is being spoken, from how far through the sentence's
/// audio playback is. Longer words take proportionally longer to say.
enum WordCursor {
    struct Word {
        let range: Range<String.Index>
        /// Letters/digits before this word in the sentence, and in the word itself.
        let alnumStart: Int
        let alnumCount: Int
    }

    static func words(in text: String) -> [Word] {
        var result: [Word] = []
        var alnumSeen = 0
        var start: String.Index?
        var startAlnum = 0
        var count = 0
        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            if ch.isWhitespace {
                if let s = start {
                    if count > 0 { result.append(Word(range: s..<index, alnumStart: startAlnum, alnumCount: count)) }
                    start = nil
                }
            } else {
                if start == nil { start = index; startAlnum = alnumSeen; count = 0 }
                let n = ch.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
                count += n
                alnumSeen += n
            }
            index = text.index(after: index)
        }
        if let s = start, count > 0 {
            result.append(Word(range: s..<text.endIndex, alnumStart: startAlnum, alnumCount: count))
        }
        return result
    }

    /// The word being spoken at `fraction` (0…1) of the sentence.
    static func word(in text: String, at fraction: Double) -> Word? {
        let all = words(in: text)
        guard let last = all.last else { return nil }
        let total = Double(last.alnumStart + last.alnumCount)
        // Leave the tail silence (pause after the sentence) on the last word.
        let target = min(max(fraction / 0.94, 0), 0.9999) * total
        return all.first { Double($0.alnumStart + $0.alnumCount) > target } ?? last
    }
}

/// Finds where each sentence of a PDF document sits on its pages, so the reader can
/// highlight the sentence (and word) being spoken on the original page.
///
/// Matching ignores everything except letters and digits, which makes it robust to
/// the line-break, hyphenation and spacing changes made when the text was prepared.
final class PDFTextMap {
    private struct Location {
        let page: Int32
        let char: Int32
    }

    private var locations: [Location] = []          // one entry per letter/digit in the PDF
    /// For each sentence, its range in `locations` (nil when it couldn't be found, e.g. OCR pages).
    private(set) var matches: [Range<Int>?] = []
    private var matchStarts: [(start: Int, segment: Int)] = []
    private let pageCount: Int

    init(pdf: PDFDocument, segments: [Segment]) {
        pageCount = pdf.pageCount
        var units: [unichar] = []
        units.reserveCapacity(200_000)

        for p in 0..<pdf.pageCount {
            guard let page = pdf.page(at: p), let string = page.string else { continue }
            let ns = string as NSString
            for i in 0..<ns.length {
                let u = ns.character(at: i)
                if Self.isAlnum(u) {
                    units.append(u)
                    locations.append(Location(page: Int32(p), char: Int32(i)))
                }
            }
        }

        let haystack = String(utf16CodeUnits: units, count: units.count) as NSString
        var cursor = 0
        matches.reserveCapacity(segments.count)
        for segment in segments {
            let needle = Self.alnum(segment.display)
            guard !needle.isEmpty, cursor < haystack.length else {
                matches.append(nil)
                continue
            }
            // Look a reasonable distance ahead; text missing from the PDF's text layer
            // (scanned pages read by OCR) is skipped instead of matching far away.
            let window = min(haystack.length - cursor, max(6_000, needle.count * 20))
            let found = haystack.range(of: needle, options: .literal, range: NSRange(location: cursor, length: window))
            if found.location != NSNotFound {
                let range = found.location..<(found.location + found.length)
                matches.append(range)
                matchStarts.append((range.lowerBound, matches.count - 1))
                cursor = range.upperBound
            } else {
                matches.append(nil)
            }
        }
    }

    // MARK: Selections

    func sentenceSelection(segment: Int, in pdf: PDFDocument) -> PDFSelection? {
        guard segment < matches.count, let range = matches[segment] else { return nil }
        return selection(for: range, in: pdf)
    }

    func wordSelection(segment: Int, word: WordCursor.Word, in pdf: PDFDocument) -> PDFSelection? {
        guard segment < matches.count, let range = matches[segment] else { return nil }
        let start = range.lowerBound + word.alnumStart
        let end = min(start + word.alnumCount, range.upperBound)
        guard start < end else { return nil }
        return selection(for: start..<end, in: pdf)
    }

    /// The sentence at a tapped spot on a page.
    func segment(atPage page: Int, char: Int) -> Int? {
        guard !matchStarts.isEmpty else { return nil }
        // First letter at or after the tapped character.
        var lo = 0, hi = locations.count
        while lo < hi {
            let mid = (lo + hi) / 2
            let l = locations[mid]
            if (Int(l.page), Int(l.char)) < (page, char) { lo = mid + 1 } else { hi = mid }
        }
        let target = min(lo, max(locations.count - 1, 0))
        // Last sentence starting at or before that letter.
        var a = 0, b = matchStarts.count
        while a < b {
            let mid = (a + b) / 2
            if matchStarts[mid].start <= target { a = mid + 1 } else { b = mid }
        }
        return a > 0 ? matchStarts[a - 1].segment : matchStarts.first?.segment
    }

    private func selection(for range: Range<Int>, in pdf: PDFDocument) -> PDFSelection? {
        guard range.lowerBound < locations.count, range.upperBound <= locations.count, !range.isEmpty else { return nil }
        let first = locations[range.lowerBound]
        let last = locations[range.upperBound - 1]
        var result: PDFSelection?
        for p in Int(first.page)...Int(last.page) {
            guard let page = pdf.page(at: p) else { continue }
            let length = (page.string as NSString?)?.length ?? 0
            let from = p == Int(first.page) ? Int(first.char) : 0
            let to = p == Int(last.page) ? Int(last.char) + 1 : length
            guard to > from, let part = page.selection(for: NSRange(location: from, length: to - from)) else { continue }
            if let existing = result { existing.add(part) } else { result = part }
        }
        return result
    }

    // MARK: Helpers

    private static func isAlnum(_ u: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(u) else { return false }   // surrogate halves
        return CharacterSet.alphanumerics.contains(scalar)
    }

    private static func alnum(_ text: String) -> String {
        let units = Array(text.utf16).filter(isAlnum)
        return String(utf16CodeUnits: units, count: units.count)
    }
}
