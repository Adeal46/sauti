import AVFoundation
import MediaPlayer
import SwiftUI

/// Generates speech a few sentences ahead of the listener and plays it through
/// AVAudioEngine. Speed changes use a time-pitch unit, so they apply instantly
/// without regenerating audio.
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
            timePitch.rate = rate
            UserDefaults.standard.set(rate, forKey: Keys.rate)
            updateNowPlaying()
        }
    }

    @Published var voiceID: Int {
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
        static let voice = "voiceID"
    }

    private var segments: [Segment] = []
    private let synthesisQueue = DispatchQueue(label: "sauti.synthesis", qos: .userInitiated)
    private let lookahead = 6

    private var generation = 0          // bumped on every seek/stop; stale work is ignored
    private var nextToGenerate = 0
    private var scheduled: [Int] = []    // segment indices queued in the player, in order
    private var isGenerating = false

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
        voiceID = defaults.object(forKey: Keys.voice) as? Int ?? VoiceCatalog.defaultVoiceID

        audioEngine.attach(playerNode)
        audioEngine.attach(timePitch)
        timePitch.rate = rate

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
        let wanted = VoiceCatalog.kind(for: voiceID)
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
            state = .paused
            updateNowPlaying()
            return
        }

        let kind = VoiceCatalog.kind(for: voiceID)
        if let engine = engines[kind] {
            begin(with: engine, kind: kind)
            return
        }

        state = .loadingVoice
        updateNowPlaying()

        switch kind {
        case .system:
            let engine = SystemSpeechEngine()
            engines[.system] = engine
            begin(with: engine, kind: .system)
        case .kokoro:
            guard !loadingKinds.contains(.kokoro) else { return }
            loadingKinds.insert(.kokoro)
            synthesisQueue.async {
                let engine = KokoroEngine.load()
                Task { @MainActor [weak self] in
                    self?.kokoroDidLoad(engine)
                }
            }
        }
    }

    private func kokoroDidLoad(_ engine: KokoroEngine?) {
        loadingKinds.remove(.kokoro)
        guard let engine else {
            errorMessage = KokoroEngine.isModelBundled
                ? "The neural voice couldn't start. Switched to the iPhone voice."
                : "The neural voice model isn't in this build. Switched to the iPhone voice."
            voiceID = VoiceCatalog.systemVoiceID
            if state == .loadingVoice { startPlayback(at: currentIndex, autoplay: true) }
            return
        }
        engines[.kokoro] = engine
        if state == .loadingVoice, VoiceCatalog.kind(for: voiceID) == .kokoro {
            begin(with: engine, kind: .kokoro)
        }
    }

    private func begin(with engine: SpeechEngine, kind: EngineKind) {
        activeEngine = engine
        activeKind = kind
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
        let voice = voiceID
        let endsParagraph = index + 1 >= segments.count || segments[index + 1].paragraph != segments[index].paragraph
        let pause = endsParagraph ? SilenceTrimmer.paragraphPause : SilenceTrimmer.sentencePause

        synthesisQueue.async {
            let raw = engine.synthesize(text, voice: voice)
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
        timePitch.rate = rate
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
