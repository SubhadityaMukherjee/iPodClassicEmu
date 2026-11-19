import AVFoundation
import Foundation
import NaturalLanguage
import Observation
import OSLog
import UIKit

/// One speakable unit: the text on a single page of a chapter, in reading
/// order. The page index drives the real page turns, so audiobook playback
/// and normal reading always agree on position.
struct AudiobookSegment: Equatable, Sendable {
    /// Chapter-relative page index (PDF page-view: the PDF page index) —
    /// drives the real page turns so listening and reading agree.
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
    /// Playback rate (time-pitch).
    var rate: Float { get set }
    /// Mixer output level 0–1 (read-aloud volume setting).
    var outputVolume: Float { get set }
    /// Play diagnostics surface (wired to the model's status line).
    var onDebug: ((String) -> Void)? { get set }
    /// Makes sure the audio session is active before playing.
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
    /// Pauses the current page (resumable in place).
    func pause()
    /// Resumes the paused page.
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
    /// Player for the current page (one player per page buffer).
    private var player: AVAudioPlayer?
    /// Rate/volume remembered between players (applied on each start).
    private var currentRate: Float = 1
    private var currentVolume: Float = 1
    /// Token for the interruption observer (removed in deinit).
    private var interruptionObserver: NSObjectProtocol?
    /// Set when playback was interrupted for a reader seek; the loop
    /// consumes it and re-syncs instead of counting the page as finished.
    private var interrupted = false
    /// Optional sink for play diagnostics (wired to the model's status file).
    var onDebug: ((String) -> Void)?

    /// True while the current page's player runs.
    var isPlaying: Bool { player?.isPlaying ?? false }

    /// Seconds of the current page rendered so far.
    var playbackSeconds: Double { player?.currentTime ?? 0 }

    /// Interrupt flag shared with the loop (bridge over `interrupted`).
    var seekRequested: Bool {
        get { interrupted }
        set { interrupted = newValue }
    }

    /// Registers the audio-interruption observer (resumes playback when
    /// the system allows it after an interruption ends).
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

    /// Drops the interruption observer.
    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    /// Time-pitch rate, applied to the live player and remembered for
    /// the next one.
    var rate: Float {
        get { currentRate }
        set {
            currentRate = newValue
            player?.rate = newValue
        }
    }

    /// Output level 0–1, applied to the live player and remembered.
    var outputVolume: Float {
        get { player?.volume ?? currentVolume }
        set {
            currentVolume = newValue
            player?.volume = newValue
        }
    }

    /// Defensively re-activates the shared .playback session (an
    /// interruption may have deactivated it); activation failures are
    /// logged, not thrown.
    ///
    /// Concept: avfoundation-audio-session → docs/concepts/avfoundation-audio-session.md
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

    /// Plays one page: encodes the buffer as an in-memory WAV and hands
    /// it to AVAudioPlayer(data:) — the temp-FILE route wrote zero-frame
    /// files on device, so nothing touches the filesystem here. Every
    /// attempt lands in the engine trace.
    ///
    /// - Returns: false when encoding or playback fails (the loop then
    ///   stops with a visible reason).
    ///
    /// Concept: avfoundation-playback → docs/concepts/avfoundation-playback.md
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
        /// Appends a 4-character RIFF chunk tag (e.g. "RIFF").
        func str(_ s: String) { data.append(contentsOf: s.utf8) }
        /// Appends a little-endian 16-bit field.
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        /// Appends a little-endian 32-bit field.
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        str("RIFF"); u32(UInt32(36 + pcm.count)); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(Int(sampleRate) * 2)); u16(2); u16(16)
        str("data"); u32(UInt32(pcm.count))
        data.append(pcm)
        return data
    }

    /// Logs decode failures (they surface as the loop's "no audio
    /// rendered" stop).
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Logger(subsystem: "com.ipodclassic.app", category: "tts")
            .notice("page decode error: \(error?.localizedDescription ?? "none", privacy: .public)")
    }

    /// Deliberately empty — the loop's isPlaying polling detects the end.
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // Polling detects the end via isPlaying; the delegate only exists
        // so nothing else is needed here.
    }

    /// Pauses the current page in place.
    func pause() {
        player?.pause()
    }

    /// Resumes the paused page.
    func resume() {
        player?.play()
    }

    /// Stops and drops the player (seek or exit).
    func stopPlayback() {
        player?.stop()
        player = nil
    }
}

/// Naive language detection over a chapter's text: stopword counts decide
/// among the common reader languages. Falls back to English when the
/// counts are inconclusive (short texts, names, numbers).
enum AudiobookLanguage {
    /// Codes the TTS engine accepts (and `detect` can return).
    static let supported = ["en", "nl", "de", "fr", "es", "it"]

    /// Frequent-word sets per language; hit counts decide the winner.
    private static let markers: [String: Set<String>] = [
        "en": ["the", "and", "of", "to", "that", "with", "was", "for", "his", "her", "not", "but", "had"],
        "nl": ["de", "het", "een", "van", "en", "dat", "niet", "met", "zijn", "haar", "ook", "maar", "voor"],
        "de": ["der", "die", "und", "das", "nicht", "mit", "ist", "sich", "auch", "auf", "für", "ein", "eine"],
        "fr": ["le", "la", "les", "et", "que", "dans", "pour", "pas", "sur", "elle", "mais", "avec", "était"],
        "es": ["el", "la", "los", "las", "que", "para", "con", "una", "por", "como", "pero", "más", "para"],
        "it": ["il", "la", "che", "di", "non", "per", "con", "una", "sono", "anche", "più", "come", "nel"],
    ]

    /// Stopword-count language guess. Needs ≥12 words and a clear lead
    /// (the runner-up must not reach half the winner's hits) — otherwise
    /// the English default stands.
    ///
    /// - Returns: a code from `supported` (or "en").
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
/// (three English engines selectable in Settings → Read Aloud); tests
/// supply a mock. Voice identity travels as its preset name string.
@MainActor
protocol AudiobookSynthesizerType: AnyObject {
    /// Download + load the pipeline once (idempotent).
    func ensureReady() async throws
    /// True when the engine is loaded (a cached install reports this
    /// from its disk probe) — lets callers label "Preparing" instead of
    /// "Downloading" for warm starts.
    var isReady: Bool { get }
    /// True when the engine chunks at SENTENCE level internally with
    /// seamless audio state (Pocket, Paradee) — `render` then feeds it
    /// whole pages. False for engines with a small internal chunk cap
    /// (Supertonic's 70 chars), which need our `speechUnits` pipeline.
    var feedsWholePages: Bool { get }
    /// Synthesizes one text chunk to raw float samples.
    ///
    /// - Returns: mono samples and their sample rate.
    /// - Throws: engine-specific errors (device requirements, download
    ///   failures) — surfaced to the user by the model.
    ///
    /// Concept: on-device-ml → docs/concepts/on-device-ml.md
    func synthesize(_ text: String, language: String, voiceName: String) async throws -> (samples: [Float], sampleRate: Int)
}

/// Audiobook mode for the book reader: on-device neural TTS (three
/// English engines selectable in Settings → Read Aloud — Pocket 18m
/// default, Pocket 100M, Paradee 8M; see ReadAloudTTS.swift) that reads
/// the open book page by page through the same page-turn path as manual
/// reading, so exiting mid-page leaves the reader exactly where
/// listening stopped.
@Observable
@MainActor
final class AudiobookModel {
    /// Pipeline phases: downloading (model fetch), loading (cached
    /// engine warming up), playing/paused, and failed carrying the
    /// user-facing reason.
    enum State: Equatable {
        case idle
        case downloading
        case loading
        case playing
        case paused
        case failed(String)
    }

    /// Current phase; every change rewrites the QA status file.
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
    /// Speed cycle (indexed by `speedIndex`).
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
    /// Volume cycle (indexed by `volumeIndex`).
    static let volumes: [Float] = [0.1, 0.25, 0.5, 0.75, 1.0]

    /// Voice preset; index into `voices`. Wraps.
    var voiceIndex: Int {
        get { max(0, Self.voices.firstIndex(of: currentVoice) ?? 0) }
        set {
            let wrapped = (newValue + Self.voices.count) % Self.voices.count
            currentVoice = Self.voices[wrapped] // didSet persists + invalidates
        }
    }
    /// Voice presets of the SELECTED engine (Pocket: the 21 English
    /// "literary" voices; Paradee: af_heart & co). The stored preference
    /// falls back to the first when the saved name doesn't exist.
    nonisolated static var voices: [String] { ReadAloudVoiceStore.voices }
    /// Count of the voice presets.
    nonisolated static var voiceCount: Int { voices.count }
    /// Stored voice preset, persisted on change.
    private var currentVoice: String {
        didSet { AppSettings.shared.audiobookVoice = currentVoice }
    }

    /// Audio backend (injected for tests).
    private let engine: AudiobookAudioEngineType
    /// TTS backend (injected for tests).
    private let synthesis: AudiobookSynthesizerType
    /// Set after the first successful ensureReady — later loads are
    /// "Preparing", never a bogus "Downloading".
    private var pipelineReady = false
    /// The book screen's page closures (nil while stopped).
    private var provider: AudiobookPageProvider?
    /// The running playback-loop task (cancelled by `stop`).
    private var loop: Task<Void, Never>?
    /// Four-entry buffer cache (playing page + prefetches; a single-entry
    /// cache evicted the playing page). A page of audio is ~10 MB at
    /// 44.1 kHz float mono. `cacheOrder` preserves insertion order —
    /// dictionary `keys.first` is ARBITRARY and could evict the page
    /// that is playing or the one just prefetched.
    private var cache: [String: AVAudioPCMBuffer] = [:]
    /// Insertion order for FIFO eviction (mirrors `cache` keys).
    private var cacheOrder: [String] = []
    /// In-flight syntheses keyed by segment text, so the loop's own
    /// `bufferFor` and a concurrent prefetch of the same page share one
    /// render instead of synthesizing the text twice.
    private var inFlight: [String: Task<AVAudioPCMBuffer, Error>] = [:]
    /// Number of synthesis windows currently open (loop + prefetches).
    /// The keep-alive is held while ANY window is open — a plain
    /// start/stop pair per call let one window's defer-stop cut the
    /// keep-alive under another window's still-running synthesis.
    private var synthWindows = 0
    /// Silent loop during synthesis windows: nothing is playing while a
    /// page is being generated, and with the screen locked iOS suspends
    /// the process — freezing neural synthesis mid-generation (the QA
    /// run stalled exactly here). Real page playback covers the gaps
    /// between syntheses; this covers the syntheses themselves.
    private let synthKeepAlive = SilentKeepAlive()

    /// Production wiring: the real engine and voice store.
    convenience init() {
        self.init(engine: AudiobookAudioEngine(), synthesis: ReadAloudVoiceStore.shared)
    }

    /// Test-friendly initializer (both backends are seams); restores the
    /// persisted voice/speed/volume onto the engine.
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

    /// True while a session runs (any state but idle).
    var isActive: Bool { state != .idle }

    /// Current playback rate (time-pitch).
    var rate: Float { engine.rate }

    /// Panel labels.
    var voiceLabel: String { currentVoice }
    /// Speed for the panel row, e.g. "1.5×".
    var speedLabel: String {
        let v = Self.speeds[min(max(speedIndex, 0), Self.speeds.count - 1)]
        return v == v.rounded() ? String(format: "%.0f×", v) : String(format: "%g×", v)
    }
    /// Volume for the panel row, e.g. "75%".
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

    /// (Re)starts read-aloud for the open book; any prior session is
    /// stopped first.
    func start(provider: AudiobookPageProvider) {
        stop()
        self.provider = provider
        loop = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// Pauses or resumes the current page.
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

    /// Full teardown: loop, engine, keep-alive, provider, and buffer
    /// cache; state returns to idle.
    func stop() {
        loop?.cancel()
        engine.seekRequested = false
        engine.stopPlayback()
        synthKeepAlive.stop()
        loop = nil
        provider = nil
        cache.removeAll()
        cacheOrder.removeAll()
        for t in inFlight.values { t.cancel() }
        inFlight.removeAll()
        synthWindows = 0
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

    /// Echo-proof `readerMoved`: the loop turns pages programmatically
    /// (`provider.showPage`) while speaking, and a page-settling callback
    /// reporting the SAME page we are already speaking must not read as a
    /// user seek — that restarted the playing page mid-sentence (heard as
    /// a break + repeat). Only a genuine move to another page interrupts.
    func readerMoved(to newPage: Int) {
        guard state == .playing || state == .paused else { return }
        guard newPage != page else { return }
        readerMoved()
    }

    // MARK: Loop

    /// The playback loop — deliberately POLL-BASED: engine.start, then
    /// isPlaying checks every 0.5 s. No continuation ever waits on an
    /// engine callback; lost callbacks stalled the audiobook before,
    /// while Task.sleep always resumes.
    ///
    /// Per chapter: fetch page segments, start at the page the reader
    /// shows, then per segment synthesize → play → poll. The seek flag
    /// is cleared on the SAME tick a page starts (a stale delayed flag
    /// from the wheel path cut pages mid-sentence). Two consecutive
    /// idle polls (~1 s grace) end a page; a page that ends without
    /// rendering half its audio is a dead backend and stops the book
    /// instead of racing on. Seeks re-index to the page now showing;
    /// normal completion prefetches ahead. Chapters advance until
    /// stepChapter reports the book's end.
    ///
    /// Concept: swift-async-await → docs/concepts/swift-async-await.md
    private func runLoop() async {
        guard let provider else { return }
        state = .playing
        Logger(subsystem: "com.ipodclassic.app", category: "tts").notice("audiobook loop start")
        // First page: start where the reader is.
        let begin = await provider.currentPage()
        provider.showPage(begin)
        while !Task.isCancelled {
            // Sentence-aligned BEFORE use: a sentence straddling a page
            // boundary is spoken in full with the page it starts on (and
            // dropped from the next) — otherwise each segment boundary
            // mid-sentence gets end-of-sentence intonation + a gap +
            // fresh intonation ("was <break> overwhelmed").
            let segments = Self.sentenceAligned(await provider.segments())
            Logger(subsystem: "com.ipodclassic.app", category: "tts")
                .notice("segments: \(segments.count, privacy: .public)")
            let total = segments.reduce(0) { $0 + $1.text.count }
            let maxPage = segments.map(\.page).max() ?? 0
            chapterNote = "chapter: \(segments.count) segs, \(total) chars, maxPage=\(maxPage)"
            writeStatus()
            // QA hook: append every segment of this chapter to
            // Documents/.audiobook_segments.txt — the ground truth for
            // "is a sentence the reader shows actually in the spoken
            // text?" (extraction-drop bugs look like skipped sentences).
            if ProcessInfo.processInfo.environment["AUDIOBOOK_DUMP"] == "1" {
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let url = docs.appendingPathComponent(".audiobook_segments.txt")
                var dump = "\n=== chapter pages \(segments.first?.page ?? -1)–\(maxPage): \(segments.count) segs, \(total) chars ===\n"
                for s in segments { dump += "[p\(s.page)] \(s.text)\n" }
                if let h = FileHandle(forWritingAtPath: url.path) {
                    defer { try? h.close() }
                    _ = try? h.seekToEndOfFile()
                    h.write(Data(dump.utf8))
                } else {
                    try? dump.write(to: url, atomically: true, encoding: .utf8)
                }
            }
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
                    // A seek flag raised by our own programmatic page turn
                    // (or a stale delayed readerMoved from the wheel path)
                    // must not cut the page we are ABOUT to play — clear
                    // it on the same tick the audio starts.
                    engine.seekRequested = false
                    guard engine.start(buffer) else {
                        // Playback failed to start — stop with the reason
                        // visible (the engine note stays in the status).
                        state = .failed("Audio playback failed")
                        return
                    }
                    // Prefetch NOW, while the page plays — synthesis is
                    // slower than playback (RTF ~0.3), so the next page
                    // must render during this one or the gap between pages
                    // lands mid-sentence (the old call fired only after
                    // the page had already ended).
                    prefetch(segments, at: i + 1, language: await provider.language())
                    // Poll until the page ends. Polling (never awaiting a
                    // callback) is deliberate: lost completions stalled the
                    // whole audiobook; Task.sleep always resumes.
                    var idle = 0
                    var seeked = false
                    var rendered = 0.0
                    var recoveries = 0
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
                            // Playback stopped well short of the page end
                            // without a seek: an interruption (call, Siri,
                            // route change) paused the player mid-sentence.
                            // Distinguish that from a natural end — try to
                            // resume in place a couple of times and wait it
                            // out; only then treat the page as finished.
                            let short = seconds - rendered > 3.0
                            if short, idle >= 2, recoveries < 2 {
                                recoveries += 1
                                idle = 0
                                try? engine.ensureStarted()
                                engine.resume()
                            } else if idle >= (short ? 60 : 2) {
                                break // ~1 s past a natural end = page done
                            }
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

    /// Moves sentences that straddle a SEGMENT (page) boundary wholly
    /// into the segment where they START: page buckets cut sentences at
    /// arbitrary words, and each segment is synthesized independently —
    /// a mid-sentence segment edge sounds like the voice finishing a
    /// sentence ("was ⏸ overwhelmed by tree-trunks"). A straddling tail
    /// joins the first sentence of the NEXT segment, and that sentence
    /// is removed from it. Idempotent: aligned segments end on
    /// terminators and are left untouched.
    static func sentenceAligned(_ segments: [AudiobookSegment]) -> [AudiobookSegment] {
        guard segments.count > 1 else { return segments }
        var texts = segments.map(\.text)
        func endsSentence(_ s: String) -> Bool {
            let closers = CharacterSet(charactersIn: "\"'”’)]").union(.whitespacesAndNewlines)
            let trimmed = s.trimmingCharacters(in: closers)
            return trimmed.last.map { ".!?…".contains($0) } ?? true
        }
        for i in texts.indices.dropLast() {
            guard !texts[i].isEmpty, !endsSentence(texts[i]) else { continue }
            var next = texts[i + 1]
            guard !next.isEmpty else { continue }
            // The next segment's FIRST sentence (tokenizer: it won't cut
            // at "Mr." etc.); if even that lacks a terminator, take it
            // whole — the following boundary pass handles the rest.
            var cut = next.endIndex
            let tok = NLTokenizer(unit: .sentence)
            tok.string = next
            if let first = tok.tokens(for: next.startIndex..<next.endIndex).first {
                cut = first.upperBound
            }
            let moved = next[..<cut].trimmingCharacters(in: .whitespacesAndNewlines)
            next = String(next[cut...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !moved.isEmpty else { continue }
            texts[i] = texts[i] + " " + moved
            texts[i + 1] = next
        }
        return zip(segments, texts).compactMap { seg, text in
            text.isEmpty ? nil : AudiobookSegment(page: seg.page, text: text)
        }
    }

    /// Begin synthesizing the NEXT pages in the background while the
    /// current page plays. Two ahead: synthesis is slower than playback
    /// (RTF ~0.3), and the second-ahead prefetch covers a short page.
    /// `bufferFor`'s in-flight dedup makes overlapping calls with the
    /// loop share one render.
    private func prefetch(_ segments: [AudiobookSegment], at index: Int, language: String) {
        for offset in 0...1 {
            guard segments.indices.contains(index + offset) else { return }
            let text = segments[index + offset].text
            guard cache[text] == nil, inFlight[text] == nil else { continue }
            Task { [weak self] in
                _ = try? await self?.bufferFor(segments[index + offset], language: language)
            }
        }
    }

    /// Groups a page into chunks of whole sentences up to `limit`
    /// (limit 1500 = one chunk for a normal page; grouping only guards
    /// pathological runs).
    ///
    /// NOT used by the render path since 2026-11-19 — superseded by
    /// `speechUnits` (one giant call per page let the engine re-chunk
    /// internally mid-sentence, and every call bakes edge silence —
    /// together heard as a pause mid-sentence every sentence). Kept
    /// because the test suite pins its behavior.
    ///
    /// Sentence boundaries come from `NLTokenizer` (unit: .sentence) —
    /// it knows "Mr.", "Dr.", "e.g." and initials are NOT sentence
    /// ends. The previous regex split after any ". " and ended chunks
    /// mid-sentence at every abbreviation: the voice dropped to
    /// end-of-sentence intonation, spliced hard, and the user heard it
    /// as the audio "stopping mid sentence" every few sentences.
    /// Sentences are grouped up to `limit`; a single sentence longer
    /// than `limit` is split at word boundaries (never left oversized —
    /// an oversized call is exactly the tail-truncation bug).
    static func sentenceChunks(_ text: String, limit: Int = 1500) -> [String] {
        guard text.count > limit else {
            return [text.replacingOccurrences(of: "\n", with: " ")]
        }
        var chunks: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty {
                chunks.append(current)
                current = ""
            }
        }
        // Paragraph by paragraph: a paragraph break ends the chunk, so
        // no chunk spans it and the gap supplies the pause.
        for para in text.components(separatedBy: "\n\n") {
            let paraText = para.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !paraText.isEmpty else { continue }
            let tok = NLTokenizer(unit: .sentence)
            tok.string = paraText
            var sentences: [String] = []
            var start = paraText.startIndex
            tok.enumerateTokens(in: paraText.startIndex..<paraText.endIndex) { range, _ in
                // A very long "sentence" (list, unpunctuated run) must
                // still be split — at word boundaries, under the limit.
                let piece = String(paraText[start..<range.upperBound])
                sentences.append(contentsOf: piece.count > limit ? Self.wordSplit(piece, limit: limit) : [piece])
                start = range.upperBound
                return true
            }
            if start < paraText.endIndex {
                let tail = String(paraText[start...])
                sentences.append(contentsOf: tail.count > limit ? Self.wordSplit(tail, limit: limit) : [tail])
            }
            for sentence in sentences {
                if !current.isEmpty, current.count + sentence.count > limit {
                    flush()
                }
                current += sentence
            }
            flush()
        }
        if chunks.isEmpty {
            return [text.replacingOccurrences(of: "\n", with: " ")]
        }
        return chunks
    }

    /// Splits an over-limit run at word boundaries into pieces of at
    /// most `limit` characters. Joins back to exactly the input.
    private static func wordSplit(_ text: String, limit: Int) -> [String] {
        var pieces: [String] = []
        var current = ""
        var iter = text.makeIterator()
        var word = ""
        while let ch = iter.next() {
            word.append(ch)
            if ch == " " || ch == "\n" {
                if !current.isEmpty, current.count + word.count > limit {
                    pieces.append(current)
                    current = word
                } else {
                    current += word
                }
                word = ""
            }
        }
        if !word.isEmpty {
            if !current.isEmpty, current.count + word.count > limit {
                pieces.append(current); current = word
            } else {
                current += word
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces.isEmpty ? [text] : pieces
    }

    /// One speakable unit: a sentence (or a merged run of very short
    /// ones), sized under the engine's own internal chunk limit, plus
    /// the pause to append after it.
    struct SpeechUnit: Equatable {
        let text: String
        /// Silence appended after this unit, in seconds.
        let pauseAfter: Double
    }

    /// Splits a page into sentence-sized speech units (the render
    /// pipeline's unit of synthesis since 2026-11-19).
    ///
    /// WHY unit-sized calls: FluidAudio chunks long synthesis calls
    /// internally (~300 chars), and each internal split lands
    /// MID-SENTENCE at an arbitrary word with the engine's own pause —
    /// a one-call-per-page design (the 2026-11-18 `sentenceChunks`
    /// doctrine) therefore read as the voice pausing mid-sentence every
    /// sentence even though every word was spoken. Every call ALSO
    /// bakes leading/trailing silence into its audio. Units are hence
    /// kept under the internal chunk size (200 chars, safely below
    /// ~300), split at sentence/clause boundaries ONLY (never
    /// mid-word), `render` trims each call's baked-in silence, and the
    /// only pauses left are the deliberate ones:
    /// 0.08 s within a sentence split at a clause, 0.2 s between
    /// sentences, 0.45 s at a paragraph end.
    ///
    /// Sentence boundaries come from `NLTokenizer` (knows "Mr."/
    /// "Dr." are not ends); very short sentences merge into the next
    /// call ("Yes." "No." alone are unnatural single-word utterances);
    /// an over-long sentence splits at its last clause break
    /// (comma/semicolon/dash) or space.
    static func speechUnits(_ raw: String, maxChars: Int = 200) -> [SpeechUnit] {
        var units: [SpeechUnit] = []
        for para in normalizeForSpeech(raw).components(separatedBy: "\n\n") {
            let para = para.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !para.isEmpty else { continue }
            let tok = NLTokenizer(unit: .sentence)
            tok.string = para
            var sentences: [String] = []
            var start = para.startIndex
            tok.enumerateTokens(in: para.startIndex..<para.endIndex) { range, _ in
                let piece = String(para[start..<range.upperBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty { sentences.append(piece) }
                start = range.upperBound
                return true
            }
            if start < para.endIndex {
                let tail = String(para[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !tail.isEmpty { sentences.append(tail) }
            }
            // Merge a very short sentence forward into the next call.
            var merged: [String] = []
            for s in sentences {
                if let last = merged.last, last.count < 25, last.count + 1 + s.count <= maxChars {
                    merged[merged.count - 1] = last + " " + s
                } else {
                    merged.append(s)
                }
            }
            for (si, sentence) in merged.enumerated() {
                let pieces = splitLong(sentence, maxChars: maxChars)
                for (k, piece) in pieces.enumerated() {
                    let pause = k < pieces.count - 1 ? 0.08
                        : (si == merged.count - 1 ? 0.45 : 0.2)
                    units.append(SpeechUnit(text: piece, pauseAfter: pause))
                }
            }
        }
        return units
    }

    /// Splits an over-long sentence at the last clause break (or space)
    /// within each window — never mid-word, never oversized for the
    /// engine's internal chunker.
    private static func splitLong(_ s: String, maxChars: Int) -> [String] {
        guard s.count > maxChars else { return [s] }
        var out: [String] = []
        var rest = Substring(s)
        while rest.count > maxChars {
            let window = rest.prefix(maxChars)
            let minCut = window.index(window.startIndex, offsetBy: maxChars / 3)
            let clause = window.lastIndex(where: { ",;:—–".contains($0) }).flatMap { $0 >= minCut ? $0 : nil }
            let cut = clause ?? window.lastIndex(of: " ") ?? window.index(before: window.endIndex)
            let end = rest.index(after: cut)
            out.append(String(rest[..<end]).trimmingCharacters(in: .whitespaces))
            rest = rest[end...].drop(while: { $0 == " " })
        }
        if !rest.isEmpty { out.append(String(rest)) }
        return out
    }

    /// Strips the model's baked-in leading/trailing silence (measured
    /// in the hundreds of milliseconds per call — the second half of
    /// the pauses-mid-sentence bug), keeping a `padMs` pad and applying
    /// ~5 ms edge fades so the cut doesn't click.
    ///
    /// - Returns: the trimmed samples; empty when the input is all
    ///   silence.
    static func trimmed(_ x: [Float], sampleRate: Int, threshold: Float = 0.01, padMs: Int = 40) -> [Float] {
        guard let first = x.firstIndex(where: { abs($0) > threshold }),
              let last = x.lastIndex(where: { abs($0) > threshold }) else { return [] }
        let pad = sampleRate * padMs / 1000
        var y = Array(x[max(0, first - pad)...min(x.count - 1, last + pad)])
        let fade = min(sampleRate / 200, y.count / 2)
        for i in 0..<fade {
            let g = Float(i) / Float(fade)
            y[i] *= g
            y[y.count - 1 - i] *= g
        }
        return y
    }

    /// Normalizes extracted text for speech before chunking. Source
    /// text — especially PDFKit `page.string` — carries a hard newline
    /// at every VISUAL line wrap and hyphenated words split across
    /// lines; TTS engines treat a newline as a hard stop, so the voice
    /// drops pitch mid-sentence roughly every line ("breaks in the
    /// audio while reading"). Soft hyphens are stripped, wrapped words
    /// are re-joined, in-sentence newlines collapse to a space, and
    /// PARAGRAPH breaks (blank lines) survive as newlines.
    static func normalizeForSpeech(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "\u{00AD}", with: "")   // soft hyphens
        // Re-join words hyphenated across a line wrap ("concen-\ntrate").
        s = s.replacingOccurrences(of: "([a-zà-ÿ])-[ \\t]*\\n[ \\t]*([a-zà-ÿ])",
                                  with: "$1$2", options: .regularExpression)
        // Preserve paragraph breaks (blank lines) through the collapse.
        s = s.replacingOccurrences(of: "\\n[ \\t]*\\n([ \\t]*\\n)*",
                                  with: "\u{1}", options: .regularExpression)
        // Wrapped lines → single spaces (the mid-sentence hard stops).
        s = s.replacingOccurrences(of: "\\s*\\n\\s*", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\u{1}", with: "\n\n")
        // Collapse runs of spaces/tabs (but keep paragraph newlines).
        s = s.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Synthesizes (or recalls) one page's audio. Cache hits return
    /// immediately; misses synthesize the page's sentence chunks
    /// sequentially and concatenate, holding the silent keep-alive (for
    /// as long as ANY synthesis window is open — overlapping prefetches
    /// used to stop it out from under each other) so a locked screen
    /// can't freeze generation. The cache holds FOUR entries,
    /// FIFO-evicted — the playing page must survive the next pages'
    /// prefetches (a single entry got evicted mid-play, and dictionary
    /// key order is arbitrary, so `keys.first` could evict anything).
    ///
    /// The text is normalized for speech first (wrapped-line newlines
    /// are hard stops to a TTS engine — the mid-sentence "breaks in the
    /// audio"), and a short silent gap is inserted between chunks so
    /// the splice doesn't click.
    ///
    /// - Returns: the page's PCM buffer at the engine's sample rate.
    /// - Throws: when no audio at all was generated.
    private func bufferFor(_ segment: AudiobookSegment, language: String) async throws -> AVAudioPCMBuffer {
        if let cached = cache[segment.text] { return cached }
        // In-flight dedup: the loop and a prefetch of the same page share
        // one render (both used to synthesize the text twice).
        if let existing = inFlight[segment.text] {
            return try await existing.value
        }
        let task = Task<AVAudioPCMBuffer, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.render(segment, language: language)
        }
        inFlight[segment.text] = task
        defer { inFlight[segment.text] = nil }
        do {
            let buffer = try await task.value
            cache[segment.text] = buffer
            cacheOrder.append(segment.text)
            while cacheOrder.count > 4 {
                let oldest = cacheOrder.removeFirst()
                cache.removeValue(forKey: oldest)
            }
            return buffer
        } catch {
            // A failed render must not poison the cache slot for retries.
            cache.removeValue(forKey: segment.text)
            cacheOrder.removeAll { $0 == segment.text }
            throw error
        }
    }

    /// One page's synthesis window. Engines that chunk at sentence level
    /// themselves (Pocket, Paradee — `feedsWholePages`) get the WHOLE
    /// normalized page in one call and keep their own seamless audio
    /// state across their internal chunks; engines with a small internal
    /// chunk cap (Supertonic's 70 chars) instead get sentence-sized
    /// `speechUnits` with per-call edge silence trimmed and explicit
    /// pauses. The keep-alive is refcounted across windows and skipped
    /// entirely while audio is playing (a playing page keeps the process
    /// alive by itself).
    private func render(_ segment: AudiobookSegment, language: String) async throws -> AVAudioPCMBuffer {
        synthWindows += 1
        if synthWindows == 1, !engine.isPlaying { synthKeepAlive.start() }
        defer {
            synthWindows -= 1
            if synthWindows == 0 { synthKeepAlive.stop() }
        }
        var samples: [Float] = []
        var sampleRate = 24_000
        /// Logs and trims one synthesis call's baked edge silence.
        func append(_ raw: [Float], rate: Int, chars: Int) {
            sampleRate = rate
            // Diagnostic: how much silence the model baked into this
            // call's edges (Supertonic measured 342–661 ms lead /
            // 391–713 ms trail — the pauses-mid-sentence culprit).
            let lead = raw.firstIndex(where: { abs($0) > 0.01 }) ?? raw.count
            let trail = raw.count - 1 - (raw.lastIndex(where: { abs($0) > 0.01 }) ?? max(0, raw.count - 1))
            Logger(subsystem: "com.ipodclassic.app", category: "tts").notice(
                "unit chars=\(chars, privacy: .public) lead=\(max(0, lead) * 1000 / max(rate, 1), privacy: .public)ms trail=\(max(0, trail) * 1000 / max(rate, 1), privacy: .public)ms")
            samples.append(contentsOf: Self.trimmed(raw, sampleRate: rate))
        }
        if synthesis.feedsWholePages {
            try Task.checkCancellation()
            let pageText = Self.normalizeForSpeech(segment.text)
            let (raw, rate) = try await synthesize(pageText, language: language)
            append(raw, rate: rate, chars: pageText.count)
        } else {
            for unit in Self.speechUnits(segment.text) {
                try Task.checkCancellation()
                let (raw, rate) = try await synthesize(unit.text, language: language)
                append(raw, rate: rate, chars: unit.text.count)
                samples.append(contentsOf: [Float](repeating: 0, count: Int(unit.pauseAfter * Double(rate))))
            }
        }
        guard !samples.isEmpty else {
            throw CocoaError(.coderInvalidValue, userInfo: [NSLocalizedDescriptionKey: "no audio generated"])
        }
        return Self.makeBuffer(samples, sampleRate: sampleRate)
    }

    /// One chunk through the backend. The first call ensures the
    /// pipeline, labeling the wait from the isReady seam (cached engine
    /// → "Preparing voices…", uncached → "Downloading").
    ///
    /// - Returns: the chunk's samples and sample rate.
    /// - Throws: engine prep/synthesis errors (user-meaningful).
    private func synthesize(_ text: String, language: String) async throws -> (samples: [Float], sampleRate: Int) {
        if !pipelineReady {
            // A cached engine must not show a bogus "Downloading" label
            // (and a download Live Activity) on every launch — the store
            // probes disk at init and reports readiness through the
            // seam. Only a genuinely uncached load is a download, and
            // the store mirrors THAT to the Live Activity itself.
            state = synthesis.isReady ? .loading : .downloading
        }
        do {
            try await synthesis.ensureReady()
        } catch {
            Logger(subsystem: "com.ipodclassic.app", category: "tts")
                .notice("engine prep failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription.isEmpty ? "Engine failed to load" : error.localizedDescription)
            throw error
        }
        if !pipelineReady {
            pipelineReady = true
            if state == .loading || state == .downloading { state = .playing }
        }
        return try await synthesis.synthesize(text, language: language, voiceName: currentVoice)
    }

    // MARK: Audio

    /// Copies samples into a mono float PCM buffer at `sampleRate`.
    ///
    /// - Returns: a buffer sized exactly to the samples.
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
        /// Writes one stage to qa_status.txt (overwrite, one line) and
        /// logs it — device QA reads the file without a debugger.
        func stage(_ s: String) {
            FileManager.default.createFile(atPath: status.path, contents: Data(s.utf8))
            Logger(subsystem: "com.ipodclassic.app", category: "tts").notice("STAGE \(s, privacy: .public)")
        }
        do {
            stage("download-start")
            // Keep the screen awake and the process runnable for the
            // whole run: a locked phone suspends the download and it
            // stalls silently.
            UIApplication.shared.isIdleTimerDisabled = true
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            let keepAlive = SilentKeepAlive()
            keepAlive.start()
            defer { keepAlive.stop() }
            let store = ReadAloudVoiceStore.shared
            _ = try await store.prepare()
            stage("model-ready")
            stage("synth-start")
            let t0 = Date()
            let (samples, sampleRate) = try await store.synthesize(
                text: text, language: AudiobookLanguage.detect(text), voiceName: currentVoice)
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
