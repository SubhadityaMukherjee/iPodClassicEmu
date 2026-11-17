import Foundation
import Combine

/// Text notes stored as .txt files in Documents/Notes (visible in the Files
/// app via UIFileSharingEnabled). All I/O is atomic; saves are debounced.
@Observable
final class NotesStore {
    /// One note as the list shows it: filename (no extension), last
    /// modification date, and a short body preview for the row subtitle.
    /// A plain value type — cheap to copy and compare.
    struct Note: Identifiable, Equatable {
        let name: String       // without extension
        let date: Date
        var preview: String = ""  // first few words, for the list
        /// Filenames are unique within the notes folder, so the name
        /// alone identifies the note (and drives SwiftUI list diffing).
        var id: String { name }
    }

    /// Notes currently in Documents/Notes, newest first. Read-only
    /// outside the store; `loadNotes()` is the refresh entry point, and
    /// most folder-changing methods call it themselves.
    private(set) var notes: [Note] = []
    /// Deleted notes live in the hidden Notes/.trash folder until restored
    /// or removed for good (the Trash screen browses this).
    private(set) var trash: [Note] = []

    /// The Documents/Notes folder, created on first access.
    ///
    /// Documents is user-visible in the Files app (UIFileSharingEnabled),
    /// so notes live as plain .txt files users can also edit or add from
    /// outside the app — which is why the lists are always re-read from
    /// disk instead of treating this store as the source of truth.
    /// Creating the directory lazily here means any entry point can just
    /// ask for the URL and the folder exists.
    ///
    /// Concept: FileManager → docs/concepts/filemanager-and-sandbox.md
    var notesURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Rebuilds `notes` from the .txt files in Documents/Notes, newest
    /// modification date first.
    ///
    /// Each row's preview is the first ~7 words of the body with
    /// newlines flattened to spaces. Subfolders (like .trash) fail the
    /// ".txt" extension filter, so only real note files are listed, and
    /// an unreadable file degrades to an empty preview instead of
    /// failing the whole load.
    func loadNotes() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: notesURL, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        notes = files.filter { $0.pathExtension.lowercased() == "txt" }
            .map { url -> Note in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                let body = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                let preview = body.split(separator: "\n").joined(separator: " ")
                let words = preview.split(separator: " ").prefix(7).joined(separator: " ")
                return Note(name: url.deletingPathExtension().lastPathComponent, date: date, preview: words)
            }
            .sorted { $0.date > $1.date }
    }

    /// Returns a note's full text.
    ///
    /// Errors collapse to "": a missing or unreadable file simply opens
    /// as a blank note instead of throwing into UI code.
    /// - Parameter name: filename without the .txt extension.
    /// - Returns: the file's UTF-8 text, or an empty string on any I/O error.
    ///
    /// Concept: String(contentsOf:) → docs/concepts/foundation.md
    func read(_ name: String) -> String {
        let url = notesURL.appendingPathComponent(name).appendingPathExtension("txt")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// Creates an empty note file and returns the name it landed on.
    ///
    /// If the requested name is taken, " 2", " 3"… suffixes are tried
    /// (Finder-style copy naming) so a create never overwrites an
    /// existing note. `@discardableResult` because callers that don't
    /// navigate into the new note may ignore the result.
    /// - Parameter name: desired filename without extension; nil uses "New Note".
    /// - Returns: the unique name actually written (without extension).
    @discardableResult
    func create(_ name: String? = nil) -> String {
        let fm = FileManager.default
        var finalName = name ?? "New Note"
        var n = 2
        while fm.fileExists(atPath: notesURL.appendingPathComponent(finalName).appendingPathExtension("txt").path) {
            finalName = "\(name ?? "New Note") \(n)"
            n += 1
        }
        write(finalName, "")
        return finalName
    }

    /// Writes a note's full text atomically.
    ///
    /// `.atomic` writes to a temp file and swaps it in, so a mid-write
    /// kill can never leave a half-written note — worth the care here
    /// because the Files app can be reading these same files.
    /// - Parameters:
    ///   - name: filename without the .txt extension.
    ///   - text: the complete body to persist.
    func write(_ name: String, _ text: String) {
        let url = notesURL.appendingPathComponent(name).appendingPathExtension("txt")
        try? text.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    /// Removes a note file from Documents/Notes immediately and
    /// permanently, then reloads the list.
    ///
    /// The screens don't call this — in-app deletes go through
    /// `trash(_:)` so they stay recoverable. This is the direct-remove
    /// primitive for callers that truly mean it.
    /// - Parameter name: filename without the .txt extension.
    func delete(_ name: String) {
        let url = notesURL.appendingPathComponent(name).appendingPathExtension("txt")
        try? FileManager.default.removeItem(at: url)
        loadNotes()
    }

    /// The Documents/Notes/.trash folder, created on first access.
    ///
    /// The leading dot keeps the folder hidden from the Files app, so
    /// trashed notes are invisible everywhere except the in-app Trash
    /// screen.
    var trashURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Notes", isDirectory: true)
            .appendingPathComponent(".trash", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Moves a note to the hidden trash folder (recoverable from the
    /// Trash screen) instead of destroying it.
    func trash(_ name: String) {
        let fm = FileManager.default
        let from = notesURL.appendingPathComponent(name).appendingPathExtension("txt")
        guard fm.fileExists(atPath: from.path) else { return }
        var target = trashURL.appendingPathComponent(name).appendingPathExtension("txt")
        var n = 2
        while fm.fileExists(atPath: target.path) {
            target = trashURL.appendingPathComponent("\(name) \(n)").appendingPathExtension("txt")
            n += 1
        }
        try? fm.moveItem(at: from, to: target)
        loadNotes()
        loadTrash()
    }

    /// Rebuilds `trash` from the .trash folder — deliberately the same
    /// shape as `loadNotes()` (previews, newest first) so the Trash
    /// screen renders with the same rows as the notes list.
    func loadTrash() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: trashURL, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        trash = files.filter { $0.pathExtension.lowercased() == "txt" }
            .map { url -> Note in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                let body = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                let preview = body.split(separator: "\n").joined(separator: " ")
                let words = preview.split(separator: " ").prefix(7).joined(separator: " ")
                return Note(name: url.deletingPathExtension().lastPathComponent, date: date, preview: words)
            }
            .sorted { $0.date > $1.date }
    }

    /// Moves a trashed note back into Notes (name uniquified on clash).
    func restore(_ name: String) {
        let fm = FileManager.default
        let from = trashURL.appendingPathComponent(name).appendingPathExtension("txt")
        guard fm.fileExists(atPath: from.path) else { return }
        var target = notesURL.appendingPathComponent(name).appendingPathExtension("txt")
        var n = 2
        while fm.fileExists(atPath: target.path) {
            target = notesURL.appendingPathComponent("\(name) \(n)").appendingPathExtension("txt")
            n += 1
        }
        try? fm.moveItem(at: from, to: target)
        loadNotes()
        loadTrash()
    }

    /// Deletes a trashed note from .trash for good — the only
    /// unrecoverable delete reachable from the UI — and reloads the
    /// trash list.
    /// - Parameter name: filename without the .txt extension.
    func deleteForever(_ name: String) {
        let url = trashURL.appendingPathComponent(name).appendingPathExtension("txt")
        try? FileManager.default.removeItem(at: url)
        loadTrash()
    }

    /// Debounced save used by the editor.
    private var saveTask: Task<Void, Never>?
    /// Persists the editor's text after 0.6 s of quiet.
    ///
    /// Every keystroke fires the editor's `onChange`, so writing (and
    /// re-reading every file via `loadNotes()`) per keystroke would be
    /// wasteful. Each call cancels the pending unstructured task first,
    /// which is what makes this a debounce — the last keystroke wins.
    /// Edits landing inside the final window are covered by the editor's
    /// `onDisappear`, which writes immediately.
    /// - Parameters:
    ///   - name: filename without the .txt extension.
    ///   - text: the complete body to persist.
    ///
    /// Concept: Task.sleep / cancellation → docs/concepts/swift-async-await.md
    func saveDebounced(_ name: String, _ text: String) {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.write(name, text)
            self?.loadNotes()
        }
    }
}
