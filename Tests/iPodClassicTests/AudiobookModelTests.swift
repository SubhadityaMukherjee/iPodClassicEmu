import AVFoundation
import XCTest
@testable import iPodClassic

/// Audiobook mode state machine: playback order, page sync, seek on wheel,
/// chapter advance, book end, pause/resume, and the language heuristic.
/// The audio backend is a controllable mock so no AVAudioEngine runs.
@MainActor
final class AudiobookModelTests: XCTestCase {

    // MARK: Mocks

    /// Always "ready"; distinct frame counts per text so assertions can
    /// tell buffers apart.
    private final class MockSynth: AudiobookSynthesizerType {
        private(set) var synthesized: [String] = []
        var isReady: Bool { true }
        func ensureReady() async throws {}
        func synthesize(_ text: String, language: String, voiceName: String) async throws -> (samples: [Float], sampleRate: Int) {
            synthesized.append(text)
            return (Array(repeating: Float(0.1), count: max(8, text.count * 2)), 24_000)
        }
    }

    /// Pages render until `finishPage()` marks the current one done —
    /// the loop polls isPlaying, exactly like the real AVAudioPlayer.
    private final class MockEngine: AudiobookAudioEngineType {
        var rate: Float = 1
        var outputVolume: Float = 1
        var onDebug: ((String) -> Void)?
        private(set) var played: [Int] = []      // frame lengths per play
        private(set) var pauseCount = 0
        private(set) var stopSeeks: [Bool] = []
        private(set) var stopCount = 0
        private(set) var playing = false
        private(set) var interrupted = false

        func ensureStarted() throws {}

        func start(_ buffer: AVAudioPCMBuffer) -> Bool {
            played.append(Int(buffer.frameLength))
            playing = true
            return true
        }

        var isPlaying: Bool { playing }
        /// Non-zero so the loop's "audio actually rendered" guard passes.
        var fakePlaybackSeconds: Double = 30
        var playbackSeconds: Double { fakePlaybackSeconds }
        var seekRequested: Bool {
            get { interrupted }
            set { interrupted = newValue }
        }

        /// Marks the current page finished (natural end).
        func finishPage() {
            playing = false
        }

        /// Marks the page dead (never rendered).
        func killPage() {
            playing = false
        }

        func pause() {
            pauseCount += 1
            playing = false
        }

        func resume() {
            playing = true
        }

        func stopPlayback() {
            stopCount += 1
            playing = false
        }
    }

    /// Mutable fake of the book screen's provider side.
    private final class FakeProvider {
        var chapters: [[AudiobookSegment]]
        var chapter = 0
        var shownPage = 0

        init(chapters: [[AudiobookSegment]]) {
            self.chapters = chapters
        }

        func provider() -> AudiobookPageProvider {
            AudiobookPageProvider(
                segments: { [unowned self] in
                    chapters.indices.contains(chapter) ? chapters[chapter] : []
                },
                showPage: { [unowned self] in shownPage = $0 },
                currentPage: { [unowned self] in shownPage },
                stepChapter: { [unowned self] delta in
                    let next = chapter + delta
                    guard chapters.indices.contains(next) else { return false }
                    chapter = next
                    shownPage = 0
                    return true
                },
                language: { "en" }
            )
        }
    }

    private func seg(_ page: Int, _ text: String) -> AudiobookSegment {
        AudiobookSegment(page: page, text: text)
    }

    private func makeModel(_ engine: MockEngine, _ box: FakeProvider) -> AudiobookModel {
        let model = AudiobookModel(engine: engine, synthesis: MockSynth())
        model.start(provider: box.provider())
        return model
    }

    private func waitUntil(
        _ condition: @escaping () -> Bool, timeout: TimeInterval = 5, _ message: String = ""
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting: \(message)")
    }

    // MARK: Playback order + page sync

    func testPlaysSegmentsInOrderAndAdvancesChaptersToEnd() async throws {
        let engine = MockEngine()
        let box = FakeProvider(chapters: [
            [seg(0, "One sentence."), seg(1, "Two sentence."), seg(2, "Three sentence.")],
            [seg(0, "Chapter two sentence.")],
        ])
        let model = makeModel(engine, box)
        try await waitUntil({ model.state == .playing }, "loop started")

        // Page 0 first; the reader follows the spoken page.
        try await waitUntil({ engine.played.count == 1 }, "first play")
        XCTAssertEqual(box.shownPage, 0)
        engine.finishPage()

        try await waitUntil({ engine.played.count == 2 }, "second play")
        XCTAssertEqual(box.shownPage, 1)
        engine.finishPage()

        try await waitUntil({ engine.played.count == 3 }, "third play")
        XCTAssertEqual(box.shownPage, 2)
        engine.finishPage()

        // Chapter walked forward, its first page spoken, then book end → idle.
        try await waitUntil({ engine.played.count == 4 }, "chapter two play")
        XCTAssertEqual(box.chapter, 1)
        engine.finishPage()

        try await waitUntil({ model.state == .idle }, "book end")
        XCTAssertEqual(box.chapter, 2 - 1) // stayed on last chapter
        XCTAssertFalse(engine.played.contains(0))
    }

    func testEmptyChapterSkipsForward() async throws {
        let engine = MockEngine()
        let box = FakeProvider(chapters: [
            [],                       // blank chapter (image-only span)
            [seg(0, "Real sentence text.")],
        ])
        let model = makeModel(engine, box)
        try await waitUntil({ engine.played.count == 1 }, "skipped to chapter 1")
        XCTAssertEqual(box.chapter, 1)
        model.stop()
    }

    func testPauseResumeDoesNotStopLoop() async throws {
        let engine = MockEngine()
        let box = FakeProvider(chapters: [[seg(0, "A sentence."), seg(1, "B sentence.")]])
        let model = makeModel(engine, box)
        try await waitUntil({ engine.played.count == 1 }, "playing")

        model.togglePlayPause()
        XCTAssertEqual(model.state, .paused)
        XCTAssertEqual(engine.pauseCount, 1)

        model.togglePlayPause()
        XCTAssertEqual(model.state, .playing)
        model.stop()
    }

    // MARK: Seek (wheel while reading aloud)

    func testWheelSeekJumpsToShownPage() async throws {
        let engine = MockEngine()
        let box = FakeProvider(chapters: [[seg(0, "A sentence."), seg(1, "B sentence."), seg(2, "C sentence.")]])
        let model = makeModel(engine, box)
        try await waitUntil({ engine.played.count == 1 }, "playing page 0")

        // Wheel scrolls to the last page while the buffer is playing.
        box.shownPage = 2
        model.readerMoved()
        XCTAssertEqual(engine.interrupted, true)

        // The poll loop sees the seek request; the loop re-syncs to p2.
        try await waitUntil({ engine.played.count == 2 }, "resynced play")
        XCTAssertEqual(box.shownPage, 2)
        model.stop()
    }

    func testNoRenderedAudioFailsInsteadOfSkipping() async throws {
        var engine = MockEngine()
        engine.fakePlaybackSeconds = 0 // backend plays nothing
        let box = FakeProvider(chapters: [[seg(0, "A sentence."), seg(1, "B sentence.")]])
        let model = AudiobookModel(engine: engine, synthesis: MockSynth())
        model.start(provider: box.provider())
        try await waitUntil({ engine.played.count == 1 }, "first play")
        engine.killPage() // "ends" without ever rendering
        try await waitUntil({ model.state == .failed("Audio playback failed") }, "guard trips")
        // It must not have raced ahead to the next page.
        XCTAssertEqual(engine.played.count, 1)
        model.stop()
        _ = engine // silence unused-mutable warning
    }

    func testStopExitsToIdle() async throws {        let engine = MockEngine()
        let box = FakeProvider(chapters: [[seg(0, "A sentence.")]])
        let model = makeModel(engine, box)
        try await waitUntil({ engine.played.count == 1 }, "playing")
        model.stop()
        XCTAssertEqual(model.state, .idle)
        try await waitUntil({ engine.played.count == 1 }, "no further plays after stop")
    }

    // MARK: Settings cycling

    func testSpeedCyclesWrapAround() {
        let model = AudiobookModel(engine: MockEngine(), synthesis: MockSynth())
        model.speedIndex = AudiobookModel.speeds.count - 1
        model.speedIndex += 1
        XCTAssertEqual(model.speedIndex, 0)
        model.speedIndex -= 1
        XCTAssertEqual(model.speedIndex, AudiobookModel.speeds.count - 1)
        XCTAssertEqual(model.speedLabel, "2×")
    }

    func testVoiceCyclesWrapAround() {
        let model = AudiobookModel(engine: MockEngine(), synthesis: MockSynth())
        model.voiceIndex = 0
        let first = model.voiceLabel
        model.voiceIndex = AudiobookModel.voiceCount - 1
        model.voiceIndex += 1
        XCTAssertEqual(model.voiceIndex, 0)
        XCTAssertEqual(model.voiceLabel, first)
        model.voiceIndex -= 1
        XCTAssertEqual(model.voiceIndex, AudiobookModel.voiceCount - 1)
    }

    func testSpeedIndexAppliesRateToEngine() {
        let model = AudiobookModel(engine: MockEngine(), synthesis: MockSynth())
        model.speedIndex = 3 // 1.5×
        XCTAssertEqual(model.rate, 1.5, accuracy: 0.001)
    }

    func testVolumeCyclesWrapAroundAndAppliesToEngine() {
        let engine = MockEngine()
        let model = AudiobookModel(engine: engine, synthesis: MockSynth())
        model.volumeIndex = AudiobookModel.volumes.count - 1
        model.volumeIndex += 1
        XCTAssertEqual(model.volumeIndex, 0)
        XCTAssertEqual(model.volumeLabel, "10%")
        model.volumeIndex -= 1
        XCTAssertEqual(model.volumeIndex, AudiobookModel.volumes.count - 1)
        XCTAssertEqual(model.volumeLabel, "100%")
        model.volumeIndex = 2 // 50%
        XCTAssertEqual(engine.outputVolume, 0.5, accuracy: 0.001)
    }

    // MARK: Sentence chunking (long-page synthesis)

    func testSentenceChunksShortTextStaysWhole() {
        let text = "One two three. Four five six."
        XCTAssertEqual(AudiobookModel.sentenceChunks(text), [text])
    }

    func testSentenceChunksSplitsLongTextOnSentenceBoundariesOnly() {
        let sentence = "The quick brown fox jumps over the lazy dog. "
        let text = String(repeating: sentence, count: 20) // ~900 chars
        let chunks = AudiobookModel.sentenceChunks(text, limit: 200)
        XCTAssertGreaterThan(chunks.count, 1)
        // Reassembly is lossless — no dropped sentences (paragraph-edge
        // whitespace is trimmed; content is exact).
        XCTAssertEqual(chunks.joined(), text.trimmingCharacters(in: .whitespacesAndNewlines))
        // Every break is at a sentence boundary. NLTokenizer sentence
        // tokens carry the trailing separator whitespace, so a chunk
        // STARTS cleanly at "The quick…" (never mid-sentence).
        for chunk in chunks.dropFirst() {
            XCTAssertTrue(chunk.hasPrefix("The quick"), "chunk started mid-sentence: \(chunk.prefix(30))")
        }
    }

    /// NO chunk may ever contain a newline — the engine reads "\n" as a
    /// hard stop and breaks prosody mid-flow ("sanitize these line
    /// breaks before hand"). Paragraph breaks end chunks instead.
    func testSentenceChunksNeverContainNewlines() {
        let paras = [
            String(repeating: "A paragraph sentence here. ", count: 8),
            String(repeating: "Second paragraph text follows. ", count: 8),
        ].joined(separator: "\n\n")
        let chunks = AudiobookModel.sentenceChunks(paras, limit: 150)
        XCTAssertGreaterThan(chunks.count, 2)
        for chunk in chunks {
            XCTAssertFalse(chunk.contains("\n"), "chunk carried a newline to the engine: \(chunk.prefix(40))…")
        }
        // Paragraph breaks are hard boundaries: no chunk spans both.
        XCTAssertFalse(chunks.contains { $0.contains("A paragraph") && $0.contains("Second paragraph") })
        // And nothing was dropped: every sentence survived.
        XCTAssertTrue(chunks.contains { $0.contains("A paragraph sentence here.") })
        XCTAssertTrue(chunks.contains { $0.contains("Second paragraph text follows.") })
    }

    /// Short pages strip newlines too (the early-return path).
    func testShortChunkAlsoStripsNewlines() {
        XCTAssertEqual(AudiobookModel.sentenceChunks("One line\nand another"),
                       ["One line and another"])
    }

    /// NLTokenizer knows "Mr."/"Dr." are not sentence ends — the old
    /// regex split chunks right after abbreviations and the voice
    /// dropped to end-of-sentence intonation mid-sentence.
    func testSentenceChunksDoesNotBreakAfterAbbreviations() {
        let text = "Mr. Smith arrived at Dr. Jones' office. He waited."
        let chunks = AudiobookModel.sentenceChunks(text, limit: 20)
        XCTAssertFalse(chunks.contains("Mr."), "chunk ended right after 'Mr.': \(chunks)")
        XCTAssertFalse(chunks.contains { $0.hasSuffix("Dr.") }, "chunk ended right after 'Dr.': \(chunks)")
        XCTAssertEqual(chunks.joined(), text)
    }

    /// A single sentence longer than the limit is split at WORD
    /// boundaries under the limit — never left oversized (an oversized
    /// synthesis call truncates its tail = whole words vanish) and
    /// never split mid-word.
    func testSentenceChunksSplitsOversizedSentenceAtWordBoundaries() {
        let text = String(repeating: "word ", count: 200) // 1000 chars, no terminators
        let chunks = AudiobookModel.sentenceChunks(text, limit: 100)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.joined(), text.trimmingCharacters(in: .whitespacesAndNewlines),
                       "reassembly must be lossless")
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.count, 101, "oversized chunk left intact: \(chunk.count)")
            XCTAssertFalse(chunk.hasSuffix("wo") && !chunk.hasSuffix("word "),
                           "split mid-word: …\(chunk.suffix(10))")
        }
    }

    // MARK: Speech normalization (wrapped lines are hard stops to TTS)

    func testNormalizeForSpeechJoinsWrappedLines() {
        let pdfLineWrapped = "The quick brown\nfox jumps over\nthe lazy dog."
        XCTAssertEqual(AudiobookModel.normalizeForSpeech(pdfLineWrapped),
                       "The quick brown fox jumps over the lazy dog.")
    }

    func testNormalizeForSpeechRejoinsHyphenatedWords() {
        XCTAssertEqual(AudiobookModel.normalizeForSpeech("the concen-\ntration of"),
                       "the concentration of")
    }

    func testNormalizeForSpeechPreservesParagraphBreaks() {
        XCTAssertEqual(AudiobookModel.normalizeForSpeech("First para.\n\nSecond para.\n\n\nThird."),
                       "First para.\n\nSecond para.\n\nThird.")
    }

    func testNormalizeForSpeechStripsSoftHyphensAndSpaceRuns() {
        XCTAssertEqual(AudiobookModel.normalizeForSpeech("be\u{00AD}autiful   wide     spaces"),
                       "beautiful wide spaces")
    }

    /// The synthesized text must be normalized first — a hard newline
    /// in a chunk makes the engine stop mid-sentence (PDFKit page.string
    /// wraps every visual line).
    func testSynthesisReceivesNormalizedText() async {
        let synth = MockSynth()
        let model = AudiobookModel(engine: MockEngine(), synthesis: synth)
        let wrapped = Array(repeating: "A wrapped line of text\n", count: 30).joined()
        let provider = FakeProvider(chapters: [[AudiobookSegment(page: 0, text: wrapped)]])
        model.start(provider: provider.provider())
        // Wait for the (mock) engine to synthesize, then stop the session.
        var synthesized = false
        for _ in 0..<150 {
            if !synth.synthesized.isEmpty { synthesized = true; break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        model.stop()
        XCTAssertTrue(synthesized, "synthesis never ran")
        for chunk in synth.synthesized {
            XCTAssertFalse(chunk.contains("\n"), "chunk carried a hard newline to the engine: \(chunk.prefix(40))…")
        }
    }

    // MARK: Reader-echo guard

    /// A delayed page-settling callback reporting the page the loop is
    /// ALREADY speaking must not interrupt it — that same-page echo
    /// restarted pages mid-sentence (audible break + repeat).
    func testSamePageReaderEchoIsIgnored() async {
        let engine = MockEngine()
        let model = AudiobookModel(engine: engine, synthesis: MockSynth())
        let provider = FakeProvider(chapters: [[AudiobookSegment(page: 3, text: "Page three's spoken text.")]])
        model.start(provider: provider.provider())
        // Wait until the loop is playing page 3.
        for _ in 0..<200 {
            if engine.playing, model.page == 3 { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(engine.playing, "loop never started playing")
        let stopsBefore = engine.stopCount

        model.readerMoved(to: 3)   // echo of our own page turn
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(engine.stopCount, stopsBefore, "same-page echo interrupted playback")
        XCTAssertFalse(engine.seekRequested, "same-page echo raised a seek flag")

        model.readerMoved(to: 4)   // a genuine move still seeks
        XCTAssertTrue(engine.seekRequested, "genuine page move must seek")
        model.stop()
    }

    /// Straddling sentences move wholly into the segment where they
    /// start — page buckets must not cut sentences into separate
    /// syntheses ("was <break> overwhelmed").
    func testSentenceAlignedMovesStraddlers() {
        let segs = [
            AudiobookSegment(page: 0, text: "When once he descended was"),
            AudiobookSegment(page: 1, text: "overwhelmed by tree-trunks. Whilst assisting them he was beguiled by"),
            AudiobookSegment(page: 2, text: "them. Later the story continues. And ends."),
        ]
        let out = AudiobookModel.sentenceAligned(segs)
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out[0].text, "When once he descended was overwhelmed by tree-trunks.")
        XCTAssertEqual(out[1].text, "Whilst assisting them he was beguiled by them.")
        XCTAssertEqual(out[2].text, "Later the story continues. And ends.")
        // No mid-sentence segment tails except possibly the last.
        for seg in out.dropLast() {
            XCTAssertTrue(seg.text.hasSuffix("."), "segment ended mid-sentence: \(seg.text.suffix(30))")
        }
    }

    /// Already sentence-aligned segments pass through unchanged.
    func testSentenceAlignedIsNoOpForCleanBoundaries() {
        let segs = [
            AudiobookSegment(page: 0, text: "First full sentence."),
            AudiobookSegment(page: 1, text: "Second full sentence."),
        ]
        XCTAssertEqual(AudiobookModel.sentenceAligned(segs).map(\.text), segs.map(\.text))
    }

    /// A segment that empties out (everything moved to its predecessor)
    /// is dropped, not spoken as a silent page.
    func testSentenceAlignedDropsEmptiedSegments() {
        let segs = [
            AudiobookSegment(page: 0, text: "A sentence that runs over the page"),
            AudiobookSegment(page: 1, text: "edge entirely."),
            AudiobookSegment(page: 2, text: "Next page starts here."),
        ]
        let out = AudiobookModel.sentenceAligned(segs)
        XCTAssertEqual(out.map(\.page), [0, 2])
        XCTAssertEqual(out[0].text, "A sentence that runs over the page edge entirely.")
    }

    // MARK: Language heuristic

    func testLanguageDetection() {        let english = "The quick brown fox jumps over the lazy dog and then rests with his friends in the shade of the old tree."
        let dutch = "De hond rent door het park en de kinderen spelen met de bal in het groene gras voor het huis van hun oma."
        let german = "Der Hund läuft durch den Park und die Kinder spielen mit dem Ball auf dem grünen Rasen vor dem Haus."
        XCTAssertEqual(AudiobookLanguage.detect(english), "en")
        XCTAssertEqual(AudiobookLanguage.detect(dutch), "nl")
        XCTAssertEqual(AudiobookLanguage.detect(german), "de")
        // Too short to judge — default English.
        XCTAssertEqual(AudiobookLanguage.detect("Hello."), "en")
        // Numbers/names only — default English.
        XCTAssertEqual(AudiobookLanguage.detect("Chapter 12 page 47 1888 23 91 44"), "en")
    }
}
