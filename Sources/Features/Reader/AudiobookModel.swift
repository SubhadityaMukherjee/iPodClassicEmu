import AVFoundation
import Foundation
import Observation
import OSLog

/// One speakable unit: the text on a single page of a chapter, in reading
/// order. The page index drives the real page turns, so audiobook playback
/// and normal reading always agree on position.
struct AudiobookSegment: Equatable, Sendable {
    let page: Int
    let text: String
}

/// Bridge between the audiobook loop and the book screen currently showing
/// the book. The screen supplies closures from its own state; the model
/// knows nothing about WKWebView or PDFKit. All closures are main-actor:
/// they drive WKWebView / PDFKit / @State, which are main-thread-only
/// (the loop awaits them, so isolation hops stay free — the loop is
/// already on the main actor).
struct AudiobookPageProvider {
    /// Text of the current chapter (PDF page-view: current page only),
    /// bucketed per page in order.
    var segments: @MainActor () async -> [AudiobookSegment]
    /// Show this page of the current chapter in the reader UI.
    var showPage: @MainActor (Int) -> Void
    /// Page index the reader is currently showing (wheel seeks land here).
    var currentPage: @MainActor () async -> Int
    /// Advance one chapter (PDF page-view: one page). Returns whether the
    /// position actually moved — false at the end of the book.
    var stepChapter: @MainActor (Int) -> Bool
    /// Language code to synthesize with, for the current chapter's text.
    var language: @MainActor () async -> String
}

/// Outcome of playing one buffer.
enum AudiobookPlayOutcome {
    /// Buffer played to the end.
    case finished
    /// Interrupted by a reader seek (wheel/scroll) — re-sync and continue.
    case seeked
    /// Interrupted by stop — leave the loop.
    case stopped
}

/// Contract for the audio backend so tests can drive the state machine
/// without an AVAudioEngine.
@MainActor
protocol AudiobookAudioEngineType: AnyObject {
    var rate: Float { get set }
    /// Mixer output level 0–1 (read-aloud volume setting).
    var outputVolume: Float { get set }
    /// Play diagnostics surface (wired to the model's status line).
    var onDebug: ((String) -> Void)? { get set }
    func ensureStarted() throws
    /// Schedules and starts playback of the page. Returns false on
    /// failure (the loop then skips the page).
    func start(_ buffer: AVAudioPCMBuffer) -> Bool
    /// True while the page is actively rendering (false at end, pause,
    /// or stop).
    var isPlaying: Bool { get }
    /// Seconds rendered so far in the current page.
    var playbackSeconds: Double { get }
    /// Set by the engine when playback was interrupted for a reader seek;
    /// the loop consumes it (resets to false).
    var seekRequested: Bool { get set }
    func pause()
    func resume()
    /// Stops playback immediately (seek or exit — the loop re-checks
    /// `seekRequested` to distinguish).
    func stopPlayback()
}

/// AVAudioPlayer playback of synthesized pages: one player per page buffer,
/// written to a temp WAV, driven by POLLING from the loop (start, then
/// isPlaying checks) — no async continuations, so a lost completion
/// callback can never wedge the audiobook. Page end: the player leaves
/// isPlaying at the natural end and the loop's grace counter turns that
/// into "page finished". The app activates a .playback AVAudioSession at
/// launch, so playing needs no per-page session work.
@MainActor
final class AudiobookAudioEngine: NSObject, AudiobookAudioEngineType, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var currentRate: Float = 1
    private var currentVolume: Float = 1
    private var interruptionObserver: NSObjectProtocol?
    /// Set when playback was interrupted for a reader seek; the loop
    /// consumes it and re-syncs instead of counting the page as finished.
    private var interrupted = false
    /// Optional sink for play diagnostics (wired to the model's status file).
    var onDebug: ((String) -> Void)?

    var isPlaying: Bool { player?.isPlaying ?? false }

    var playbackSeconds: Double { player?.currentTime ?? 0 }

    var seekRequested: Bool {
        get { interrupted }
        set { interrupted = newValue }
    }

    override init() {
        super.init()
        // Interruption-end resume playback — a dead route would otherwise
        // leave the page playing into silence.
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] note in
            Task { @MainActor in
                guard let self, self.player?.isPlaying != true,
                      let info = note.userInfo,
                      (info[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.ended.rawValue
                else { return }
                let options = AVAudioSession.InterruptionOptions(
                    rawValue: info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
                if options.contains(.shouldResume) {
                    self.player?.play()
                }
            }
        }
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    var rate: Float {
        get { currentRate }
        set {
            currentRate = newValue
            player?.rate = newValue
        }
    }

    var outputVolume: Float {
        get { player?.volume ?? currentVolume }
        set {
            currentVolume = newValue
            player?.volume = newValue
        }
    }

    func ensureStarted() throws {
        // The session is active app-wide; re-activate defensively (an
        // interruption may have deactivated it) and surface failures.
        do {
            try AVAudioSession.sharedInstance().setActive(true, options: [])
        } catch {
            Logger(subsystem: "com.ipodclassic.app", category: "tts")
                .notice("session activate failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Append-only engine trace (Documents/.audiobook_engine.txt) — every
    /// start attempt and failure lands here in order.
    private func engineLog(_ s: String) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let path = docs.appendingPathComponent(".audiobook_engine.txt").path
        let line = "\(Int(Date().timeIntervalSince1970)) \(s)\n"
        if let h = FileHandle(forWritingAtPath: path) {
            defer { try? h.close() }
            _ = try? h.seekToEndOfFile()
            h.write(Data(line.utf8))
        } else {
            try? line.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
        }
    }

    func start(_ buffer: AVAudioPCMBuffer) -> Bool {
        // In-memory 16-bit PCM WAV → AVAudioPlayer(data:). The tmp-file
        // route wrote zero-frame files on device (both Int16 and Float32),
        // making play() return false; the data route has no filesystem in
        // the path at all.
        guard let data = Self.wavData(from: buffer) else {
            engineLog("start failed: wav encode produced no data")
            onDebug?("start failed: wav encode empty")
            return false
        }
        do {
            let p = try AVAudioPlayer(data: data)
            p.enableRate = true
            p.rate = currentRate
            p.volume = currentVolume
            p.delegate = self
            p.prepareToPlay()
            let ok = p.play()
            let seconds = Int(p.duration)
            engineLog("start ok=\(ok) dur=\(seconds)s playing=\(p.isPlaying) rate=\(currentRate) vol=\(currentVolume)")
            onDebug?("start ok=\(ok) dur=\(seconds)s playing=\(p.isPlaying)")
            Logger(subsystem: "com.ipodclassic.app", category: "tts")
                .notice("start: \(seconds, privacy: .public)s ok=\(ok, privacy: .public) playing=\(p.isPlaying, privacy: .public)")
            if ok {
                player = p
                return true
            }
            return false
        } catch {
            engineLog("start failed: \(error.localizedDescription)")
            onDebug?("start failed: \(error.localizedDescription)")
            Logger(subsystem: "com.ipodclassic.app", category: "tts")
                .notice("page playback failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Encode the float PCM buffer as a 16-bit mono WAV in memory.
    static func wavData(from buffer: AVAudioPCMBuffer) -> Data? {
        let frameCount = Int(buffer.frameLength)
        let sampleRate = buffer.format.sampleRate
        guard frameCount > 0, let src = buffer.floatChannelData?[0] else { return nil }
        var pcm = Data(count: frameCount * 2)
        pcm.withUnsafeMutableBytes { raw in
            let dst = raw.bindMemory(to: Int16.self)
            for i in 0..<frameCount {
                let s = max(-1.0, min(1.0, src[i]))
                dst[i] = Int16(s * 32767.0)
            }
        }
        var data = Data()
        data.reserveCapacity(44 + pcm.count)
        func str(_ s: String) { data.append(contentsOf: s.utf8) }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        str("RIFF"); u32(UInt32(36 + pcm.count)); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(Int(sampleRate) * 2)); u16(2); u16(16)
        str("data"); u32(UInt32(pcm.count))
        data.append(pcm)
        return data
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Logger(subsystem: "com.ipodclassic.app", category: "tts")
            .notice("page decode error: \(error?.localizedDescription ?? "none", privacy: .public)")
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // Polling detects the end via isPlaying; the delegate only exists
        // so nothing else is needed here.
    }

    func pause() {
        player?.pause()
    }

    func resume() {
        player?.play()
    }

    func stopPlayback() {
        player?.stop()
        player = nil
    }
}

/// Naive language detection over a chapter's text: stopword counts decide
/// among the common reader languages. Falls back to English when the
/// counts are inconclusive (short texts, names, numbers).
enum AudiobookLanguage {
    static let supported = ["en", "nl", "de", "fr", "es", "it"]

    private static let markers: [String: Set<String>] = [
        "en": ["the", "and", "of", "to", "that", "with", "was", "for", "his", "her", "not", "but", "had"],
        "nl": ["de", "het", "een", "van", "en", "dat", "niet", "met", "zijn", "haar", "ook", "maar", "voor"],
        "de": ["der", "die", "und", "das", "nicht", "mit", "ist", "sich", "auch", "auf", "für", "ein", "eine"],
        "fr": ["le", "la", "les", "et", "que", "dans", "pour", "pas", "sur", "elle", "mais", "avec", "était"],
        "es": ["el", "la", "los", "las", "que", "para", "con", "una", "por", "como", "pero", "más", "para"],
        "it": ["il", "la", "che", "di", "non", "per", "con", "una", "sono", "anche", "più", "come", "nel"],
    ]

    static func detect(_ text: String) -> String {
        let words = text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        guard words.count >= 12 else { return "en" }
        var counts: [String: Int] = [:]
        for w in words {
            for (lang, set) in markers where set.contains(w) {
                counts[lang, default: 0] += 1
            }
        }
        let ranked = counts.sorted { $0.value > $1.value }
        guard let top = ranked.first, top.value >= 5 else { return "en" }
        // Require a clear lead so mixed text stays English (the default).
        if ranked.count > 1, ranked[1].value * 2 > top.value { return "en" }
        return supported.contains(top.key) ? top.key : "en"
    }
}

/// Synthesis seam: the real implementation is ReadAloudVoiceStore
/// (Breeze TTS 2 via MLX — download, load, voice presets); tests supply a
/// mock. Voice identity travels as its preset name string.
@MainActor
protocol AudiobookSynthesizerType: AnyObject {
    /// Download + load the pipeline once (idempotent).
    func ensureReady() async throws
    func synthesize(_ text: String, language: String, voiceName: String) async throws -> (samples: [Float], sampleRate: Int)
}

/// Audiobook mode for the book reader: on-device neural TTS (Breeze TTS 2
/// via MLX, see BreezeTTS.swift) that reads the open book page by page through the same
/// page-turn path as manual reading, so exiting mid-page leaves the reader
/// exactly where listening stopped.
@Observable
@MainActor
final class AudiobookModel {
    enum State: Equatable {
        case idle
        case downloading
        case loading
        case playing
        case paused
        case failed(String)
    }

    private(set) var state: State = .idle {
        didSet { writeStatus() }
    }
    /// Page (chapter-relative) currently being spoken.
    private(set) var page: Int = 0

    /// Extra detail for the rolling status line (e.g. what stage inside
    /// the current segment: fetching voice, synthesizing N chars, playing).
    private var segmentNote = ""
    /// Sticky chapter summary included in every status write (set when a
    /// chapter's segments are extracted).
    private var chapterNote = ""

    /// Rolling status line (Documents/.audiobook_status.txt) so a QA pull
    /// from a device can see exactly where the pipeline is without a
    /// console. Written on state/page/note changes only.
    private func writeStatus() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let parts = [segmentNote, chapterNote].filter { !$0.isEmpty }.joined(separator: " ")
        let line = "state=\(state) page=\(page)\(parts.isEmpty ? "" : " " + parts) t=\(Int(Date().timeIntervalSince1970))"
        try? line.write(to: docs.appendingPathComponent(".audiobook_status.txt"),
                        atomically: true, encoding: .utf8)
    }

    /// Engine play diagnostics surface in the status line.
    func noteEngine(_ note: String) {
        segmentNote = note
        writeStatus()
    }

    /// Playback speed (time-pitch rate); index into `speeds`. Wraps.
    var speedIndex: Int {
        get { AppSettings.shared.audiobookSpeedIndex }
        set {
            let wrapped = (newValue + Self.speeds.count) % Self.speeds.count
            AppSettings.shared.audiobookSpeedIndex = wrapped
            engine.rate = Self.speeds[wrapped]
        }
    }
    static let speeds: [Float] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    /// Read-aloud volume (mixer output level); index into `volumes`. Wraps.
    var volumeIndex: Int {
        get { AppSettings.shared.audiobookVolumeIndex }
        set {
            let wrapped = (newValue + Self.volumes.count) % Self.volumes.count
            AppSettings.shared.audiobookVolumeIndex = wrapped
            engine.outputVolume = Self.volumes[wrapped]
        }
    }
    static let volumes: [Float] = [0.1, 0.25, 0.5, 0.75, 1.0]

    /// Voice preset; index into `voices`. Wraps.
    var voiceIndex: Int {
        get { max(0, Self.voices.firstIndex(of: currentVoice) ?? 0) }
        set {
            let wrapped = (newValue + Self.voices.count) % Self.voices.count
            currentVoice = Self.voices[wrapped] // didSet persists + invalidates
        }
    }
    nonisolated static let voices: [String] = ReadAloudVoiceStore.voices.map(\.name)
    nonisolated static var voiceCount: Int { voices.count }
    private var currentVoice: String {
        didSet { AppSettings.shared.audiobookVoice = currentVoice }
    }

    private let engine: AudiobookAudioEngineType
    private let synthesis: AudiobookSynthesizerType
    private var pipelineReady = false
    private var provider: AudiobookPageProvider?
    private var loop: Task<Void, Never>?
    /// Single-entry buffer cache (current segment) + the in-flight
    /// prefetch. A page of audio is ~10 MB at 44.1 kHz float mono.
    private var cache: [String: AVAudioPCMBuffer] = [:]

    convenience init() {
        self.init(engine: AudiobookAudioEngine(), synthesis: ReadAloudVoiceStore.shared)
    }

    init(engine: AudiobookAudioEngineType, synthesis: AudiobookSynthesizerType) {
        self.engine = engine
        self.synthesis = synthesis
        let stored = AppSettings.shared.audiobookVoice
        self.currentVoice = Self.voices.first { $0 == stored } ?? Self.voices[0]
        self.engine.rate = Self.speeds[AppSettings.shared.audiobookSpeedIndex]
        let vol = AppSettings.shared.audiobookVolumeIndex
        self.engine.outputVolume = Self.volumes[min(max(vol, 0), Self.volumes.count - 1)]
        engine.onDebug = { [weak self] note in
            self?.noteEngine(note)
        }
    }

    var isActive: Bool { state != .idle }

    /// Current playback rate (time-pitch).
    var rate: Float { engine.rate }

    /// Panel labels.
    var voiceLabel: String { currentVoice }
    var speedLabel: String {
        let v = Self.speeds[min(max(speedIndex, 0), Self.speeds.count - 1)]
        return v == v.rounded() ? String(format: "%.0f×", v) : String(format: "%g×", v)
    }
    var volumeLabel: String {
        let v = Self.volumes[min(max(volumeIndex, 0), Self.volumes.count - 1)]
        return "\(Int((v * 100).rounded()))%"
    }

    /// What the audiobook is doing right now, for the panel row.
    var statusText: String {
        switch state {
        case .idle: return "Off"
        case .downloading: return "Downloading voice engine…"
        case .loading: return "Preparing voices…"
        case .playing: return "Playing page \(page + 1)"
        case .paused: return "Paused — page \(page + 1)"
        case .failed(let message): return message
        }
    }

    // MARK: Controls

    func start(provider: AudiobookPageProvider) {
        stop()
        self.provider = provider
        loop = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func togglePlayPause() {
        switch state {
        case .playing:
            engine.pause()
            state = .paused
        case .paused:
            engine.resume()
            state = .playing
        default:
            break
        }
    }

    func stop() {
        loop?.cancel()
        engine.seekRequested = false
        engine.stopPlayback()
        loop = nil
        provider = nil
        cache.removeAll()
        if state != .idle { state = .idle }
        page = 0
    }

    /// The reader's page changed underneath playback (wheel, chapter
    /// step). Interrupt the current buffer; the loop re-syncs to the page
    /// the reader shows before speaking again.
    /// The reader's page changed underneath playback (wheel, chapter
    /// step). Flag a seek and drop the current page; the loop re-syncs to
    /// the page the reader shows before speaking again.
    func readerMoved() {
        guard state == .playing || state == .paused else { return }
        engine.seekRequested = true
        engine.stopPlayback()
    }

    // MARK: Loop

    private func runLoop() async {
        guard let provider else { return }
        state = .playing
        Logger(subsystem: "com.ipodclassic.app", category: "tts").notice("audiobook loop start")
        // First page: start where the reader is.
        let begin = await provider.currentPage()
        provider.showPage(begin)
        while !Task.isCancelled {
            let segments = await provider.segments()
            Logger(subsystem: "com.ipodclassic.app", category: "tts")
                .notice("segments: \(segments.count, privacy: .public)")
            let total = segments.reduce(0) { $0 + $1.text.count }
            let maxPage = segments.map(\.page).max() ?? 0
            chapterNote = "chapter: \(segments.count) segs, \(total) chars, maxPage=\(maxPage)"
            writeStatus()
            Logger(subsystem: "com.ipodclassic.app", category: "tts")
                .notice("chapter: \(segments.count, privacy: .public) segments, \(total, privacy: .public) chars, maxPage \(maxPage, privacy: .public)")
            guard !segments.isEmpty else {
                // Blank chapter / image-only page — skip forward.
                if provider.stepChapter(1) { continue }
                break
            }
            let shown = await provider.currentPage()
            let first = segments.firstIndex { $0.page >= shown } ?? 0
            var i = first
            while i < segments.count, !Task.isCancelled {
                let segment = segments[i]
                page = segment.page
                provider.showPage(segment.page)
                do {
                    segmentNote = "synthesizing \(segment.text.count) chars"
                    writeStatus()
                    let buffer = try await bufferFor(segment, language: await provider.language())
                    try engine.ensureStarted()
                    if Task.isCancelled { return }
                    if state == .downloading || state == .loading { state = .playing }
                    let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
                    segmentNote = "playing \(Int(seconds))s"
                    writeStatus()
                    guard engine.start(buffer) else {
                        // Playback failed to start — stop with the reason
                        // visible (the engine note stays in the status).
                        state = .failed("Audio playback failed")
                        return
                    }
                    // Poll until the page ends. Polling (never awaiting a
                    // callback) is deliberate: lost completions stalled the
                    // whole audiobook; Task.sleep always resumes.
                    var idle = 0
                    var seeked = false
                    var rendered = 0.0
                    while !Task.isCancelled {
                        if engine.seekRequested {
                            engine.seekRequested = false
                            seeked = true
                            break
                        }
                        if state == .paused {
                            idle = 0
                        } else if engine.isPlaying {
                            idle = 0
                            rendered = max(rendered, engine.playbackSeconds)
                        } else {
                            idle += 1
                            if idle >= 4 { break } // ~2 s past the end = page done
                        }
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                    if Task.isCancelled { return }
                    // A page that "ended" without ever rendering is a dead
                    // audio backend (decode errors etc.) — surface it
                    // instead of racing through the book page by page.
                    if !seeked, rendered < seconds * 0.5 {
                        Logger(subsystem: "com.ipodclassic.app", category: "tts")
                            .notice("no audio rendered (\(rendered, privacy: .public)s of \(seconds, privacy: .public)s)")
                        segmentNote = "stopped after \(Int(rendered))s of \(Int(seconds))s"
                        writeStatus()
                        state = .failed("Audio playback failed")
                        return
                    }
                    if seeked {
                        // The reader moved underneath playback (wheel,
                        // chapter step). Resume at the page now showing;
                        // past the chapter's last segment → chapter step
                        // below handles the advance.
                        let showing = await provider.currentPage()
                        i = segments.firstIndex { $0.page >= showing } ?? segments.count
                    } else {
                        i += 1
                        prefetch(segments, at: i, language: await provider.language())
                    }
                } catch is CancellationError {
                    return
                } catch {
                    Logger(subsystem: "com.ipodclassic.app", category: "tts")
                        .notice("synth failed: \(error.localizedDescription, privacy: .public)")
                    // Surface the underlying message — the voice store's
                    // errors are user-meaningful ("needs a real device",
                    // download failures); a generic label hid them.
                    state = .failed(error.localizedDescription.isEmpty ? "Speech failed" : error.localizedDescription)
                    return
                }
            }
            // Chapter finished — walk forward; at the book's end, stop.
            let moved = provider.stepChapter(1)
            Logger(subsystem: "com.ipodclassic.app", category: "tts")
                .notice("chapter done, advanced=\(moved, privacy: .public)")
            if !moved { break }
        }
        if state == .playing || state == .paused { state = .idle }
    }

    /// Begin synthesizing the next segment in the background so the gap
    /// between pages stays small.
    private func prefetch(_ segments: [AudiobookSegment], at index: Int, language: String) {
        guard segments.indices.contains(index) else { return }
        let text = segments[index].text
        guard cache[text] == nil else { return }
        Task { [weak self] in
            _ = try? await self?.bufferFor(segments[index], language: language)
        }
    }

    private func bufferFor(_ segment: AudiobookSegment, language: String) async throws -> AVAudioPCMBuffer {
        if let cached = cache[segment.text] { return cached }
        let (samples, sampleRate) = try await synthesize(segment.text, language: language)
        let buffer = Self.makeBuffer(samples, sampleRate: sampleRate)
        cache.removeAll()
        cache[segment.text] = buffer
        return buffer
    }

    private func synthesize(_ text: String, language: String) async throws -> (samples: [Float], sampleRate: Int) {
        if !pipelineReady {
            state = .downloading
            LiveActivityManager.shared.downloadStarted()
            Logger(subsystem: "com.ipodclassic.app", category: "tts").notice("downloading pipeline")
        }
        do {
            try await synthesis.ensureReady()
        } catch {
            Logger(subsystem: "com.ipodclassic.app", category: "tts")
                .notice("download failed: \(error.localizedDescription, privacy: .public)")
            LiveActivityManager.shared.downloadFinished(success: false)
            state = .failed("Download failed")
            throw error
        }
        if !pipelineReady {
            pipelineReady = true
            state = .loading
            LiveActivityManager.shared.downloadFinished(success: true)
        }
        return try await synthesis.synthesize(text, language: language, voiceName: currentVoice)
    }

    // MARK: Audio

    static func makeBuffer(_ samples: [Float], sampleRate: Int) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1)))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let dst = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                dst.update(from: src.baseAddress!, count: samples.count)
            }
        }
        return buffer
    }

    // MARK: QA

    /// QA_TRANSCRIBE-style end-to-end check: download, load, synthesize a
    /// short line, write stage statuses to Documents/qa_status.txt and the
    /// audio to Documents/qa_tts.wav. Never touches player state.
    func qaHook(text: String) async {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let status = docs.appendingPathComponent("qa_status.txt")
        func stage(_ s: String) {
            FileManager.default.createFile(atPath: status.path, contents: Data(s.utf8))
            Logger(subsystem: "com.ipodclassic.app", category: "tts").notice("STAGE \(s, privacy: .public)")
        }
        do {
            stage("download-start")
            let store = ReadAloudVoiceStore.shared
            _ = try await store.loadModelIfNeeded()
            stage("model-ready")
            stage("synth-start")
            let t0 = Date()
            let (samples, sampleRate) = try await store.synthesize(text: text, voiceName: currentVoice)
            let duration = Double(samples.count) / Double(max(sampleRate, 1))
            let rtf = Date().timeIntervalSince(t0) / Double(max(duration, 0.001))
            stage("synth-done")
            let buffer = Self.makeBuffer(samples, sampleRate: sampleRate)
            if let file = try? AVAudioFile(forWriting: docs.appendingPathComponent("qa_tts.wav"),
                                           settings: buffer.format.settings) {
                try? file.write(from: buffer)
            }
            // Playback stage: run the page buffer through the real engine
            // (start + short poll) so the QA covers the audio path too.
            stage("play-start")
            try engine.ensureStarted()
            let playOk = engine.start(buffer)
            if playOk {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                stage("play-3s isPlaying=\(engine.isPlaying) cur=\(Int(engine.playbackSeconds))s")
            } else {
                stage("play-start FAILED")
            }
            let headroom = os_proc_available_memory() / 1_048_576
            Logger(subsystem: "com.ipodclassic.app", category: "tts")
                .notice("RESULT rtf=\(String(format: "%.2f", rtf), privacy: .public) samples=\(samples.count, privacy: .public) headroomMB=\(Int(headroom), privacy: .public)")
            stage(String(format: "RESULT rtf=%.2f headroomMB=%d", rtf, Int(headroom)))
        } catch {
            stage("failed: \(error.localizedDescription)")
        }
    }
}
