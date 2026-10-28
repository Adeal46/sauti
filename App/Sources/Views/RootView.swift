import SwiftUI
import SwiftData
import UIKit
import UniformTypeIdentifiers
import VisionKit

@MainActor
final class AppRouter: ObservableObject {
    enum Tab: Hashable {
        case home, library, settings
    }

    enum AddAction: CaseIterable, Identifiable {
        case file, scan, web, text

        var id: Self { self }

        var title: String {
            switch self {
            case .file: return "Import PDF"
            case .scan: return "Scan pages"
            case .web: return "Web link"
            case .text: return "Paste text"
            }
        }

        var subtitle: String {
            switch self {
            case .file: return "PDF or text file"
            case .scan: return "Books, notes, letters"
            case .web: return "Any article"
            case .text: return "From clipboard"
            }
        }

        var symbol: String {
            switch self {
            case .file: return "doc.fill"
            case .scan: return "doc.viewfinder.fill"
            case .web: return "link"
            case .text: return "doc.on.clipboard.fill"
            }
        }
    }

    @Published var tab: Tab = .home
    @Published var homePath: [ReadingDocument] = []
    @Published var libraryPath: [ReadingDocument] = []

    @Published var showFileImporter = false
    @Published var showScanner = false
    @Published var showLinkSheet = false
    @Published var showTextSheet = false
    @Published var showClipboardCard = false
    @Published var alertMessage: String?

    func open(_ document: ReadingDocument) {
        switch tab {
        case .library:
            libraryPath.append(document)
        default:
            tab = .home
            homePath.append(document)
        }
    }

    func perform(_ action: AddAction) {
        switch action {
        case .file:
            showFileImporter = true
        case .scan:
            if VNDocumentCameraViewController.isSupported {
                showScanner = true
            } else {
                alertMessage = "Scanning needs the camera, which isn't available here."
            }
        case .web:
            showLinkSheet = true
        case .text:
            showTextSheet = true
        }
    }
}

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var importer: ImportCoordinator
    @EnvironmentObject private var player: PlaybackController
    @StateObject private var router = AppRouter()

    @AppStorage("appearance") private var appearance = "night"
    @AppStorage("dismissedPasteboardChange") private var dismissedPasteboardChange = -1

    var body: some View {
        TabView(selection: $router.tab) {
            NavigationStack(path: $router.homePath) {
                HomeView()
                    .navigationDestination(for: ReadingDocument.self) { ReaderView(document: $0) }
            }
            .tabItem { Label("Home", systemImage: "house.fill") }
            .tag(AppRouter.Tab.home)

            NavigationStack(path: $router.libraryPath) {
                LibraryView()
                    .navigationDestination(for: ReadingDocument.self) { ReaderView(document: $0) }
            }
            .tabItem { Label("Library", systemImage: "books.vertical.fill") }
            .tag(AppRouter.Tab.library)

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Settings", systemImage: "gearshape.fill") }
            .tag(AppRouter.Tab.settings)
        }
        .environmentObject(router)
        .preferredColorScheme(colorScheme)
        .fileImporter(
            isPresented: $router.showFileImporter,
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
        .fullScreenCover(isPresented: $router.showScanner) {
            DocumentScanner { images in
                router.showScanner = false
                Task { await importer.importScan(images, into: context) }
            } onCancel: {
                router.showScanner = false
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $router.showLinkSheet) {
            AddLinkSheet { url in
                Task { await importer.importWeb(url, into: context) }
            }
        }
        .sheet(isPresented: $router.showTextSheet) {
            PasteTextSheet { title, text in
                importer.importText(title: title, text: text, into: context)
            }
        }
        .overlay {
            if importer.isBusy {
                VStack(spacing: 14) {
                    Image("WolfMark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 44)
                    ProgressView()
                    Text(importer.busyMessage)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: 260)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
        }
        .alert("Something went wrong", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importer.errorMessage ?? player.errorMessage ?? router.alertMessage ?? "")
        }
        .onOpenURL { url in
            Task { await importer.importFiles([url], into: context) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshFromOutside() }
        }
        .onAppear { refreshFromOutside() }
        .onChange(of: router.showClipboardCard) { _, shown in
            if !shown { dismissedPasteboardChange = UIPasteboard.general.changeCount }
        }
    }

    private var colorScheme: ColorScheme? {
        switch appearance {
        case "day": return .light
        case "system": return nil
        default: return .dark
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { importer.errorMessage != nil || player.errorMessage != nil || router.alertMessage != nil },
            set: { shown in
                if !shown {
                    importer.errorMessage = nil
                    player.errorMessage = nil
                    router.alertMessage = nil
                }
            }
        )
    }

    private func refreshFromOutside() {
        Task { await importer.drainInbox(into: context) }
        // The share extension copies links when there's no shared container; offer to
        // paste them. Checking hasURLs doesn't trigger the paste prompt.
        let board = UIPasteboard.general
        router.showClipboardCard = board.hasURLs && board.changeCount != dismissedPasteboardChange
    }
}

/// Now-playing strip shown above the tab bar on Home and Library.
struct MiniPlayerBar: View {
    @EnvironmentObject private var player: PlaybackController
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        if let document = player.document, player.state != .idle {
            VStack(spacing: 0) {
                ProgressLine(fraction: player.segmentCount > 1
                             ? Double(player.currentIndex) / Double(player.segmentCount - 1) : 0,
                             height: 2)
                HStack(spacing: 12) {
                    Button {
                        router.open(document)
                    } label: {
                        HStack(spacing: 12) {
                            CoverView(document: document, cornerRadius: 6)
                                .frame(width: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(document.title)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Text(statusText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        player.skip(by: -1)
                    } label: {
                        Image(systemName: "gobackward")
                            .font(.body.weight(.semibold))
                            .frame(width: 34, height: 34)
                    }
                    .accessibilityLabel("Previous sentence")

                    Button {
                        player.togglePlayPause()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .frame(width: 38, height: 38)
                    }
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .background(.ultraThinMaterial)
        }
    }

    private var statusText: String {
        switch player.state {
        case .loadingVoice: return "Waking the voice…"
        case .buffering: return "Preparing audio…"
        case .paused: return "Paused"
        case .finished: return "Finished"
        default: return "\(VoiceCatalog.option(for: player.voiceID).name) · \(PlayerControls.rateLabel(player.rate))"
        }
    }
}
