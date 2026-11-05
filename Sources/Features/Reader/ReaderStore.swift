import Foundation

/// Registry of imported books (Documents/Books) with each book's reading
/// position and font size, persisted in UserDefaults. EPUBs are extracted
/// to a folder per book so the web view can load resources relatively;
/// PDFs are copied as files.
@Observable
final class ReaderStore {
    struct Book: Codable, Identifiable, Equatable {
        enum Kind: String, Codable {
            case pdf, epub
        }

        let id: String             // folder (epub) or file stem (pdf) under Books/
        let kind: Kind
        var title: String
        var chapterIndex: Int      // epub: spine index; pdf: page index
        var scrollFraction: Double // epub: position within the chapter
        var fontSize: Int          // epub: CSS body font size in px
    }

    enum ImportError: LocalizedError {
        case unsupported
        case badEPUB

        var errorDescription: String? {
            switch self {
            case .unsupported: return "Only PDF and EPUB files are supported"
            case .badEPUB: return "The EPUB file could not be read"
            }
        }
    }

    static let shared = ReaderStore()

    private(set) var books: [Book] = []

    private let d = UserDefaults.standard
    private static let key = "reader.books"

    private init() {
        if let data = d.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([Book].self, from: data) {
            books = decoded
        }
    }

    /// Root folder for all imported books.
    static var booksRoot: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Books", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func book(id: String) -> Book? {
        books.first { $0.id == id }
    }

    /// Replaces a book's entry and persists (reading position, font size).
    func update(_ book: Book) {
        guard let idx = books.firstIndex(where: { $0.id == book.id }) else { return }
        books[idx] = book
        persist()
    }

    func remove(_ book: Book) {
        books.removeAll { $0.id == book.id }
        persist()
        let target = Self.booksRoot.appendingPathComponent(book.id)
        try? FileManager.default.removeItem(at: target)               // epub dir
        try? FileManager.default.removeItem(at: target.appendingPathExtension("pdf"))  // pdf file
    }

    // MARK: Import

    /// Imports a picked file (a plain copy URL from the document picker).
    @discardableResult
    func addBook(from url: URL) throws -> Book {
        let ext = url.pathExtension.lowercased()
        guard ext == "pdf" || ext == "epub" else { throw ImportError.unsupported }
        let kind: Book.Kind = ext == "pdf" ? .pdf : .epub
        let base = url.deletingPathExtension().lastPathComponent
        let id = uniqueID(for: base)
        let dest = Self.booksRoot.appendingPathComponent(id)

        if kind == .pdf {
            let fileDest = dest.appendingPathExtension("pdf")
            try? FileManager.default.removeItem(at: fileDest)
            try FileManager.default.copyItem(at: url, to: fileDest)
        } else {
            try? FileManager.default.removeItem(at: dest)
            try EpubUnzip.extract(zipURL: url, to: dest)
            // Sanity check: a valid EPUB always has a container.xml.
            let container = dest.appendingPathComponent("META-INF/container.xml")
            guard FileManager.default.fileExists(atPath: container.path) else {
                try? FileManager.default.removeItem(at: dest)
                throw ImportError.badEPUB
            }
        }

        let book = Book(id: id, kind: kind, title: base,
                        chapterIndex: 0, scrollFraction: 0, fontSize: 17)
        books.insert(book, at: 0)
        persist()
        return book
    }

    /// "Title", "Title 2", … — never overwrites an existing import.
    private func uniqueID(for base: String) -> String {
        let fm = FileManager.default
        var candidate = base
        var n = 2
        while fm.fileExists(atPath: Self.booksRoot.appendingPathComponent(candidate).path)
            || fm.fileExists(atPath: Self.booksRoot.appendingPathComponent(candidate).appendingPathExtension("pdf").path) {
            candidate = "\(base) \(n)"
            n += 1
        }
        return candidate
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(books) {
            d.set(data, forKey: Self.key)
        }
    }
}
