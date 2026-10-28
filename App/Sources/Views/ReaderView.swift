import SwiftUI

struct ReaderView: View {
    let document: ReadingDocument
    @EnvironmentObject private var player: PlaybackController
    @AppStorage("readerFontSize") private var fontSize: Double = 19
    @State private var content: ReaderContent?

    private var isActive: Bool { player.document?.id == document.id }
    private var highlightedIndex: Int? { isActive && player.state != .idle ? player.currentIndex : nil }

    var body: some View {
        Group {
            if let content {
                if content.segments.isEmpty {
                    ContentUnavailableView("No readable text", systemImage: "text.badge.xmark",
                                           description: Text("This document doesn't contain text Wolf Companion can read."))
                } else {
                    reader(content)
                        .safeAreaInset(edge: .bottom) {
                            PlayerControls(document: document, content: content)
                        }
                }
            } else {
                ProgressView("Preparing…")
            }
        }
        .background(ScreenBackground())
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        fontSize = min(fontSize + 2, 30)
                    } label: {
                        Label("Larger text", systemImage: "textformat.size.larger")
                    }
                    Button {
                        fontSize = max(fontSize - 2, 14)
                    } label: {
                        Label("Smaller text", systemImage: "textformat.size.smaller")
                    }
                    if let source = document.sourceURL, let url = URL(string: source) {
                        Link(destination: url) {
                            Label("Open original page", systemImage: "safari")
                        }
                    }
                } label: {
                    Image(systemName: "textformat.size")
                }
            }
        }
        .task(id: document.id) {
            await prepare()
        }
    }

    private func prepare() async {
        let text = document.text
        let prepared = await Task.detached(priority: .userInitiated) {
            TextSegmenter.segment(text)
        }.value
        if document.segmentCount != prepared.segments.count {
            document.segmentCount = prepared.segments.count
        }
        document.lastOpenedAt = Date()
        content = prepared
    }

    private func reader(_ content: ReaderContent) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    header
                    ForEach(content.paragraphs) { paragraph in
                        Text(attributed(paragraph, in: content))
                            .font(.system(size: fontSize, design: .serif))
                            .lineSpacing(fontSize * 0.3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                player.play(document: document, content: content, from: paragraph.segmentRange.lowerBound)
                            }
                            .id(paragraph.id)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
            }
            .onAppear {
                let start = isActive ? player.currentIndex : document.progressIndex
                if start > 0, start < content.segments.count {
                    proxy.scrollTo(content.segments[start].paragraph, anchor: UnitPoint(x: 0.5, y: 0.25))
                }
            }
            .onChange(of: highlightedIndex) { _, index in
                guard let index, index < content.segments.count else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(content.segments[index].paragraph, anchor: UnitPoint(x: 0.5, y: 0.3))
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            CoverView(document: document, cornerRadius: 8)
                .frame(width: 64)
            VStack(alignment: .leading, spacing: 6) {
                Text(document.title)
                    .font(.system(.title3, design: .serif).weight(.bold))
                    .lineLimit(3)
                Text("\(document.kind.label) · \(Theme.minutesLabel(document.estimatedWords / (Theme.wordsPerMinute * Double(player.rate)))) listen")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 10)
    }

    private func attributed(_ paragraph: Paragraph, in content: ReaderContent) -> AttributedString {
        var result = AttributedString()
        let active = highlightedIndex
        for i in paragraph.segmentRange {
            var piece = AttributedString(content.segments[i].display)
            if let active {
                // Explicit Color values keep these on SwiftUI's attributes (not UIKit's).
                if i == active {
                    piece.backgroundColor = Color.accentColor.opacity(0.28)
                } else if i < active {
                    piece.foregroundColor = Color.secondary
                }
            }
            result.append(piece)
        }
        return result
    }
}

struct PlayerControls: View {
    let document: ReadingDocument
    let content: ReaderContent
    @EnvironmentObject private var player: PlaybackController
    @State private var scrubValue: Double?

    private var isActive: Bool { player.document?.id == document.id }
    private var position: Int { isActive ? player.currentIndex : min(document.progressIndex, content.segments.count - 1) }
    private var isPlaying: Bool { isActive && player.isPlaying }
    private var lastIndex: Double { Double(max(content.segments.count - 1, 1)) }

    var body: some View {
        VStack(spacing: 12) {
            Slider(
                value: Binding(get: { scrubValue ?? Double(position) }, set: { scrubValue = $0 }),
                in: 0...lastIndex,
                onEditingChanged: { editing in
                    guard !editing, let value = scrubValue else { return }
                    seek(to: Int(value.rounded()))
                    scrubValue = nil
                }
            )

            HStack {
                Text(statusText)
                Spacer()
                Text(timeLeftText)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            HStack {
                voiceMenu
                Spacer()
                Button {
                    skip(-1)
                } label: {
                    Image(systemName: "backward.fill").font(.title3)
                }
                .accessibilityLabel("Previous sentence")
                Spacer()
                Button {
                    if isActive {
                        player.togglePlayPause()
                    } else {
                        player.play(document: document, content: content)
                    }
                } label: {
                    ZStack {
                        Circle().fill(Color.accentColor)
                        if isActive && (player.state == .loadingVoice || player.state == .buffering) {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.title2)
                                .foregroundStyle(.white)
                                .offset(x: isPlaying ? 0 : 2)
                        }
                    }
                    .frame(width: 62, height: 62)
                }
                .accessibilityLabel(isPlaying ? "Pause" : "Play")
                Spacer()
                Button {
                    skip(1)
                } label: {
                    Image(systemName: "forward.fill").font(.title3)
                }
                .accessibilityLabel("Next sentence")
                Spacer()
                speedMenu
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private var voiceMenu: some View {
        Menu {
            Picker("Voice", selection: $player.voiceID) {
                Section("Premium") {
                    ForEach(VoiceCatalog.premium) { voice in
                        voiceLabel(voice).tag(voice.id)
                    }
                }
                Section("iPhone voices") {
                    ForEach(VoiceCatalog.appleVoices()) { voice in
                        voiceLabel(voice).tag(voice.id)
                    }
                }
            }
            Menu("More voices") {
                Picker("More voices", selection: $player.voiceID) {
                    ForEach(VoiceCatalog.standard) { voice in
                        voiceLabel(voice).tag(voice.id)
                    }
                }
            }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: "person.wave.2.fill").font(.body)
                Text(VoiceCatalog.option(for: player.voiceID).name)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .frame(width: 64)
        }
    }

    private func voiceLabel(_ voice: VoiceOption) -> some View {
        VStack(alignment: .leading) {
            Text(voice.name)
            Text(voice.detail)
        }
    }

    private var speedMenu: some View {
        Menu {
            Picker("Speed", selection: $player.rate) {
                ForEach(PlaybackController.rates, id: \.self) { rate in
                    Text(Self.rateLabel(rate)).tag(rate)
                }
            }
        } label: {
            Text(Self.rateLabel(player.rate))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .frame(width: 64, height: 32)
                .background(Color.accentColor.opacity(0.14), in: Capsule())
        }
    }

    private var statusText: String {
        if isActive {
            switch player.state {
            case .loadingVoice: return "Loading voice…"
            case .buffering:
                if let stats = player.generationStats, stats < Double(player.rate) {
                    return "Voice catching up…"
                }
                return "Preparing audio…"
            case .finished: return "Finished"
            default: break
            }
        }
        return "Sentence \(position + 1) of \(content.segments.count)"
    }

    private var timeLeftText: String {
        let words = content.wordsRemaining(from: position)
        let rate = Double(player.rate)
        let minutes = Double(words) / (165.0 * rate)
        if minutes < 1 { return "under a minute left" }
        if minutes < 60 { return "\(Int(minutes.rounded())) min left" }
        let hours = Int(minutes / 60)
        let mins = Int(minutes) % 60
        return "\(hours) h \(mins) min left"
    }

    private func skip(_ delta: Int) {
        if isActive {
            player.skip(by: delta)
        } else {
            seek(to: position + delta)
        }
    }

    private func seek(to index: Int) {
        let clamped = min(max(index, 0), content.segments.count - 1)
        if isActive {
            player.seek(to: clamped)
        } else {
            document.progressIndex = clamped
        }
    }

    static func rateLabel(_ rate: Float) -> String {
        var text = String(format: "%.2f", rate)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text + "×"
    }
}
