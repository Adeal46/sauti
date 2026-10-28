import Foundation
import SwiftData
import UIKit

@MainActor
final class ImportCoordinator: ObservableObject {
    @Published private(set) var isBusy = false
    @Published private(set) var busyMessage = ""
    @Published var errorMessage: String?

    private let articleExtractor = ArticleExtractor()

    // MARK: Files (PDF, text, rtf)

    func importFiles(_ urls: [URL], into context: ModelContext) async {
        for url in urls {
            await importFile(url, into: context)
        }
    }

    private func importFile(_ url: URL, into context: ModelContext) async {
        begin("Reading \(url.lastPathComponent)…")
        defer { end() }

        let hasAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { url.stopAccessingSecurityScopedResource() }
            // Files shared from other apps arrive as copies in Documents/Inbox; tidy up.
            if url.path.contains("/Documents/Inbox/") { try? FileManager.default.removeItem(at: url) }
        }

        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                try DocumentLoader.load(url)
            }.value
            insert(title: loaded.title, text: loaded.text, kind: loaded.kind, source: nil, cover: loaded.cover, into: context)
        } catch {
            errorMessage = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    // MARK: Scans

    func importScan(_ images: [UIImage], into context: ModelContext) async {
        let pages = images.compactMap { $0.cgImage }
        guard !pages.isEmpty else { return }
        begin(pages.count == 1 ? "Recognizing text…" : "Recognizing text on \(pages.count) pages…")
        defer { end() }

        do {
            let text = try await Task.detached(priority: .userInitiated) {
                try pages
                    .map { TextCleaner.reflow(try OCRService.recognizeText(in: $0)) }
                    .joined(separator: "\n")
            }.value
            let title = TextCleaner.title(fromText: text) ?? "Scan, \(Date().formatted(date: .abbreviated, time: .shortened))"
            let cover = images.first.flatMap { CoverRenderer.imageCover($0) }
            insert(title: title, text: text, kind: .scan, source: nil, cover: cover, into: context)
        } catch {
            errorMessage = "Text recognition failed: \(error.localizedDescription)"
        }
    }

    // MARK: Web

    func importWeb(_ url: URL, into context: ModelContext) async {
        begin("Fetching \(url.host ?? "article")…")
        defer { end() }
        do {
            let article = try await articleExtractor.extract(from: url)
            var cover: Data?
            if let imageURL = article.imageURL {
                busyMessage = "Fetching cover…"
                cover = await CoverRenderer.downloadCover(from: imageURL)
            }
            insert(title: article.title, text: article.text, kind: .web, source: url.absoluteString, cover: cover, into: context)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Text

    func importText(title: String, text: String, into context: ModelContext) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = cleanTitle.isEmpty ? (TextCleaner.title(fromText: text) ?? "Pasted text") : cleanTitle
        insert(title: finalTitle, text: text, kind: .text, source: nil, into: context)
    }

    // MARK: Share extension inbox

    func drainInbox(into context: ModelContext) async {
        for item in SharedInbox.drain() {
            switch item.kind {
            case .url:
                if let url = URL(string: item.value) {
                    await importWeb(url, into: context)
                }
            case .text:
                importText(title: item.title ?? "", text: item.value, into: context)
            }
        }
    }

    // MARK: Helpers

    private func insert(title: String, text: String, kind: DocumentKind, source: String?, cover: Data? = nil, into context: ModelContext) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.rangeOfCharacter(from: .letters) != nil else {
            errorMessage = "No readable text was found."
            return
        }
        let document = ReadingDocument(title: title, text: trimmed, kind: kind, sourceURL: source, coverData: cover)
        context.insert(document)
        try? context.save()
    }

    private func begin(_ message: String) {
        busyMessage = message
        isBusy = true
    }

    private func end() {
        isBusy = false
    }
}
