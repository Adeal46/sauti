import Foundation
import SwiftData

enum DocumentKind: String, CaseIterable {
    case pdf, scan, web, text

    var label: String {
        switch self {
        case .pdf: return "PDF"
        case .scan: return "Scan"
        case .web: return "Web"
        case .text: return "Text"
        }
    }

    var symbol: String {
        switch self {
        case .pdf: return "doc.richtext"
        case .scan: return "doc.viewfinder"
        case .web: return "safari"
        case .text: return "text.alignleft"
        }
    }
}

@Model
final class ReadingDocument {
    var id: UUID
    var title: String
    var text: String
    var kindRaw: String
    var sourceURL: String?
    var createdAt: Date
    var lastOpenedAt: Date?
    /// Index of the sentence the listener last reached.
    var progressIndex: Int
    /// Number of sentences, filled in the first time the document is opened.
    var segmentCount: Int

    init(title: String, text: String, kind: DocumentKind, sourceURL: String? = nil) {
        self.id = UUID()
        self.title = title
        self.text = text
        self.kindRaw = kind.rawValue
        self.sourceURL = sourceURL
        self.createdAt = Date()
        self.lastOpenedAt = nil
        self.progressIndex = 0
        self.segmentCount = 0
    }

    var kind: DocumentKind { DocumentKind(rawValue: kindRaw) ?? .text }

    var progressFraction: Double {
        guard segmentCount > 1 else { return 0 }
        return min(1, Double(progressIndex) / Double(segmentCount - 1))
    }
}
