import Foundation
import AVFoundation
import UIKit
import FluidAudio
import os

/// One recording's transcription, persisted in a hidden JSON sidecar next
/// to the recordings. `partial` transcripts save as they go, so a killed
/// app never loses what was already transcribed; `failed` entries can be
/// retried from the hold menu.
struct TranscriptEntry: Codable, Equatable {
    var file: String          // recording file name (….m4a)
    var text: String
    var state: String         // "done" | "partial" | "failed"
    var date: Date
    var secondsDone: Double   // audio seconds transcribed so far
    /// The decoder run's global token timings (word → audio position).
    /// Kept in the sidecar so the custom-dictionary pass ("Fix Names")
    /// can re-score an existing transcript against the CTC spotter
    /// without re-listening. nil for transcripts saved before boosting
    /// existed; optional so old sidecars decode unchanged.
    var timings: [TokenTiming]? = nil
    /// Whether the custom-dictionary pass ran AND changed the text (nil
    /// = no dictionary was configured, or the run failed early). QA
    /// evidence visible in the sidecar without device logs.
    var boostApplied: Bool? = nil

    /// True only for a transcription that ran to completion; `partial` and
    /// `failed` entries don't count as done.
    var isDone: Bool { state == "done" }

    /// Manual `==`: TokenTiming isn't Equatable, and timing arrays carry
    /// thousands of samples nobody compares field-by-field — entries
    /// count as equal when the transcript fields match and both carry
    /// (or both lack) timings.
    static func == (lhs: TranscriptEntry, rhs: TranscriptEntry) -> Bool {
        lhs.file == rhs.file && lhs.text == rhs.text && lhs.state == rhs.state
            && lhs.date == rhs.date && lhs.secondsDone == rhs.secondsDone
            && (lhs.timings?.count ?? 0) == (rhs.timings?.count ?? 0)
    }
}

/// All transcripts in one hidden JSON sidecar next to the recordings
/// (Documents/Recordings/.transcripts.json). An empty `partial` entry is
/// saved BEFORE a run and the final entry after it, so a killed app never
/// loses its place; deleting a recording removes its entry.
/// Concept: FileManager & sandbox → docs/concepts/filemanager-and-sandbox.md
enum TranscriptStore {
    /// Hidden from the Files app by the leading dot.
    static var url: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Recordings", isDirectory: true)
            .appendingPathComponent(".transcripts.json")
    }

    /// The sidecar lives inside Recordings/; make sure the folder exists so
    /// a fresh install (or erased simulator) can save before the first
    /// recording creates it.
    private static func ensureDirectory() {
        let dir = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Reads and decodes the whole sidecar; a missing or corrupt file means
    /// "no transcripts yet" rather than an error (fresh installs, wiped sims).
    /// - Returns: every persisted entry.
    static func loadAll() -> [TranscriptEntry] {
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([TranscriptEntry].self, from: data) else { return [] }
        return entries
    }

    /// Finds one recording's saved transcript.
    /// - Parameter file: recording file name (the sidecar key, ….m4a).
    /// - Returns: the entry, or nil if this recording was never transcribed.
    static func entry(for file: String) -> TranscriptEntry? {
        loadAll().first { $0.file == file }
    }

    /// Title-bar text for the transcript screen ("Recording 2026-11-10 …").
    static func displayTitle(for file: String) -> String {
        let base = file.replacingOccurrences(of: ".m4a", with: "")
        return base.count > 26 ? "Transcript" : base
    }

    /// Breaks a raw transcript into readable paragraphs: ICU sentence
    /// detection (handles abbreviations like "Dr." correctly), grouped
    /// into `paragraphSentences`-sentence lines, existing paragraph
    /// breaks preserved (so the function is idempotent). Applied when a
    /// transcript is saved; display/share re-apply it so older
    /// single-paragraph transcripts format too.
    static let paragraphSentences = 5

    /// Formats a raw transcript for reading: ICU sentence detection groups
    /// sentences into `paragraphSentences`-per-line paragraphs. Existing
    /// paragraph breaks and already-grouped lines survive, making this
    /// IDEMPOTENT — display and share re-apply it, so transcripts saved
    /// before formatting existed still render formatted.
    /// - Parameter text: raw or previously formatted transcript text.
    /// - Returns: the paragraph-formatted text (input unchanged if empty).
    static func formatParagraphs(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        // Two-level split: \n\n separates paragraphs, \n separates
        // already-formatted lines inside one — re-formatting must keep
        // both stable (idempotency).
        let paragraphBlocks = trimmed.components(separatedBy: "\n\n")
        var out: [String] = []
        for block in paragraphBlocks {
            var lines: [String] = []
            for line in block.components(separatedBy: "\n") {
                let clean = line.trimmingCharacters(in: .whitespaces)
                guard !clean.isEmpty else { continue }
                let sentences = Self.sentences(in: clean)
                guard sentences.count > paragraphSentences else {
                    lines.append(clean)
                    continue
                }
                var i = 0
                while i < sentences.count {
                    let end = min(i + paragraphSentences, sentences.count)
                    lines.append(sentences[i..<end].joined(separator: " "))
                    i = end
                }
            }
            if !lines.isEmpty { out.append(lines.joined(separator: "\n")) }
        }
        return out.joined(separator: "\n\n")
    }

    /// ICU sentence split — locale-aware, abbreviation-aware.
    private static func sentences(in text: String) -> [String] {
        var out: [String] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex,
                                 options: [.bySentences, .localized]) { sub, _, _, _ in
            if let sub {
                let s = sub.trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { out.append(s) }
            }
        }
        return out
    }

    /// Upserts one entry (thread-safe enough: called from the main actor).
    static func save(_ entry: TranscriptEntry) {
        ensureDirectory()
        var all = loadAll()
        if let idx = all.firstIndex(where: { $0.file == entry.file }) {
            all[idx] = entry
        } else {
            all.append(entry)
        }
        if let data = try? JSONEncoder().encode(all) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Drops one recording's entry so deleted memos leave no orphan
    /// transcripts behind.
    /// - Parameter file: recording file name whose entry is removed.
    static func remove(for file: String) {
        ensureDirectory()
        var all = loadAll()
        all.removeAll { $0.file == file }
        if let data = try? JSONEncoder().encode(all) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// Parakeet speech-to-text for voice memos via the FluidAudio CoreML
/// runtime (Parakeet ULTRA, 25 European languages, runs on the Apple
/// Neural Engine). The SDK downloads the model from HuggingFace on
/// first use; transcription is batch but the SDK chunks long audio
/// internally, and the transcript sidecar saves as it goes so a killed
/// app never loses everything.
///
/// Model history: the earlier sherpa-onnx paths were REMOVED — the 0.6b
/// ORT build dequantizes to ~2.4 GB and jetsams on device, and the
/// v3-coreml model mangles Dutch on iOS; Ultra decodes it correctly
/// (a one-time sweep deletes stale v3 cache dirs).
/// Concept: on-device ML → docs/concepts/on-device-ml.md
@Observable
final class TranscriptionManager {
    /// Process-wide instance: the model download and the loaded engine are
    /// far too expensive to duplicate per caller.
    static let shared = TranscriptionManager()
    /// Singleton — use `shared`.
    private init() {}

    /// Lifecycle of the on-device ASR model: not started, downloading
    /// (progress nil = indeterminate), ready, or failed with a reason.
    enum DownloadState: Equatable {
        case notStarted
        case downloading(file: String, progress: Double?) // nil = indeterminate
        case ready
        case failed(String)
    }

    /// Published model state, seeded from a DISK PROBE rather than
    /// `.notStarted` — a cached model must never show "Downloading" (a warm
    /// load reads from disk instantly and stays silent).
    /// Concept: actors & isolation → docs/concepts/swift-actors-and-isolation.md
    @MainActor private(set) var downloadState: DownloadState = TranscriptionManager.hasCachedModels() ? .ready : .notStarted

    /// True when the Parakeet Ultra model is fully cached on disk —
    /// seeds `downloadState` so a cached load never shows "Downloading",
    /// and lets first-run setup skip its download step.
    nonisolated static func hasCachedModels() -> Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .ultra), version: .ultra)
    }

    /// One-time sweep of sherpa-era model caches (superseded by
    /// FluidAudio's own cache) and QA test artifacts.
    nonisolated private static func sweepLegacyCaches() {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        for name in ["ParakeetTDT-v2", "Parakeet110m-v1"] {
            try? fm.removeItem(at: appSupport.appendingPathComponent(name, isDirectory: true))
        }
        try? fm.removeItem(at: appSupport.appendingPathComponent("FluidAudio/Models/parakeet-tdt-0.6b-v3", isDirectory: true))
        // QA artifact from the sherpa-era device test.
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first
        if let docs {
            try? fm.removeItem(at: docs.appendingPathComponent("Recordings/Recording 2026-11-10 22-30-00.m4a"))
        }
    }
    /// Recording file names currently transcribing.
    @MainActor private(set) var transcribing: Set<String> = []

    // MARK: Custom dictionary (CTC vocabulary boosting)

    /// UserDefaults key holding the boost terms.
    private static let dictionaryKey = "transcription.dictionary"

    /// Reads the persisted dictionary (empty on fresh installs).
    private static func loadDictionary() -> [String] {
        (UserDefaults.standard.stringArray(forKey: dictionaryKey) ?? []).filter { !$0.isEmpty }
    }

    /// The user's boost terms — names and jargon the ASR commonly
    /// mishears. Each transcription runs one CTC rescoring pass over the
    /// finished transcript with these; "Fix Names" re-runs it on demand.
    /// Persisted in UserDefaults.
    @MainActor private(set) var dictionaryTerms: [String] = TranscriptionManager.loadDictionary()

    /// Adds a term (trimmed, deduped case-insensitively) and persists it.
    /// - Parameter term: the word or name to boost.
    @MainActor func addDictionaryTerm(_ term: String) {
        let clean = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty,
              !dictionaryTerms.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) else { return }
        dictionaryTerms.append(clean)
        UserDefaults.standard.set(dictionaryTerms, forKey: Self.dictionaryKey)
    }

    /// Removes a term and persists the change.
    /// - Parameter term: the exact stored term.
    @MainActor func removeDictionaryTerm(_ term: String) {
        dictionaryTerms.removeAll { $0 == term }
        UserDefaults.standard.set(dictionaryTerms, forKey: Self.dictionaryKey)
    }

    /// Loaded CTC keyword-spotter models (the dictionary pass's second
    /// model, ~100 MB download once, ~64 MB resident while loaded). Kept
    /// across runs; `ensureVocabularyModels` reloads from disk as needed.
    @MainActor private var ctcModels: CtcModels?

    /// Dictionary-model lifecycle — same states as the ASR download,
    /// seeded from a disk probe so a cached pack never shows
    /// "Downloading" (mirrors `downloadState`).
    @MainActor private(set) var vocabularyModelState: DownloadState =
        TranscriptionManager.hasCachedCTCModels() ? .ready : .notStarted

    /// True when the Parakeet CTC 110M keyword-spotter pack is fully
    /// cached on disk — the custom-dictionary rescoring pass needs it.
    nonisolated static func hasCachedCTCModels() -> Bool {
        CtcModels.modelsExist(at: CtcModels.defaultCacheDirectory(for: .ctc110m))
    }

    /// Loads (downloading first if needed) the CTC models used to
    /// rescore transcripts against the custom dictionary. A cached load
    /// is silent and instant; a real download mirrors its progress into
    /// `vocabularyModelState` (the Custom Dictionary screen shows it).
    @MainActor
    func ensureVocabularyModels() async throws -> CtcModels {
        if let ctcModels { return ctcModels }
        let cached = TranscriptionManager.hasCachedCTCModels()
        if !cached {
            vocabularyModelState = .downloading(file: "dictionary-model", progress: nil)
        }
        do {
            let models = try await CtcModels.downloadAndLoad(variant: .ctc110m, progressHandler: { p in
                Task { @MainActor in
                    self.vocabularyModelState = .downloading(file: "dictionary-model", progress: p.fractionCompleted)
                }
            })
            ctcModels = models
            vocabularyModelState = .ready
            return models
        } catch {
            vocabularyModelState = .failed(error.localizedDescription)
            throw error
        }
    }

    /// Builds a boosting session from the given terms: the session
    /// tokenizes them with the CTC tokenizer and binds the keyword
    /// spotter + rescorer. Cheap enough to rebuild per transcription run
    /// (the models themselves are the expensive part and stay cached).
    /// - Parameters:
    ///   - terms: the user's dictionary words.
    ///   - ctc: the loaded CTC models.
    private func makeBoostSession(terms: [String], ctc: CtcModels) async throws -> VocabularyBoostingSession {
        let vocabulary = CustomVocabularyContext(terms: terms.map { CustomVocabularyTerm(text: $0) })
        return try await VocabularyBoostingSession(vocabulary: vocabulary, ctcModels: ctc)
    }

    /// The boosting pass over a finished transcript, with all bookkeeping:
    /// ensures the CTC models, builds the session, runs the windowed
    /// rescore, and logs. Throwing surfaces download/load failures (the
    /// caller keeps the raw text); a quiet no-result pass just returns
    /// the input.
    /// - Parameters:
    ///   - raw: the transcript text to boost.
    ///   - timings: its global token timings (nil skips boosting).
    ///   - url: the recording, read window-by-window.
    ///   - terms: the dictionary to rescore against.
    /// - Returns: the boosted text (== `raw` when nothing replaced).
    nonisolated private func boostedText(
        raw: String, timings: [TokenTiming]?, url: URL, terms: [String]
    ) async throws -> String {
        guard !terms.isEmpty else { return raw }
        let logger = Logger(subsystem: "com.ipodclassic.app", category: "transcribe")
        logger.notice("BOOST pass over \(raw.count) chars with \(terms.count) dictionary term(s)")
        let ctc = try await ensureVocabularyModels()
        let session = try await makeBoostSession(terms: terms, ctc: ctc)
        let boosted = await TranscriptBoost.boosted(original: raw, timings: timings, url: url, session: session)
        if boosted != raw {
            logger.notice("BOOST applied dictionary replacements (\(terms.count) terms)")
        }
        return boosted
    }

    /// Re-runs ONLY the dictionary rescoring pass over an already-done
    /// transcript ("Fix Names"): the stored token timings tell the
    /// rescorer where every word sits, so no re-listening happens —
    /// typically a few seconds of CTC inference per minute of audio.
    /// The entry keeps its done state; text and date update on success
    /// (no change → the sidecar is left untouched).
    /// - Parameters:
    ///   - file: recording file name (the sidecar key).
    ///   - sourceURL: the recording's audio file.
    @MainActor
    func reboost(file: String, sourceURL: URL) {
        guard transcribing.isEmpty, !dictionaryTerms.isEmpty,
              let entry = TranscriptStore.entry(for: file),
              entry.isDone,
              let timings = entry.timings, !timings.isEmpty,
              FileManager.default.fileExists(atPath: sourceURL.path) else { return }
        transcribing.insert(file)
        LiveActivityManager.shared.transcriptionStarted(file: file)
        let terms = dictionaryTerms
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runReboost(file: file, url: sourceURL, entry: entry,
                                   timings: timings, terms: terms)
        }
    }

    /// Background body of `reboost` — SilentKeepAlive covers a possible
    /// first-time CTC model download; the done transcript is paragraph
    /// formatted, and splicing preserves that formatting, so the result
    /// is only re-formatted (idempotent) before saving.
    nonisolated private func runReboost(
        file: String, url: URL, entry: TranscriptEntry,
        timings: [TokenTiming], terms: [String]
    ) async {
        let keepAlive = SilentKeepAlive()
        keepAlive.start()
        defer { keepAlive.stop() }
        let logger = Logger(subsystem: "com.ipodclassic.app", category: "transcribe")
        logger.notice("REBOOST start \(file, privacy: .public)")
        var text = entry.text
        do {
            text = try await boostedText(raw: entry.text, timings: timings, url: url, terms: terms)
        } catch {
            logger.notice("REBOOST \(file, privacy: .public) model error: \(String(describing: error), privacy: .public)")
        }
        if text != entry.text {
            TranscriptStore.save(TranscriptEntry(
                file: file, text: TranscriptStore.formatParagraphs(text),
                state: entry.state, date: Date(), secondsDone: entry.secondsDone,
                timings: entry.timings))
        }
        logger.notice("REBOOST \(file, privacy: .public) done changed=\(text != entry.text)")
        Task { @MainActor in
            self.transcribing.remove(file)
            LiveActivityManager.shared.transcriptionFinished(file: file, state: "done")
        }
    }


    /// The loaded ASR engine, kept once loaded so later runs are warm
    /// starts (no re-download, no re-compile for the ANE).
    private var asrManager: AsrManager?

    /// Loads (downloading first if needed) the Parakeet Ultra CoreML
    /// models. FluidAudio caches the download; subsequent calls are
    /// instant (the first device load compiles for ANE, ~10 min once).
    /// A real download mirrors to a Live Activity; a cached load is
    /// silent and keeps the state .ready so the UI never says
    /// "Downloading" for work that reads from disk.
    @MainActor
    func ensureModels() async throws -> AsrManager {
        if let asrManager { return asrManager }
        TranscriptionManager.sweepLegacyCaches()
        let cached = TranscriptionManager.hasCachedModels()
        if cached {
            downloadState = .ready
        } else {
            downloadState = .downloading(file: "asr-models", progress: nil)
            LiveActivityManager.shared.downloadStarted()
        }
        do {
            let models = try await AsrModels.downloadAndLoad(version: .ultra, progressHandler: { p in
                let fraction = p.fractionCompleted
                let phase: String
                if case .compiling(let modelName) = p.phase {
                    phase = "Compiling \(modelName)…"
                } else {
                    phase = "Downloading…"
                }
                Task { @MainActor in
                    self.downloadState = .downloading(file: phase, progress: fraction)
                    LiveActivityManager.shared.downloadProgress(fraction)
                }
            })
            let mgr = AsrManager(config: .default)
            try await mgr.loadModels(models)
            asrManager = mgr
            downloadState = .ready
            if !cached {
                LiveActivityManager.shared.downloadFinished(success: true)
            }
            return mgr
        } catch {
            downloadState = .failed(error.localizedDescription)
            if !cached {
                LiveActivityManager.shared.downloadFinished(success: false)
            }
            throw error
        }
    }

    /// Lock-protected cancellation flag shared between the main actor
    /// (`cancel(file:)`) and the detached transcription task, which polls
    /// it. `@unchecked Sendable` is sound here: every field access takes
    /// the lock.
    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        /// Sets the flag (thread-safe).
        func cancel() { lock.lock(); value = true; lock.unlock() }
        /// True once `cancel()` ran (thread-safe read).
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
    /// Live cancel flags keyed by recording file name.
    private var cancelFlags: [String: CancelFlag] = [:]

    /// Transcribes one recording (async, off main). One transcription at
    /// a time — recognition saturates the ANE and the manager is shared.
    @MainActor
    func transcribe(file: String, sourceURL: URL) {
        guard transcribing.isEmpty, FileManager.default.fileExists(atPath: sourceURL.path) else { return }
        let flag = CancelFlag()
        cancelFlags[file] = flag
        transcribing.insert(file)
        TranscriptStore.save(TranscriptEntry(file: file, text: "", state: "partial",
                                             date: Date(), secondsDone: 0))
        LiveActivityManager.shared.transcriptionStarted(file: file)
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runTranscription(file: file, url: sourceURL, cancel: flag)
        }
    }

    /// Transcribes and awaits completion — for App Intents/Shortcuts,
    /// which return the transcript text to the caller.
    @MainActor
    func transcribeAndWait(file: String, sourceURL: URL) async -> String {
        transcribe(file: file, sourceURL: sourceURL)
        while transcribing.contains(file) {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return TranscriptStore.entry(for: file)?.text ?? ""
    }

    /// Cooperatively cancels a running transcription: sets the flag the
    /// background task checks after model load (before decoding starts).
    /// - Parameter file: the recording being transcribed.
    @MainActor
    func cancel(file: String) {
        cancelFlags[file]?.cancel()
    }

    /// Background transcription body, detached from the main actor.
    ///
    /// Holds a `SilentKeepAlive` so the audio background mode keeps the
    /// process alive for the whole run, streams the SDK's chunked progress
    /// (0…1) into the transcription Live Activity, and decodes from the file
    /// URL so audio stays disk-backed (~1.2 MB constant memory — hour-long
    /// memos are safe). The sidecar entry was written before the run (empty
    /// `partial`, by `transcribe`); `finish` writes it again on completion,
    /// and a QA RESULT line (rtf, memory headroom) is logged per run.
    /// - Parameter file: recording file name (the sidecar key).
    /// - Parameter url: the recording's audio file.
    /// - Parameter cancel: flag checked after model load, before decoding.
    /// Concept: async/await → docs/concepts/swift-async-await.md
    nonisolated private func runTranscription(file: String, url: URL, cancel: CancelFlag) async {
        let keepAlive = SilentKeepAlive()
        keepAlive.start()
        defer { keepAlive.stop() }
        let startedAt = Date()
        let logger = Logger(subsystem: "com.ipodclassic.app", category: "transcribe")
        logger.notice("start \(file, privacy: .public)")

        /// Writes the final sidecar entry (done transcripts are
        /// paragraph-formatted first, and carry the token timings so
        /// "Fix Names" can re-boost later), logs the QA RESULT line, then
        /// hops to the main actor to clear bookkeeping and end the Live
        /// Activity.
        func finish(state: String, text: String, seconds: Double, timings: [TokenTiming]?, boostApplied: Bool? = nil) {
            let stored = state == "done" ? TranscriptStore.formatParagraphs(text) : text
            TranscriptStore.save(TranscriptEntry(file: file, text: stored, state: state,
                                                 date: Date(), secondsDone: seconds,
                                                 timings: state == "done" ? timings : nil,
                                                 boostApplied: boostApplied))
            let headroom = os_proc_available_memory() / 1_048_576
            let elapsed = max(1, Date().timeIntervalSince(startedAt))
            let line = "RESULT \(file) state=\(state) chars=\(text.count) sec=\(Int(seconds)) rtf=\(String(format: "%.2f", elapsed / max(1, seconds))) boost=\(boostApplied.map { String($0) } ?? "off") headroomMB=\(Int(headroom))"
            logger.notice("\(line, privacy: .public)")
            Task { @MainActor in
                self.transcribing.remove(file)
                self.cancelFlags[file] = nil
                LiveActivityManager.shared.transcriptionFinished(file: file, state: state)
            }
        }

        do {
            let mgr = try await self.ensureModels()
            if cancel.isCancelled {
                finish(state: "partial", text: TranscriptStore.entry(for: file)?.text ?? "", seconds: 0, timings: nil)
                return
            }
            // Observe the SDK's chunked-decode progress (0…1) for the
            // Live Activity percentage.
            let stream = await mgr.transcriptionProgressStream
            let progressTask = Task {
                for try await fraction in stream {
                    let f = fraction
                    await MainActor.run {
                        LiveActivityManager.shared.transcriptionProgress(file: file, fraction: f)
                    }
                }
            }
            defer { progressTask.cancel() }
            // URL-based transcription: large files decode disk-backed with
            // ~1.2 MB constant memory, so hour-long memos are safe.
            var decoderState = TdtDecoderState.make()
            let result = try await mgr.transcribe(url, decoderState: &decoderState)
            let raw = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Custom dictionary: one post-transcription rescoring pass
            // (CTC keyword spotter vs. the user's terms). Best-effort —
            // a download or load failure keeps the raw transcript.
            let terms = await MainActor.run { self.dictionaryTerms }
            var text = raw
            var boostApplied: Bool? = nil
            if !terms.isEmpty {
                let boosted = (try? await boostedText(raw: raw, timings: result.tokenTimings,
                                                     url: url, terms: terms)) ?? raw
                text = boosted
                boostApplied = boosted != raw
            }
            let seconds = TranscriptStore.entry(for: file).map { entry in
                max(entry.secondsDone, 0)
            } ?? 0
            let duration = (try? AVAudioFile(forReading: url)).map {
                Double($0.length) / $0.processingFormat.sampleRate
            } ?? seconds
            finish(state: "done", text: text, seconds: duration, timings: result.tokenTimings,
                   boostApplied: boostApplied)
        } catch {
            let msg = String(describing: error)
            logger.notice("ERROR \(file, privacy: .public): \(msg, privacy: .public)")
            finish(state: "failed", text: "", seconds: 0, timings: nil)
        }
    }
}

/// Keeps the process alive during long transcriptions: plays a silent
/// loop under the app's active .playback audio session (the app already
/// activates one at launch), so iOS's `audio` background mode never
/// suspends us mid-transcription.
final class SilentKeepAlive {
    private var player: AVAudioPlayer?

    /// Starts the keep-alive: writes a 1-second silent .caf to the temp
    /// directory once (8 kHz mono — tiny), then loops it at volume 0.01
    /// under the app's active .playback session.
    func start() {
        guard player == nil else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("silence.caf")
        if !FileManager.default.fileExists(atPath: url.path) {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 8_000,
                                       channels: 1, interleaved: false)!
            guard let file = try? AVAudioFile(forWriting: url, settings: format.settings) else { return }
            if let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000) {
                buf.frameLength = 8_000
                try? file.write(from: buf)
            }
        }
        player = try? AVAudioPlayer(contentsOf: url)
        player?.numberOfLoops = -1
        player?.volume = 0.01
        player?.play()
    }

    /// Stops the loop and releases the player — the process may sleep again.
    func stop() {
        player?.stop()
        player = nil
    }
}
