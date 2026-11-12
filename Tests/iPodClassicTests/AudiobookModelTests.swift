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
        func ensureReady() async throws {}
        func synthesize(_ text: String, language: String, voiceName: String) async throws -> [Float] {
            synthesized.append(text)
            return Array(repeating: Float(0.1), count: max(8, text.count * 2))
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
        private(set) var playing = false
        private(set) var interrupted = false

        func ensureStarted() throws {}

        func start(_ buffer: AVAudioPCMBuffer) -> Bool {
            played.append(Int(buffer.frameLength))
            playing = true
            return true
        }

        var isPlaying: Bool { playing }
        var playbackSeconds: Double { 0 }
        var seekRequested: Bool {
            get { interrupted }
            set { interrupted = newValue }
        }

        /// Marks the current page finished (natural end).
        func finishPage() {
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
            [seg(0, "one"), seg(1, "two"), seg(2, "three")],
            [seg(0, "chapter two")],
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
            [seg(0, "real text")],
        ])
        let model = makeModel(engine, box)
        try await waitUntil({ engine.played.count == 1 }, "skipped to chapter 1")
        XCTAssertEqual(box.chapter, 1)
        model.stop()
    }

    func testPauseResumeDoesNotStopLoop() async throws {
        let engine = MockEngine()
        let box = FakeProvider(chapters: [[seg(0, "a"), seg(1, "b")]])
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
        let box = FakeProvider(chapters: [[seg(0, "a"), seg(1, "b"), seg(2, "c")]])
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

    func testStopExitsToIdle() async throws {
        let engine = MockEngine()
        let box = FakeProvider(chapters: [[seg(0, "a")]])
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

    // MARK: Language heuristic

    func testLanguageDetection() {
        let english = "The quick brown fox jumps over the lazy dog and then rests with his friends in the shade of the old tree."
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
