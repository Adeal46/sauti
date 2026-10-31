import PDFKit
import SwiftUI
import UIKit

/// Shows the original PDF pages and moves a reading cursor over them: the spoken
/// sentence gets a soft highlight and the current word a stronger one.
struct PDFPageReader: UIViewRepresentable {
    let pdf: PDFDocument
    let map: PDFTextMap
    let content: ReaderContent
    let documentID: UUID
    @ObservedObject var player: PlaybackController
    let onTapSegment: (Int) -> Void
    var startSegment: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = true
        view.pageShadowsEnabled = true
        view.backgroundColor = UIColor(red: 0.08, green: 0.07, blue: 0.13, alpha: 1)
        view.document = pdf

        let coordinator = context.coordinator
        coordinator.pdfView = view

        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = coordinator
        view.addGestureRecognizer(tap)

        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleUserScroll(_:)))
        pan.cancelsTouchesInView = false
        pan.delegate = coordinator
        view.addGestureRecognizer(pan)

        coordinator.start()
        let start = startSegment
        DispatchQueue.main.async {
            MainActor.assumeIsolated { coordinator.scroll(toSegment: start, animated: false) }
        }
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.refresh()
    }

    static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PDFPageReader
        weak var pdfView: PDFView?
        private var timer: Timer?
        private var lastSegment: Int?
        private var lastWordStart: Int?
        private var lastUserScroll = Date.distantPast

        private let sentenceColor = UIColor(red: 0.49, green: 0.36, blue: 0.96, alpha: 0.22)
        private let wordColor = UIColor(red: 0.49, green: 0.36, blue: 0.96, alpha: 0.55)

        init(_ parent: PDFPageReader) {
            self.parent = parent
        }

        func start() {
            timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
                self?.refresh()
            }
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }

        @MainActor
        private var isActive: Bool {
            parent.player.document?.id == parent.documentID && parent.player.state != .idle
        }

        func refresh() {
            MainActor.assumeIsolated { refreshOnMain() }
        }

        @MainActor
        private func refreshOnMain() {
            guard let view = pdfView else { return }
            guard isActive, parent.player.state != .finished else {
                if lastSegment != nil {
                    view.highlightedSelections = nil
                    lastSegment = nil
                    lastWordStart = nil
                }
                return
            }

            let segment = parent.player.currentIndex
            guard segment < parent.content.segments.count else { return }
            let text = parent.content.segments[segment].display

            var word: WordCursor.Word?
            if let fraction = parent.player.progressInCurrentSegment() {
                word = WordCursor.word(in: text, at: fraction)
            }
            guard segment != lastSegment || word?.alnumStart != lastWordStart else { return }

            var selections: [PDFSelection] = []
            if let sentence = parent.map.sentenceSelection(segment: segment, in: parent.pdf) {
                sentence.color = sentenceColor
                selections.append(sentence)
            }
            if let word, let wordSelection = parent.map.wordSelection(segment: segment, word: word, in: parent.pdf) {
                wordSelection.color = wordColor
                selections.append(wordSelection)
            }
            view.highlightedSelections = selections.isEmpty ? nil : selections

            if segment != lastSegment {
                lastSegment = segment
                // Follow along unless the listener has just scrolled away to look around.
                if Date().timeIntervalSince(lastUserScroll) > 6 {
                    scroll(toSegment: segment, animated: true)
                }
            }
            lastWordStart = word?.alnumStart
        }

        @MainActor
        func scroll(toSegment segment: Int, animated: Bool) {
            guard let view = pdfView,
                  let selection = parent.map.sentenceSelection(segment: segment, in: parent.pdf),
                  let page = selection.pages.first
            else { return }
            let bounds = selection.bounds(for: page)
            let onScreen = view.convert(bounds, from: page)
            let comfortable = view.bounds.inset(by: UIEdgeInsets(top: 80, left: 0, bottom: 220, right: 0))
            if comfortable.contains(onScreen) { return }
            // Put the sentence about a third of the way down the screen.
            var target = bounds
            target.origin.y += view.bounds.height * 0.3 / max(view.scaleFactor, 0.01)
            if animated {
                UIView.animate(withDuration: 0.3) { view.go(to: target, on: page) }
            } else {
                view.go(to: target, on: page)
            }
        }

        @objc func handleUserScroll(_ gesture: UIPanGestureRecognizer) {
            lastUserScroll = Date()
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            MainActor.assumeIsolated {
                guard let view = pdfView else { return }
                let location = gesture.location(in: view)
                guard let page = view.page(for: location, nearest: true),
                      let pageIndex = view.document?.index(for: page)
                else { return }
                let point = view.convert(location, to: page)
                let char = page.characterIndex(at: point)
                guard char >= 0, char != NSNotFound,
                      let segment = parent.map.segment(atPage: pageIndex, char: char)
                else { return }
                lastUserScroll = .distantPast
                parent.onTapSegment(segment)
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
