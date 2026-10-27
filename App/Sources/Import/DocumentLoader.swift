import Foundation
import PDFKit
import UIKit
import UniformTypeIdentifiers

struct LoadedDocument {
    let title: String
    let text: String
    let kind: DocumentKind
}

enum ImportError: LocalizedError {
    case unreadable
    case noText

    var errorDescription: String? {
        switch self {
        case .unreadable: return "The file couldn't be opened."
        case .noText: return "No readable text was found."
        }
    }
}

enum DocumentLoader {
    static func load(_ url: URL) throws -> LoadedDocument {
        let type = UTType(filenameExtension: url.pathExtension.lowercased()) ?? .plainText
        let fallbackTitle = url.deletingPathExtension().lastPathComponent

        if type.conforms(to: .pdf) {
            return try loadPDF(url, fallbackTitle: fallbackTitle)
        }
        if type.conforms(to: .rtf) {
            let attributed = try NSAttributedString(
                url: url,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            )
            return LoadedDocument(title: fallbackTitle, text: attributed.string, kind: .text)
        }
        return LoadedDocument(title: fallbackTitle, text: try readPlainText(url), kind: .text)
    }

    private static func readPlainText(_ url: URL) throws -> String {
        var encoding = String.Encoding.utf8
        if let text = try? String(contentsOf: url, usedEncoding: &encoding) {
            return text
        }
        let data = try Data(contentsOf: url)
        return String(decoding: data, as: UTF8.self)
    }

    private static func loadPDF(_ url: URL, fallbackTitle: String) throws -> LoadedDocument {
        guard let pdf = PDFDocument(url: url) else { throw ImportError.unreadable }

        var pages: [String] = []
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index) else { continue }
            let embedded = page.string ?? ""
            if embedded.trimmingCharacters(in: .whitespacesAndNewlines).count >= 20 {
                pages.append(embedded)
            } else if let image = render(page) {
                // Scanned page with no text layer: read it with OCR instead.
                let recognized = (try? OCRService.recognizeText(in: image)) ?? ""
                pages.append(recognized)
            }
        }

        let text = TextCleaner.reflow(pages.joined(separator: "\n"))
        guard !text.isEmpty else { throw ImportError.noText }

        let metadataTitle = (pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (metadataTitle?.isEmpty == false ? metadataTitle : nil) ?? fallbackTitle
        return LoadedDocument(title: title, text: text, kind: .pdf)
    }

    private static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2.5
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard size.width > 0, size.height > 0 else { return nil }
        return page.thumbnail(of: size, for: .mediaBox).cgImage
    }
}
