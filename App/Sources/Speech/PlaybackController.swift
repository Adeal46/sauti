import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

/// Generates speech a few sentences ahead of the listener and plays it through
/// AVAudioEngine. Kokoro speaks faster by itself (up to 2×), which sounds natural;
/// only speeds beyond that, or Apple voices, use time-stretching.
@MainActor
final class PlaybackController: ObservableObject {
    enum State: Equatable {
        case idle, loadingVoice, buffering, playing, paused, finished
    }

    static let rates: [Float] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    @Published private(set) var state: State = .idle {
        didSet { if oldValue != state { log("state \(oldValue) → \(state)") } }
    }
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

    /// Use the Neural Engine (CoreML) for Kokoro instead of only the CPU.
    @Published var useNeuralEngine: Bool {
        didSet {
            guard oldValue != useNeuralEngine else { return }
            UserDefaults.standard.set(useNeuralEngine, forKey: Keys.neuralEngine)
            for key in engines.keys {
                if case .kokoro = key { engines[key] = nil }
            }
            if case .kokoro = activeKind { activeEngine = nil; activeKind = nil }
            generationStats = nil
            if document != nil, state != .idle, state != .finished {
                startPlayback(at: currentIndex, autoplay: isPlaying)
            }
        }
    }

    /// How many seconds of speech the voice produces per second of work (higher is better;
    /// below the playback speed means the player will have to wait).
    @Published private(set) var generationStats: Double?

    var isPlaying: Bool {
        state == .playing || state == .buffering || state == .loadingVoice
    }

    var segmentCount: Int { segments.count }

    // MARK: Private state

    private enum Keys {
        static let rate = "playbackRate"
        static let voice = "voiceKey"
        static let neuralEngine = "useNeuralEngine"
    }

    private var segments: [Segment] = []
    private let synthesisQueue = DispatchQueue(label: "sauti.synthesis", qos: .userInitiated)
    /// Keep generating until this much audio is waiting, so slow sentences don't cause gaps.
    private let bufferTargetSeconds: Double = 45
    private let maxQueuedSentences = 40
    private var queuedSeconds: [Int: Double] = [:]
    /// Where each queued sentence starts in the player's timeline (frames), for the word cursor.
    private var segmentStartFrame: [Int: AVAudioFramePosition] = [:]
    private var segmentFrameCount: [Int: AVAudioFramePosition] = [:]
    private var scheduledFrames: AVAudioFramePosition = 0
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

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
        useNeuralEngine = defaults.bool(forKey: Keys.neuralEngine)

        audioEngine.attach(playerNode)
        audioEngine.attach(timePitch)
        timePitch.overlap = 16
        applyTimePitch()

        observeAudioSession()
        observeApp()
        setUpRemoteCommands()
    }

    // MARK: Word cursor

    /// How far (0…1) the listener is through the sentence being spoken right now.
    func progressInCurrentSegment() -> Double? {
        guard state == .playing || state == .paused,
              let start = segmentStartFrame[currentIndex],
              let length = segmentFrameCount[currentIndex], length > 0,
              let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime)
        else { return nil }
        let fraction = Double(playerTime.sampleTime - start) / Double(length)
        return min(max(fraction, 0), 1)
    }

    private func resetTimeline() {
        segmentStartFrame.removeAll()
        segmentFrameCount.removeAll()
        scheduledFrames = 0
    }

    private func log(_ message: String) {
        DiagnosticsLog.shared.log(message)
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
        queuedSeconds.removeAll()
        resetTimeline()
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
        queuedSeconds.removeAll()
        resetTimeline()
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
        // Start the audio session right away so iOS keeps the app running if the
        // screen is locked while the voice is still loading.
        try? configureAudio(sampleRate: 24_000)
        beginBackgroundWork()

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
            let neural = useNeuralEngine
            log("loading Kokoro \(accent) neural=\(neural)")
            synthesisQueue.async {
                let started = CFAbsoluteTimeGetCurrent()
                let engine = KokoroEngine.load(accent: accent, useNeuralEngine: neural)
                DiagnosticsLog.shared.log(String(format: "Kokoro loaded=%@ in %.1fs", engine == nil ? "NO" : "yes", CFAbsoluteTimeGetCurrent() - started))
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
        endBackgroundWork()
        activeEngine = engine
        activeKind = kind
        generationSpeed = min(rate, engine.maxNativeSpeed)
        applyTimePitch()
        do {
            try configureAudio(sampleRate: engine.sampleRate)
        } catch {
            log("audio start failed: \(error.localizedDescription)")
            errorMessage = "Audio couldn't start: \(error.localizedDescription)"
            state = .idle
            return
        }
        playerNode.play()
        state = .buffering
        pump()
        updateNowPlaying()
    }

    /// Keeps generating ahead of the listener until `bufferTargetSeconds` of audio is queued.
    private func pump() {
        guard state != .idle, state != .finished, state != .loadingVoice,
              let engine = activeEngine, !isGenerating,
              scheduled.count < maxQueuedSentences,
              queuedSeconds.values.reduce(0, +) < bufferTargetSeconds,
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
            let started = CFAbsoluteTimeGetCurrent()
            let raw = engine.synthesize(text, voice: voice, speed: speed)
            let elapsed = CFAbsoluteTimeGetCurrent() - started
            let samples = SilenceTrimmer.tighten(raw, sampleRate: engine.sampleRate, pauseAfter: pause)
            if raw.isEmpty { DiagnosticsLog.shared.log("no audio for sentence \(index)") }
            let produced = Double(raw.count) / engine.sampleRate
            Task { @MainActor [weak self] in
                self?.record(produced: produced, elapsed: elapsed)
            }
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
            segmentStartFrame[index] = scheduledFrames
            segmentFrameCount[index] = AVAudioFramePosition(buffer.frameLength)
            scheduledFrames += AVAudioFramePosition(buffer.frameLength)
            queuedSeconds[index] = Double(samples.count) / sampleRate / Double(max(rate, 0.25))
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
        queuedSeconds[index] = nil
        segmentStartFrame[index] = nil
        segmentFrameCount[index] = nil

        if let next = scheduled.first {
            currentIndex = next
            document?.progressIndex = next
        } else if nextSpeakable(from: nextToGenerate) == nil, !isGenerating {
            finish()
            return
        } else if state == .playing {
            state = .buffering
            log("ran out of audio at sentence \(index) (voice \(String(format: "%.1f", generationStats ?? 0))× real time)")
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

    private func record(produced: Double, elapsed: Double) {
        guard produced > 0.3, elapsed > 0 else { return }
        let sample = produced / elapsed
        generationStats = generationStats.map { $0 * 0.7 + sample * 0.3 } ?? sample
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
                self.log("audio engine configuration changed")
                if self.isPlaying, self.state != .loadingVoice {
                    self.startPlayback(at: self.currentIndex, autoplay: true)
                }
            }
        })
    }

    private func observeApp() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.didEnterBackground() }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.log("foreground (state \(String(describing: self?.state)))") }
        })
        observers.append(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.didReceiveMemoryWarning() }
        })
    }

    private func didEnterBackground() {
        log("background: state \(state), engine running \(audioEngine.isRunning), queued \(scheduled.count)")
        // The GPU isn't available to apps in the background, so a Neural Engine (CoreML)
        // voice is swapped for a CPU one. The swap happens on the synthesis queue while
        // the already-buffered audio keeps playing.
        guard useNeuralEngine, case .kokoro(let accent) = activeKind, isPlaying else { return }
        let kind = EngineKind.kokoro(accent)
        log("switching voice to CPU for background")
        synthesisQueue.async {
            let engine = KokoroEngine.load(accent: accent, useNeuralEngine: false)
            Task { @MainActor [weak self] in
                guard let self, let engine, self.activeKind == kind else { return }
                self.engines[kind] = engine
                self.activeEngine = engine
                self.log("background voice ready")
                self.pump()
            }
        }
    }

    private func didReceiveMemoryWarning() {
        log("memory warning")
        for key in engines.keys where key != activeKind {
            engines[key] = nil
        }
    }

    private func beginBackgroundWork() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "LoadVoice") { [weak self] in
            Task { @MainActor in self?.endBackgroundWork() }
        }
    }

    private func endBackgroundWork() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func handleInterruption(began: Bool, shouldResume: Bool) {
        log("interruption \(began ? "began" : "ended") shouldResume=\(shouldResume)")
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
        if let cover = CoverCache.image(for: document) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: cover.size) { _ in cover }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
