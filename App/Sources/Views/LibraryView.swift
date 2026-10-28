import SwiftUI
import SwiftData

struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var player: PlaybackController
    @EnvironmentObject private var router: AppRouter

    @Query(sort: \ReadingDocument.createdAt, order: .reverse) private var documents: [ReadingDocument]

    @State private var search = ""
    @State private var filter: Filter = .all
    @AppStorage("librarySort") private var sortRaw = Sort.recent.rawValue
    @State private var renaming: ReadingDocument?
    @State private var renameText = ""

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", inProgress = "In progress", pdf = "PDFs", scan = "Scans", web = "Web", text = "Text", finished = "Finished"
        var id: String { rawValue }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case recent = "Recently added", opened = "Recently opened", title = "Title", progress = "Progress"
        var id: String { rawValue }
    }

    private var sort: Sort { Sort(rawValue: sortRaw) ?? .recent }

    private var visible: [ReadingDocument] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let filtered = documents.filter { document in
            if !query.isEmpty, !document.title.localizedCaseInsensitiveContains(query) { return false }
            switch filter {
            case .all: return true
            case .inProgress: return document.progressFraction > 0 && !document.isFinished
            case .pdf: return document.kind == .pdf
            case .scan: return document.kind == .scan
            case .web: return document.kind == .web
            case .text: return document.kind == .text
            case .finished: return document.isFinished
            }
        }
        switch sort {
        case .recent:
            return filtered
        case .opened:
            return filtered.sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
        case .title:
            return filtered.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .progress:
            return filtered.sorted { $0.progressFraction > $1.progressFraction }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                filterChips

                if documents.isEmpty {
                    emptyLibrary
                } else if visible.isEmpty {
                    ContentUnavailableView.search(text: search)
                        .padding(.top, 40)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)],
                              alignment: .leading, spacing: 22) {
                        ForEach(visible) { document in
                            Button {
                                router.open(document)
                            } label: {
                                LibraryCard(document: document, isPlaying: player.isActive(document) && player.isPlaying)
                            }
                            .buttonStyle(PressableStyle())
                            .contextMenu { menu(for: document) }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(ScreenBackground())
        .navigationTitle("Library")
        .searchable(text: $search, prompt: "Search your den")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort by", selection: $sortRaw) {
                        ForEach(Sort.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .accessibilityLabel("Sort")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(AppRouter.AddAction.allCases) { action in
                        Button {
                            router.perform(action)
                        } label: {
                            Label(action.title, systemImage: action.symbol)
                        }
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                }
                .accessibilityLabel("Add")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayerBar() }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Save") {
                let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let renaming, !title.isEmpty {
                    renaming.title = title
                    try? context.save()
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private var filterChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Filter.allCases) { option in
                    Button {
                        withAnimation(.snappy) { filter = option }
                    } label: {
                        Text(option.rawValue)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .foregroundStyle(filter == option ? Color.white : Color.primary)
                            .background(
                                Capsule().fill(filter == option
                                               ? AnyShapeStyle(LinearGradient(colors: [Theme.violet, Theme.violet.opacity(0.75)], startPoint: .leading, endPoint: .trailing))
                                               : AnyShapeStyle(Color.primary.opacity(0.07)))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
    }

    private var emptyLibrary: some View {
        VStack(spacing: 14) {
            Image("WolfMark")
                .resizable()
                .scaledToFit()
                .frame(width: 80)
                .opacity(0.8)
            Text("Your den is empty")
                .font(.system(.title3, design: .serif).weight(.bold))
            Text("Tap + to add a PDF, a scan, a web article or some text.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    @ViewBuilder
    private func menu(for document: ReadingDocument) -> some View {
        Button {
            player.playOrToggle(document)
        } label: {
            Label(player.isActive(document) && player.isPlaying ? "Pause" : "Play", systemImage: "play.fill")
        }
        Button {
            renameText = document.title
            renaming = document
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        Button {
            document.progressIndex = 0
            document.finishedAt = nil
            try? context.save()
        } label: {
            Label("Start over", systemImage: "arrow.counterclockwise")
        }
        if let source = document.sourceURL, let url = URL(string: source) {
            ShareLink(item: url) {
                Label("Share original link", systemImage: "square.and.arrow.up")
            }
        }
        Divider()
        Button(role: .destructive) {
            if player.document?.id == document.id { player.stop() }
            context.delete(document)
            try? context.save()
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}

private struct LibraryCard: View {
    let document: ReadingDocument
    let isPlaying: Bool
    @EnvironmentObject private var player: PlaybackController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CoverView(document: document)
                .overlay(alignment: .topLeading) {
                    Label(document.kind.label, systemImage: document.kind.symbol)
                        .font(.caption2.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(8)
                }
                .overlay(alignment: .topTrailing) {
                    if isPlaying {
                        Image(systemName: "waveform")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Theme.cyan)
                            .symbolEffect(.variableColor.iterative)
                            .padding(7)
                            .background(.ultraThinMaterial, in: Circle())
                            .padding(8)
                    } else if document.isFinished {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.callout)
                            .foregroundStyle(Theme.cyan)
                            .padding(8)
                    }
                }
                .overlay(alignment: .bottom) {
                    if document.progressFraction > 0 && !document.isFinished {
                        ProgressLine(fraction: document.progressFraction, height: 4)
                            .padding(10)
                    }
                }
            Text(document.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var subtitle: String {
        if document.isFinished { return "Finished" }
        let left = Theme.minutesLabel(document.minutesLeft(rate: player.rate))
        let percent = Int((document.progressFraction * 100).rounded())
        return percent == 0 ? "\(left) listen" : "\(percent)% · \(left) left"
    }
}
