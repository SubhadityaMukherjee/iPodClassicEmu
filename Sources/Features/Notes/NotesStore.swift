import Foundation
import Combine

/// Text notes stored as .txt files in Documents/Notes (visible in the Files
/// app via UIFileSharingEnabled). All I/O is atomic; saves are debounced.
@Observable
final class NotesStore {
    struct Note: Identifiable, Equatable {
        let name: String       // without extension
        let date: Date
        var preview: String = ""  // first few words, for the list
        var id: String { name }
    }

    private(set) var notes: [Note] = []
    /// Deleted notes live in the hidden Notes/.trash folder until restored
    /// or removed for good (the Trash screen browses this).
    private(set) var trash: [Note] = []

    var notesURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

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

    func read(_ name: String) -> String {
        let url = notesURL.appendingPathComponent(name).appendingPathExtension("txt")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

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

    func write(_ name: String, _ text: String) {
        let url = notesURL.appendingPathComponent(name).appendingPathExtension("txt")
        try? text.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    func delete(_ name: String) {
        let url = notesURL.appendingPathComponent(name).appendingPathExtension("txt")
        try? FileManager.default.removeItem(at: url)
        loadNotes()
    }

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

    func deleteForever(_ name: String) {
        let url = trashURL.appendingPathComponent(name).appendingPathExtension("txt")
        try? FileManager.default.removeItem(at: url)
        loadTrash()
    }

    /// Debounced save used by the editor.
    private var saveTask: Task<Void, Never>?
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
