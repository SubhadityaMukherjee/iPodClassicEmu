import XCTest
@testable import iPodClassic

/// Transcript sidecar persistence + text join helpers.
final class TranscriptStoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        try? FileManager.default.removeItem(at: TranscriptStore.url)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: TranscriptStore.url)
        super.tearDown()
    }

    private let entry = TranscriptEntry(
        file: "Recording 2026-01-02 03-04-05.m4a", text: "hello world",
        state: "done", date: Date(timeIntervalSince1970: 100), secondsDone: 12)

    func testSaveLoadRoundtrip() {
        TranscriptStore.save(entry)
        let loaded = TranscriptStore.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].file, entry.file)
        XCTAssertEqual(loaded[0].text, "hello world")
        XCTAssertEqual(loaded[0].state, "done")
        XCTAssertEqual(TranscriptStore.entry(for: entry.file)?.text, "hello world")
    }

    func testUpsertReplacesByFile() {
        TranscriptStore.save(entry)
        var updated = entry
        updated.text = "updated text"
        updated.state = "partial"
        updated.secondsDone = 30
        TranscriptStore.save(updated)
        let all = TranscriptStore.loadAll()
        XCTAssertEqual(all.count, 1, "upsert must not duplicate")
        XCTAssertEqual(all[0].text, "updated text")
        XCTAssertEqual(all[0].state, "partial")
    }

    func testRemove() {
        TranscriptStore.save(entry)
        TranscriptStore.save(TranscriptEntry(file: "other.m4a", text: "x",
                                             state: "done", date: Date(), secondsDone: 1))
        TranscriptStore.remove(for: entry.file)
        XCTAssertNil(TranscriptStore.entry(for: entry.file))
        XCTAssertEqual(TranscriptStore.loadAll().count, 1)
    }

    func testDisplayTitle() {
        XCTAssertEqual(TranscriptStore.displayTitle(for: "Recording 2026-01-02.m4a"),
                       "Recording 2026-01-02")
        XCTAssertTrue(TranscriptStore.displayTitle(for: String(repeating: "x", count: 40)).count <= 26)
    }
}
