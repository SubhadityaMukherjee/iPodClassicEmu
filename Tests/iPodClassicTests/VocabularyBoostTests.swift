import XCTest
import AVFoundation
import FluidAudio
@testable import iPodClassic
@testable import FluidAudio  // internal memberwise RescoringResult init

/// Custom-dictionary boosting: token/word alignment, window partitioning,
/// replacement application (punctuation-preserving), the 16 kHz windowed
/// audio reader, and the transcript sidecar's timings decode-compatibility.
/// Pure logic — no CoreML models involved.
final class VocabularyBoostTests: XCTestCase {

    /// Convenience TokenTiming builder (tokenId/confidence don't matter).
    private func tt(_ token: String, _ start: Double, _ end: Double) -> TokenTiming {
        TokenTiming(token: token, tokenId: 0, startTime: start, endTime: end, confidence: 1)
    }

    /// Convenience RescoringResult builder (@testable exposes the
    /// internal memberwise init of the SDK type).
    private func replacement(_ original: String, _ word: String) -> VocabularyRescorer.RescoringResult {
        VocabularyRescorer.RescoringResult(
            originalWord: original, originalScore: 0,
            replacementWord: word, replacementScore: 0,
            shouldReplace: true, reason: "test")
    }

    // MARK: Token grouping

    func testTokenGroupsGroupOnBoundaryMarker() {
        let groups = TranscriptBoost.tokenGroups(from: [
            tt("▁meet", 0, 0.2), tt("ing", 0.2, 0.3), tt("▁with", 0.3, 0.5),
        ])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].word, "meeting")
        XCTAssertEqual(groups[0].tokens, 0..<2)
        XCTAssertEqual(groups[0].start, 0, accuracy: 0.001)
        XCTAssertEqual(groups[0].end, 0.3, accuracy: 0.001)
        XCTAssertEqual(groups[1].word, "with")
        XCTAssertEqual(groups[1].tokens, 2..<3)
    }

    func testTokenGroupsSkipBlankAndPadTokens() {
        let groups = TranscriptBoost.tokenGroups(from: [
            tt("<blank>", 0, 0.1), tt("▁hi", 0.1, 0.2), tt("", 0.2, 0.3), tt("<pad>", 0.3, 0.4),
        ])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].word, "hi")
        XCTAssertEqual(groups[0].tokens, 1..<2)
    }

    func testPunctuationTokenAttachesToCurrentWord() {
        let groups = TranscriptBoost.tokenGroups(from: [
            tt("▁world", 0, 0.2), tt(",", 0.2, 0.25),
        ])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].word, "world,")
    }

    // MARK: Alignment

    func testAlignMatchesWhitespaceWordsPositionally() {
        let text = "meeting with NVIDIA, tomorrow"
        let timings = [
            tt("▁meeting", 0, 0.3), tt("▁with", 0.3, 0.5), tt("▁NVIDIA", 0.5, 0.7), tt(",", 0.7, 0.75), tt("▁tomorrow", 0.75, 1.0),
        ]
        let aligned = TranscriptBoost.align(text: text, timings: timings)
        XCTAssertNotNil(aligned, "decoder text and timing words must align 1:1")
        let (spans, groups) = aligned!
        XCTAssertEqual(spans.count, 4)
        XCTAssertEqual(groups.count, 4)
        XCTAssertEqual(String(text[spans[2].range]), "NVIDIA,")
    }

    func testAlignRejectsMismatchedSequences() {
        // Edited text (an extra word) must refuse to align — boosting
        // never guesses against a foreign transcript.
        let aligned = TranscriptBoost.align(
            text: "an extra word slipped in",
            timings: [tt("▁hello", 0, 0.3)])
        XCTAssertNil(aligned)
    }

    // MARK: Windows

    func testWindowsPartitionWordsByTimeAndRebaseTimings() {
        let text = "aa bb cc dd"
        let spans = TranscriptBoost.wordSpans(in: text)
        let timings = [
            tt("▁aa", 0, 1), tt("▁bb", 100, 101), tt("▁cc", 190, 191), tt("▁dd", 380, 381),
        ]
        let groups = TranscriptBoost.tokenGroups(from: timings)
        let windows = TranscriptBoost.windows(spans: spans, groups: groups, timings: timings, in: text)
        XCTAssertEqual(windows.count, 3, "180 s windows: [aa bb] [cc] [dd]")
        XCTAssertEqual(windows[0].text, "aa bb")
        XCTAssertEqual(windows[1].text, "cc")
        XCTAssertEqual(windows[2].text, "dd")
        // Segment-local clocks: each window's first token starts at zero.
        XCTAssertEqual(windows[0].timings.first?.startTime, 0)
        XCTAssertEqual(windows[1].timings.first?.startTime, 0)
        XCTAssertEqual(windows[1].timings.first?.endTime ?? -1, 1, accuracy: 0.001)
        XCTAssertEqual(windows[2].duration, 1, accuracy: 0.001)
    }

    // MARK: Replacement application

    func testApplyingSingleWordPreservesSurroundingText() {
        let out = TranscriptBoost.applying([replacement("corp", "NVIDIA")],
                                           to: "met with in video corp today")
        XCTAssertEqual(out, "met with in video NVIDIA today")
    }

    func testApplyingMultiWordSpanKeepsEdgePunctuation() {
        let out = TranscriptBoost.applying([replacement("in video", "NVIDIA")],
                                           to: "we met in video, right?")
        XCTAssertEqual(out, "we met NVIDIA, right?", "the comma hugging the span survives")
    }

    func testApplyingIsCaseAndPunctuationInsensitiveInMatching() {
        let out = TranscriptBoost.applying([replacement("In Video", "NVIDIA")],
                                           to: "say IN VIDEO! loud")
        XCTAssertEqual(out, "say NVIDIA! loud")
    }

    func testApplyingRepeatedWordsReplacesFirstUnmatchedOnly() {
        let out = TranscriptBoost.applying([replacement("nvidia", "NVIDIA Corp")],
                                           to: "nvidia then nvidia")
        XCTAssertEqual(out, "NVIDIA Corp then nvidia")
    }

    func testApplyingUnmatchedReplacementReturnsNil() {
        XCTAssertNil(TranscriptBoost.applying([replacement("zebra", "Horse")],
                                              to: "no such word here"),
                     "an unplaceable replacement must fall back, not guess")
    }

    func testApplyingReplacementOverlappingExistingWordReturnsNil() {
        // Two adjacent replacements can't share a word: the second has
        // nothing left to consume.
        let out = TranscriptBoost.applying(
            [replacement("aa bb", "X"), replacement("bb cc", "Y")],
            to: "aa bb cc")
        XCTAssertNil(out)
    }

    // MARK: Audio reader

    func testReaderReturnsWindowedSamplesAt16k() throws {
        // 1 s of 44.1 kHz constant-value samples — a wav, no encoder
        // needed — read back as a 0.3 s window mid-file. The writer goes
        // out of scope before reading so its header is finalized.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("boost-reader-\(UUID().uuidString).wav")
        do {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: 44_100, channels: 1, interleaved: false)!
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
            buf.frameLength = 44_100
            if let ch = buf.floatChannelData?[0] {
                for i in 0..<Int(buf.frameLength) { ch[i] = 0.5 }
            }
            try file.write(from: buf)
        }

        let samples = RecordingAudioReader.samples(from: url, start: 0.2, duration: 0.3)
        XCTAssertEqual(Double(samples.count), 4_800, accuracy: 300,
                       "0.3 s at 16 kHz ≈ 4800 samples")
        let mean = samples.reduce(0, +) / Float(max(1, samples.count))
        XCTAssertEqual(mean, 0.5, accuracy: 0.01, "window content matches the source tone")
        try? FileManager.default.removeItem(at: url)
    }

    func testReaderPastFileEndReturnsEmpty() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("boost-reader-\(UUID().uuidString).wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 16_000, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_000)!
        buf.frameLength = 1_000
        try file.write(from: buf)
        XCTAssertTrue(RecordingAudioReader.samples(from: url, start: 5, duration: 1).isEmpty)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Sidecar compatibility

    func testTranscriptEntryDecodesWithoutTimings() throws {
        // Old sidecars (pre-dictionary) have no timings field.
        let json = #"{"file":"a.m4a","text":"hi","state":"done","date":700000000,"secondsDone":1}"#
        let entry = try JSONDecoder().decode(TranscriptEntry.self, from: Data(json.utf8))
        XCTAssertNil(entry.timings)
        XCTAssertTrue(entry.isDone)
    }

    func testTranscriptEntryTimingsRoundTrip() throws {
        let entry = TranscriptEntry(file: "a.m4a", text: "hi", state: "done",
                                    date: Date(timeIntervalSince1970: 700_000_000),
                                    secondsDone: 1,
                                    timings: [tt("▁hi", 0, 0.3)])
        let data = try JSONEncoder().encode(entry)
        let back = try JSONDecoder().decode(TranscriptEntry.self, from: data)
        XCTAssertEqual(back, entry)
        XCTAssertEqual(back.timings?.first?.token, "▁hi")
    }
}
