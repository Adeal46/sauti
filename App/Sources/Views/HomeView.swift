import SwiftUI
import SwiftData

struct HomeView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var player: PlaybackController
    @EnvironmentObject private var importer: ImportCoordinator
    @EnvironmentObject private var router: AppRouter
    @AppStorage("listenerName") private var listenerName = ""

    @Query(sort: \ReadingDocument.createdAt, order: .reverse) private var documents: [ReadingDocument]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header

                if router.showClipboardCard {
                    clipboardCard
                }

                if let current = continueDocument {
                    ContinueCard(document: current)
                } else {
                    WelcomeCard()
                }

                quickAdd

                if !documents.isEmpty {
                    recentShelf
                    statsStrip
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(ScreenBackground())
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayerBar() }
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("WOLF COMPANION")
                    .font(.caption.weight(.bold))
                    .tracking(2)
                    .foregroundStyle(Theme.lilac)
                Text(Theme.greeting(name: listenerName))
                    .font(.system(.largeTitle, design: .serif).weight(.bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
            Spacer()
            Image("WolfMark")
                .resizable()
                .scaledToFit()
                .frame(width: 46, height: 46)
                .padding(8)
                .background(Circle().fill(Theme.violet.opacity(0.16)))
                .overlay(Circle().strokeBorder(Theme.violet.opacity(0.35), lineWidth: 1))
        }
        .padding(.top, 12)
    }

    private var clipboardCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "link")
                .font(.headline)
                .foregroundStyle(Theme.cyan)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Theme.cyan.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text("Link on your clipboard")
                    .font(.subheadline.weight(.semibold))
                Text("Turn it into a listen")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            PasteButton(payloadType: URL.self) { urls in
                DispatchQueue.main.async {
                    router.showClipboardCard = false
                    if let url = urls.first {
                        Task { await importer.importWeb(url, into: context) }
                    }
                }
            }
            .labelStyle(.titleOnly)
            .buttonBorderShape(.capsule)
            Button {
                router.showClipboardCard = false
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(14)
        .background(cardBackground)
    }

    private var quickAdd: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Bring something to the den")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(AppRouter.AddAction.allCases) { action in
                    Button {
                        router.perform(action)
                    } label: {
                        QuickAddTile(action: action)
                    }
                    .buttonStyle(PressableStyle())
                }
            }
        }
    }

    private var recentShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle("Recently added")
                Spacer()
                Button("See all") { router.tab = .library }
                    .font(.subheadline.weight(.semibold))
            }
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(documents.prefix(12)) { document in
                        Button {
                            router.open(document)
                        } label: {
                            ShelfItem(document: document)
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }

    private var statsStrip: some View {
        let finished = documents.filter(\.isFinished).count
        let minutes = documents.reduce(0) { $0 + $1.minutesLeft(rate: 1) }
        return HStack(spacing: 10) {
            StatPill(value: "\(documents.count)", label: "in your den", symbol: "books.vertical.fill")
            StatPill(value: Theme.minutesLabel(minutes), label: "to listen", symbol: "headphones")
            StatPill(value: "\(finished)", label: "finished", symbol: "checkmark.seal.fill")
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(Color.primary.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }

    /// The document playing now, otherwise the most recently opened unfinished one.
    private var continueDocument: ReadingDocument? {
        if let active = player.document, player.state != .idle { return active }
        return documents
            .filter { $0.lastOpenedAt != nil && !$0.isFinished }
            .max { ($0.lastOpenedAt ?? .distantPast) < ($1.lastOpenedAt ?? .distantPast) }
            ?? documents.first { !$0.isFinished }
    }
}

// MARK: Components

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.title3.weight(.bold))
    }
}

private struct ContinueCard: View {
    let document: ReadingDocument
    @EnvironmentObject private var player: PlaybackController
    @EnvironmentObject private var router: AppRouter

    private var isActive: Bool { player.isActive(document) }
    private var isPlaying: Bool { isActive && player.isPlaying }
    private var fraction: Double {
        if isActive, player.segmentCount > 1 {
            return Double(player.currentIndex) / Double(player.segmentCount - 1)
        }
        return document.progressFraction
    }

    var body: some View {
        Button {
            router.open(document)
        } label: {
            HStack(alignment: .center, spacing: 16) {
                CoverView(document: document, cornerRadius: 10)
                    .frame(width: 96)
                VStack(alignment: .leading, spacing: 8) {
                    Text(isActive ? "NOW LISTENING" : (document.progressFraction > 0 ? "PICK UP WHERE YOU LEFT OFF" : "READY WHEN YOU ARE"))
                        .font(.caption2.weight(.bold))
                        .tracking(1.2)
                        .foregroundStyle(Theme.cyan)
                    Text(document.title)
                        .font(.system(.headline, design: .serif))
                        .foregroundStyle(.white)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    ProgressLine(fraction: fraction)
                    Text("\(Theme.minutesLabel(document.minutesLeft(rate: player.rate))) left")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .padding(.trailing, 56)
            .frame(minHeight: 160)
            .background(heroBackground)
        }
        .buttonStyle(PressableStyle())
        // Kept outside the card's button so the two taps don't fight.
        .overlay(alignment: .bottomTrailing) {
                Button {
                    player.playOrToggle(document)
                } label: {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(colors: [Theme.violet, Theme.cyan.opacity(0.9)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        if isActive && (player.state == .loadingVoice || player.state == .buffering) {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.title2)
                                .foregroundStyle(.white)
                                .offset(x: isPlaying ? 0 : 2)
                        }
                    }
                    .frame(width: 58, height: 58)
                    .shadow(color: Theme.violet.opacity(0.6), radius: 12, y: 4)
                }
                .accessibilityLabel(isPlaying ? "Pause" : "Play")
                .padding(16)
        }
    }

    private var heroBackground: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.20, green: 0.12, blue: 0.48), Theme.night],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image("WolfMark")
                .resizable()
                .scaledToFit()
                .frame(width: 190)
                .opacity(0.08)
                .offset(x: 110, y: -20)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Theme.lilac.opacity(0.25), lineWidth: 1)
        )
    }
}

private struct WelcomeCard: View {
    var body: some View {
        HStack(spacing: 18) {
            Image("WolfMark")
                .resizable()
                .scaledToFit()
                .frame(width: 74)
            VStack(alignment: .leading, spacing: 6) {
                Text("Your reading companion")
                    .font(.system(.title3, design: .serif).weight(.bold))
                    .foregroundStyle(.white)
                Text("Give it a PDF, a page from a book, or an article. It reads to you, entirely on this iPhone.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .padding(20)
        .background(
            LinearGradient(colors: [Color(red: 0.20, green: 0.12, blue: 0.48), Theme.night],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Theme.lilac.opacity(0.25), lineWidth: 1)
        )
    }
}

private struct QuickAddTile: View {
    let action: AppRouter.AddAction

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: action.symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.cyan)
                .frame(width: 42, height: 42)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(colors: [Theme.violet.opacity(0.45), Theme.violet.opacity(0.15)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(action.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct ShelfItem: View {
    let document: ReadingDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CoverView(document: document, cornerRadius: 10)
                .frame(width: 120)
                .overlay(alignment: .bottom) {
                    if document.progressFraction > 0 && !document.isFinished {
                        ProgressLine(fraction: document.progressFraction, height: 3)
                            .padding(8)
                    }
                }
            Text(document.title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: 120, alignment: .leading)
            Text(document.statusLine)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct StatPill: View {
    let value: String
    let label: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(Theme.lilac)
            Text(value)
                .font(.headline.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
