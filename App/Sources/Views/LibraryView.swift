import SwiftUI
import UIKit
import SwiftData
import UniformTypeIdentifiers
import VisionKit

struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var importer: ImportCoordinator
    @EnvironmentObject private var player: PlaybackController

    @Query(sort: \ReadingDocument.createdAt, order: .reverse) private var documents: [ReadingDocument]

    @State private var path: [ReadingDocument] = []
    @State private var showFileImporter = false
    @State private var showScanner = false
    @State private var showLinkSheet = false
    @State private var showTextSheet = false
    @State private var showSettings = false
    @State private var showClipboardBanner = false
    @AppStorage("dismissedPasteboardChange") private var dismissedPasteboardChange = -1

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if documents.isEmpty {
                    emptyState
                } else {
                    documentList
                }
            }
            .navigationTitle("Sauti")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        addMenuItems
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                    }
                    .accessibilityLabel("Add")
                }
            }
            .navigationDestination(for: ReadingDocument.self) { document in
                ReaderView(document: document)
            }
            .safeAreaInset(edge: .top) {
                if showClipboardBanner { clipboardBanner }
            }
            .safeAreaInset(edge: .bottom) {
                if let current = player.document, player.state != .idle {
                    MiniPlayer(title: current.title) {
                        path.append(current)
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.pdf, .plainText, .rtf, .text],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task { await importer.importFiles(urls, into: context) }
            case .failure(let error):
                importer.errorMessage = error.localizedDescription
            }
        }
        .fullScreenCover(isPresented: $showScanner) {
            DocumentScanner { images in
                showScanner = false
                Task { await importer.importScan(images, into: context) }
            } onCancel: {
                showScanner = false
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showLinkSheet) {
            AddLinkSheet { url in
                Task { await importer.importWeb(url, into: context) }
            }
        }
        .sheet(isPresented: $showTextSheet) {
            PasteTextSheet { title, text in
                importer.importText(title: title, text: text, into: context)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .overlay {
            if importer.isBusy {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(importer.busyMessage)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: 260)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            }
        }
        .alert("Something went wrong", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importer.errorMessage ?? player.errorMessage ?? "")
        }
        .onOpenURL { url in
            Task { await importer.importFiles([url], into: context) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshFromOutside() }
        }
        .onAppear { refreshFromOutside() }
    }

    // MARK: Pieces

    @ViewBuilder
    private var addMenuItems: some View {
        Button {
            showFileImporter = true
        } label: {
            Label("Import PDF or text file", systemImage: "doc")
        }
        Button {
            if VNDocumentCameraViewController.isSupported {
                showScanner = true
            } else {
                importer.errorMessage = "Scanning needs the camera, which isn't available here."
            }
        } label: {
            Label("Scan pages", systemImage: "doc.viewfinder")
        }
        Button {
            showLinkSheet = true
        } label: {
            Label("Add web article", systemImage: "safari")
        }
        Button {
            showTextSheet = true
        } label: {
            Label("Paste text", systemImage: "doc.on.clipboard")
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nothing to listen to yet", systemImage: "waveform")
        } description: {
            Text("Add a PDF, scan printed pages, or save a web article. Sauti reads it aloud entirely on your iPhone.")
        } actions: {
            Menu {
                addMenuItems
            } label: {
                Text("Add something")
                    .fontWeight(.semibold)
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var documentList: some View {
        List {
            ForEach(documents) { document in
                NavigationLink(value: document) {
                    DocumentRow(document: document, isPlaying: player.document?.id == document.id && player.isPlaying)
                }
            }
            .onDelete(perform: delete)
        }
        .listStyle(.plain)
    }

    private var clipboardBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "link")
                .foregroundStyle(.tint)
            Text("A link is on your clipboard")
                .font(.subheadline)
            Spacer(minLength: 4)
            PasteButton(payloadType: URL.self) { urls in
                DispatchQueue.main.async {
                    dismissClipboardBanner()
                    if let url = urls.first {
                        Task { await importer.importWeb(url, into: context) }
                    }
                }
            }
            .labelStyle(.titleOnly)
            .buttonBorderShape(.capsule)
            Button {
                dismissClipboardBanner()
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { importer.errorMessage != nil || player.errorMessage != nil },
            set: { shown in
                if !shown {
                    importer.errorMessage = nil
                    player.errorMessage = nil
                }
            }
        )
    }

    // MARK: Actions

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            let document = documents[index]
            if player.document?.id == document.id { player.stop() }
            context.delete(document)
        }
        try? context.save()
    }

    private func refreshFromOutside() {
        Task { await importer.drainInbox(into: context) }
        // Without an app group (some sideloading setups), the share extension copies
        // the link instead; offer to paste it. Reading hasURLs doesn't show a prompt.
        let board = UIPasteboard.general
        showClipboardBanner = !SharedInbox.isAvailable
            && board.hasURLs
            && board.changeCount != dismissedPasteboardChange
    }

    private func dismissClipboardBanner() {
        dismissedPasteboardChange = UIPasteboard.general.changeCount
        showClipboardBanner = false
    }
}

private struct DocumentRow: View {
    let document: ReadingDocument
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor.opacity(0.14))
                Image(systemName: isPlaying ? "speaker.wave.2.fill" : document.kind.symbol)
                    .foregroundStyle(.tint)
                    .symbolEffect(.variableColor.iterative, isActive: isPlaying)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(document.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(document.kind.label)
                    if document.segmentCount > 0 {
                        Text("·")
                        Text(progressLabel)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var progressLabel: String {
        let percent = Int((document.progressFraction * 100).rounded())
        return percent == 0 ? "Not started" : "\(percent)% listened"
    }
}

private struct MiniPlayer: View {
    @EnvironmentObject private var player: PlaybackController
    let title: String
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform")
                        .foregroundStyle(.tint)
                        .symbolEffect(.variableColor.iterative, isActive: player.state == .playing)
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)

            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }
}
