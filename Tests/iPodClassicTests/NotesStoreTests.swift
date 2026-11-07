import XCTest
@testable import iPodClassic

/// Notes list behavior on top of the basic store round-trips covered in
/// CoreTests: the list ordering (newest first) and the list preview text.
final class NotesListTests: XCTestCase {
    override func tearDown() {
        let store = NotesStore()
        store.delete("listnote-old")
        store.delete("listnote-new")
        super.tearDown()
    }

    func testLoadNotesListsNewestFirstWithPreview() {
        let store = NotesStore()
        store.write("listnote-old", "first note body")
        Thread.sleep(forTimeInterval: 0.05)
        store.write("listnote-new", "second note body")
        store.loadNotes()
        let names = store.notes.map { $0.name }
        XCTAssertTrue(names.contains("listnote-old") && names.contains("listnote-new"), "both notes listed")
        let newNote = store.notes.first { $0.name == "listnote-new" }
        XCTAssertEqual(newNote?.preview, "second note body", "preview carries the body's first words")
        if let oi = names.firstIndex(of: "listnote-old"), let ni = names.firstIndex(of: "listnote-new") {
            XCTAssertLessThan(ni, oi, "newer note sorts first")
        }
    }

    func testReadMissingNoteIsEmpty() {
        let store = NotesStore()
        XCTAssertEqual(store.read("no-such-note-\(UUID().uuidString)"), "")
    }
}
