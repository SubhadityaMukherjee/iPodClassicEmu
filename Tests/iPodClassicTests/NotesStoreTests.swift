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

/// Trash flow: delete-to-trash is recoverable; restore brings the note
/// back; delete-for-good removes it from the hidden trash folder.
final class NotesTrashTests: XCTestCase {
    private let store = NotesStore()

    override func tearDown() {
        store.deleteForever("trashtest-note")
        store.delete("trashtest-note")
        super.tearDown()
    }

    func testTrashMovesNoteOutOfListAndIntoTrash() {
        store.write("trashtest-note", "recover me")
        store.loadNotes()
        XCTAssertTrue(store.notes.contains { $0.name == "trashtest-note" })
        store.trash("trashtest-note")
        store.loadNotes()
        XCTAssertFalse(store.notes.contains { $0.name == "trashtest-note" }, "trashed note left the list")
        store.loadTrash()
        XCTAssertTrue(store.trash.contains { $0.name == "trashtest-note" }, "trashed note is in the trash")
        XCTAssertEqual(store.read("trashtest-note"), "", "trashed note no longer readable from Notes")
    }

    func testRestoreBringsNoteBack() {
        store.write("trashtest-note", "recover me")
        store.trash("trashtest-note")
        store.restore("trashtest-note")
        store.loadNotes()
        store.loadTrash()
        XCTAssertTrue(store.notes.contains { $0.name == "trashtest-note" }, "restored note is back in Notes")
        XCTAssertFalse(store.trash.contains { $0.name == "trashtest-note" }, "restored note left the trash")
        XCTAssertNotEqual(store.read("trashtest-note"), "", "restored body intact")
    }

    func testDeleteForeverRemovesFromTrash() {
        store.write("trashtest-note", "gone for good")
        store.trash("trashtest-note")
        store.loadTrash()
        XCTAssertTrue(store.trash.contains { $0.name == "trashtest-note" })
        store.deleteForever("trashtest-note")
        store.loadTrash()
        XCTAssertFalse(store.trash.contains { $0.name == "trashtest-note" }, "note removed from trash")
    }
}
