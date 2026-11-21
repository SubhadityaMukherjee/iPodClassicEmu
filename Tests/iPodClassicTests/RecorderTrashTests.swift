import XCTest
import AVFoundation
@testable import iPodClassic

/// Recently Deleted for recordings: trash moves the file into
/// Recordings/.trash and KEEPS its transcript sidecar entry; restore
/// brings both back (re-keying the entry when the name is uniquified);
/// delete forever removes both. Runs against real files in the test
/// runner's own Documents sandbox.
final class RecorderTrashTests: XCTestCase {
    private var recorder: RecorderModel!

    override func setUp() {
        super.setUp()
        recorder = RecorderModel()
        clean()
    }

    override func tearDown() {
        clean()
        super.tearDown()
    }

    /// Removes every QA-prefixed file (both folders — including the
    /// " 2"/" 3" suffixes earlier runs may have left behind) plus their
    /// sidecar entries, so tests always start and leave clean.
    private func clean() {
        let fm = FileManager.default
        for dir in [recorder.recordingsURL, recorder.trashURL] {
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.lastPathComponent.hasPrefix("QA Trash") {
                try? fm.removeItem(at: file)
                TranscriptStore.remove(for: file.lastPathComponent)
            }
        }
    }

    /// Writes a tiny real .m4a (AAC — the same settings the recorder
    /// itself uses) with a done sidecar entry, as if it had been
    /// recorded and transcribed.
    @discardableResult
    private func writeMemo(_ name: String, trashed: Bool = false) -> RecordingFile {
        let dir = trashed ? recorder.trashURL : recorder.recordingsURL
        let url = dir.appendingPathComponent(name).appendingPathExtension("m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.low.rawValue,
        ]
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 44_100, channels: 1, interleaved: false)!
        let file = try! AVAudioFile(forWriting: url, settings: settings)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22_050)!
        buf.frameLength = 22_050
        try! file.write(from: buf)
        TranscriptStore.save(TranscriptEntry(file: url.lastPathComponent, text: "hello from \(name)",
                                             state: "done", date: Date(), secondsDone: 0.5))
        recorder.loadRecordings()
        recorder.loadTrash()
        return RecordingFile(url: url, name: name, duration: 0.5, date: Date())
    }

    /// The runner shares the app's Documents sandbox, so real memos may
    /// sit alongside the QA files — every assertion filters to the
    /// QA-prefixed names instead of counting the whole folder.
    private func qaRecordings() -> [RecordingFile] {
        recorder.recordings.filter { $0.name.hasPrefix("QA Trash") }
    }

    private func qaTrash() -> [RecordingFile] {
        recorder.trash.filter { $0.name.hasPrefix("QA Trash") }
    }

    func testTrashMovesFileAndKeepsTranscript() {
        let memo = writeMemo("QA Trash A")
        recorder.trash(memo)
        XCTAssertFalse(FileManager.default.fileExists(atPath: memo.url.path),
                       "the memo leaves the recordings folder")
        XCTAssertTrue(qaRecordings().isEmpty)
        XCTAssertEqual(qaTrash().count, 1)
        XCTAssertEqual(qaTrash().first?.name, "QA Trash A")
        XCTAssertNotNil(TranscriptStore.entry(for: "QA Trash A.m4a"),
                        "the sidecar entry survives so a restore brings the transcript back")
    }

    func testRestoreBringsBackFileAndTranscript() {
        let memo = writeMemo("QA Trash A")
        recorder.trash(memo)
        let trashed = qaTrash()[0]
        recorder.restore(trashed)
        XCTAssertEqual(qaRecordings().count, 1)
        XCTAssertTrue(qaTrash().isEmpty)
        XCTAssertEqual(qaRecordings().first?.name, "QA Trash A")
        XCTAssertEqual(TranscriptStore.entry(for: "QA Trash A.m4a")?.text, "hello from QA Trash A")
    }

    func testRestoreUniquifiesAndRekeysTranscript() {
        writeMemo("QA Trash A")
        let memo = writeMemo("QA Trash B")
        recorder.trash(memo)
        // Restoring while "QA Trash B" now exists in Recordings (nothing
        // exists here, so force the clash by writing a live copy first).
        _ = writeMemo("QA Trash B")
        recorder.restore(qaTrash()[0])
        let restored = qaRecordings().first { $0.name == "QA Trash B 2" }
        XCTAssertNotNil(restored, "the clash forces the uniquified name")
        XCTAssertEqual(TranscriptStore.entry(for: "QA Trash B 2.m4a")?.text, "hello from QA Trash B",
                       "the sidecar entry is re-keyed to the restored name")
        XCTAssertNil(TranscriptStore.entry(for: "QA Trash B.m4a"),
                     "the old sidecar key is gone — no duplicate entries")
    }

    func testDeleteForeverRemovesFileAndTranscript() {
        let memo = writeMemo("QA Trash A")
        recorder.trash(memo)
        recorder.deleteForever(qaTrash()[0])
        XCTAssertTrue(qaTrash().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: recorder.trashURL.appendingPathComponent("QA Trash A.m4a").path))
        XCTAssertNil(TranscriptStore.entry(for: "QA Trash A.m4a"),
                     "delete forever is the only step that drops the transcript")
    }

    func testTrashFallsBackToSuffixOnNameClash() {
        let memo = writeMemo("QA Trash A")
        recorder.trash(memo)
        // Another memo with the same name gets trashed too — the first
        // one must not be overwritten.
        let second = writeMemo("QA Trash A")
        recorder.trash(second)
        XCTAssertEqual(qaTrash().count, 2)
        let names = Set(qaTrash().map(\.name))
        XCTAssertEqual(names, ["QA Trash A", "QA Trash A 2"])
    }
}
