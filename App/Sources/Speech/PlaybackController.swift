import AVFoundation
import MediaPlayer
import SwiftUI

/// Generates speech a few sentences ahead of the listener and plays it through
/// AVAudioEngine. Kokoro speaks faster by itself (up to 2×), which sounds natural;
/// only speeds beyond that, or Apple voices, use time-stretching.
@MainActor
final class PlaybackController: ObservableObject {
    enum State: Equatable {
        case idle, loadingVoice, buffering, playing, paused, finished
    }

    static let rates: [Float] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    @Published private(set) var state: State = .idle
    @Published private(set) var currentIndex: Int = 0
    @Published private(set) var document: ReadingDocument?
    @Published var errorMessage: String?

    @Published var rate: Float {
        didSet {
            guard oldValue != rate else { return }
            UserDefaults.standard.set(rate, forKey: Keys.rate)
            let native = min(rate, activeEngine?.maxNativeSpeed ?? 1)
            if native != generationSpeed, document != nil, state != .idle, state != .finished, state != .loadingVoice {
                // Queued audio was spoken at the old speed: regenerate from this sentence.
                startPlayback(at: currentIndex, autoplay: isPlaying)
            } else {
                applyTimePitch()
            }
            updateNowPlaying()
        }
    }

    @Published var voiceID: String {
        didSet {
            guard oldValue != voiceID else { return }
            UserDefaults.standard.set(voiceID, forKey: Keys.voice)
            // Audio already generated used the old voice: restart from the current sentence.
            if document != nil, state != .idle, state != .finished {
                startPlayback(at: currentIndex, autoplay: isPlaying)
            }
        }
    }

    var isPlaying: Bool {
        state == .playing || state == .buffering || state == .loadingVoice
    }

    var segmentCount: Int { segments.count }

    // MARK: Private state

    private enum Keys {
        static let rate = "playbackRate"
        static let voice = "voiceKey"
    }

    private var segments: [Segment] = []
    private let synthesisQueue = DispatchQueue(label: "sauti.synthesis", qos: .userInitiated)
    private let lookahead = 6

    private var generation = 0          // bumped on every seek/stop; stale work is ignored
    private var nextToGenerate = 0
    private var scheduled: [Int] = []    // segment indices queued in the player, in order
    private var isGenerating = false

    private var generationSpeed: Float = 1
    private var engines: [EngineKind: SpeechEngine] = [:]
    private var loadingKinds: Set<EngineKind> = []
    private var activeKind: EngineKind?
    private var activeEngine: SpeechEngine?

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var graphSampleRate: Double = 0
    private var resumeAfterInterruption = false
    private var observers: [NSObjectProtocol] = []

    init() {
        let defaults = UserDefaults.standard
        let savedRate = defaults.float(forKey: Keys.rate)
        rate = savedRate > 0 ? savedRate : 1.0
        voiceID = defaults.string(forKey: Keys.voice) ?? VoiceCatalog.defaultVoiceID

        audioEngine.attach(playerNode)
        audioEngine.attach(timePitch)
        timePitch.overlap = 16
        applyTimePitch()

        observeAudioSession()
        setUpRemoteCommands()
    }

    // MARK: Public controls

    func play(document: ReadingDocument, content: ReaderContent, from index: Int? = nil) {
        if self.document?.id != document.id || segments.count != content.segments.count {
            self.document = document
            segments = content.segments
        }
        document.lastOpenedAt = Date()
        let start = index ?? (document.progressIndex < content.segments.count ? document.progressIndex : 0)
        startPlayback(at: start, autoplay: true)
    }

    func isActive(_ document: ReadingDocument) -> Bool {
        self.document?.id == document.id && state != .idle
    }

    /// Play from the library without opening the reader first.
    func playOrToggle(_ document: ReadingDocument) {
        if isActive(document) {
            togglePlayPause()
            return
        }
        let text = document.text
        Task {
            let content = await Task.detached(priority: .userInitiated) {
                TextSegmenter.segment(text)
            }.value
            if document.segmentCount != content.segments.count {
                document.segmentCount = content.segments.count
            }
            guard !content.segments.isEmpty else { return }
            play(document: document, content: content)
        }
    }

    func togglePlayPause() {
        switch state {
        case .playing, .buffering, .loadingVoice:
            pause()
        case .paused:
            resume()
        case .finished:
            startPlayback(at: 0, autoplay: true)
        case .idle:
            if document != nil { startPlayback(at: currentIndex, autoplay: true) }
        }
    }

    func pause() {
        guard document != nil else { return }
        playerNode.pause()
        state = .paused
        updateNowPlaying()
    }

    func resume() {
        guard document != nil else { return }
        let wanted = VoiceCatalog.option(for: voiceID).engineKind
        guard activeKind == wanted, audioEngine.isRunning, activeEngine != nil else {
            startPlayback(at: currentIndex, autoplay: true)
            return
        }
        try? AVAudioSession.sharedInstance().setActive(true)
        playerNode.play()
        state = scheduled.isEmpty ? .buffering : .playing
        pump()
        updateNowPlaying()
    }

    func skip(by delta: Int) {
        guard document != nil, !segments.isEmpty else { return }
        var target = currentIndex + delta
        // Skip over things like page numbers that produce no speech.
        while target >= 0, target < segments.count, !segments[target].isSpeakable {
            target += delta > 0 ? 1 : -1
        }
        seek(to: min(max(target, 0), segments.count - 1))
    }

    func seek(to index: Int) {
        guard document != nil, !segments.isEmpty else { return }
        startPlayback(at: min(max(index, 0), segments.count - 1), autoplay: isPlaying)
    }

    func stop() {
        generation &+= 1
        playerNode.stop()
        scheduled.removeAll()
        document = nil
        segments = []
        currentIndex = 0
        state = .idle
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: Pipeline

    private func startPlayback(at index: Int, autoplay: Bool) {
        generation &+= 1
        playerNode.stop()
        scheduled.removeAll()
        nextToGenerate = index
        currentIndex = index
        document?.progressIndex = index

        guard autoplay else {
            if let engine = activeEngine {
                generationSpeed = min(rate, engine.maxNativeSpeed)
                applyTimePitch()
            }
            state = .paused
            updateNowPlaying()
            return
        }

        let kind = VoiceCatalog.option(for: voiceID).engineKind
        if let engine = engines[kind] {
            begin(with: engine, kind: kind)
            return
        }

        state = .loadingVoice
        updateNowPlaying()

        switch kind {
        case .apple:
            let engine = SystemSpeechEngine()
            engines[.apple] = engine
            begin(with: engine, kind: .apple)
        case .kokoro(let accent):
            guard !loadingKinds.contains(kind) else { return }
            loadingKinds.insert(kind)
            // Only one Kokoro accent stays in memory at a time (~350 MB each).
            for key in engines.keys where key != kind {
                if case .kokoro = key { engines[key] = nil }
            }
            if case .kokoro = activeKind { activeEngine = nil; activeKind = nil }
            synthesisQueue.async {
                let engine = KokoroEngine.load(accent: accent)
                Task { @MainActor [weak self] in
                    self?.kokoroDidLoad(engine, kind: kind)
                }
            }
        }
    }

    private func kokoroDidLoad(_ engine: KokoroEngine?, kind: EngineKind) {
        loadingKinds.remove(kind)
        guard let engine else {
            errorMessage = KokoroEngine.isModelBundled
                ? "The neural voice couldn't start. Switched to the iPhone voice."
                : "The neural voice model isn't in this build. Switched to the iPhone voice."
            voiceID = VoiceCatalog.bestAppleVoiceID
            if state == .loadingVoice { startPlayback(at: currentIndex, autoplay: true) }
            return
        }
        engines[kind] = engine
        if state == .loadingVoice, VoiceCatalog.option(for: voiceID).engineKind == kind {
            begin(with: engine, kind: kind)
        }
    }

    private func begin(with engine: SpeechEngine, kind: EngineKind) {
        activeEngine = engine
        activeKind = kind
        generationSpeed = min(rate, engine.maxNativeSpeed)
        applyTimePitch()
        do {
            try configureAudio(sampleRate: engine.sampleRate)
        } catch {
            errorMessage = "Audio couldn't start: \(error.localizedDescription)"
            state = .idle
            return
        }
        playerNode.play()
        state = .buffering
        pump()
        updateNowPlaying()
    }

    /// Keeps up to `lookahead` sentences generated ahead of the one playing.
    private func pump() {
        guard state != .idle, state != .finished, state != .loadingVoice,
              let engine = activeEngine, !isGenerating, scheduled.count < lookahead,
              let index = nextSpeakable(from: nextToGenerate)
        else { return }

        isGenerating = true
        let token = generation
        let text = segments[index].speakText
        let voice = VoiceCatalog.option(for: voiceID)
        let speed = generationSpeed
        let endsParagraph = index + 1 >= segments.count || segments[index + 1].paragraph != segments[index].paragraph
        let pause = endsParagraph ? SilenceTrimmer.paragraphPause : SilenceTrimmer.sentencePause

        synthesisQueue.async {
            let raw = engine.synthesize(text, voice: voice, speed: speed)
            let samples = SilenceTrimmer.tighten(raw, sampleRate: engine.sampleRate, pauseAfter: pause)
            Task { @MainActor [weak self] in
                self?.didGenerate(samples, index: index, sampleRate: engine.sampleRate, token: token)
            }
        }
    }

    private func didGenerate(_ samples: [Float], index: Int, sampleRate: Double, token: Int) {
        isGenerating = false
        guard token == generation else {
            pump()
            return
        }
        nextToGenerate = index + 1

        if let buffer = AudioBufferTools.makeBuffer(samples, sampleRate: sampleRate) {
            if scheduled.isEmpty {
                currentIndex = index
                document?.progressIndex = index
                if state == .buffering { state = .playing }
            }
            scheduled.append(index)
            playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor in
                    self?.didFinishPlaying(index, token: token)
                }
            }
            updateNowPlaying()
        } else if scheduled.isEmpty, nextSpeakable(from: nextToGenerate) == nil {
            finish()
            return
        }
        pump()
    }

    private func didFinishPlaying(_ index: Int, token: Int) {
        guard token == generation else { return }
        scheduled.removeAll { $0 == index }

        if let next = scheduled.first {
            currentIndex = next
            document?.progressIndex = next
        } else if nextSpeakable(from: nextToGenerate) == nil, !isGenerating {
            finish()
            return
        } else if state == .playing {
            state = .buffering
        }
        pump()
        updateNowPlaying()
    }

    private func finish() {
        state = .finished
        document?.finishedAt = Date()
        document?.progressIndex = 0
        updateNowPlaying()
    }

    private func nextSpeakable(from index: Int) -> Int? {
        guard index >= 0 else { return nil }
        var i = index
        while i < segments.count {
            if segments[i].isSpeakable { return i }
            i += 1
        }
        return nil
    }

    // MARK: Audio session & graph

    /// Time-stretch only what the voice couldn't do natively; bypass it entirely at 1×.
    private func applyTimePitch() {
        let ratio = rate / max(generationSpeed, 0.1)
        timePitch.rate = ratio
        timePitch.bypass = abs(ratio - 1) < 0.01
    }

    private func configureAudio(sampleRate: Double) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)

        if graphSampleRate != sampleRate {
            audioEngine.stop()
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
            audioEngine.connect(playerNode, to: timePitch, format: format)
            audioEngine.connect(timePitch, to: audioEngine.mainMixerNode, format: format)
            graphSampleRate = sampleRate
        }
        applyTimePitch()
        if !audioEngine.isRunning {
            audioEngine.prepare()
            try audioEngine.start()
        }
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default

        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume)
            Task { @MainActor in
                self?.handleInterruption(began: type == .began, shouldResume: shouldResume)
            }
        })

        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
            Task { @MainActor in
                // Headphones unplugged: pause rather than play out loud.
                if self?.isPlaying == true { self?.pause() }
            }
        })

        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.isPlaying, self.state != .loadingVoice {
                    self.startPlayback(at: self.currentIndex, autoplay: true)
                }
            }
        })
    }

    private func handleInterruption(began: Bool, shouldResume: Bool) {
        if began {
            resumeAfterInterruption = isPlaying
            if isPlaying { pause() }
        } else {
            if resumeAfterInterruption, shouldResume { resume() }
            resumeAfterInterruption = false
        }
    }

    // MARK: Lock screen

    private func setUpRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        commands.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(by: 1) }
            return .success
        }
        commands.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(by: -1) }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let document else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: document.title,
            MPMediaItemPropertyArtist: "Wolf Companion",
            MPNowPlayingInfoPropertyPlaybackRate: state == .playing ? Double(rate) : 0.0,
        ]
        if segments.count > 1 {
            info[MPNowPlayingInfoPropertyPlaybackProgress] = Double(currentIndex) / Double(segments.count - 1)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
