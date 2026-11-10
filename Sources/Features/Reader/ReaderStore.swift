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
        var fontFamily: Int        // epub: index into fontFamilies (0..count-1)
        var lineSpacing: Int       // epub: 0 compact, 1 normal, 2 wide
        var margin: Int            // epub: 0 narrow, 1 normal, 2 wide
        var scrollStep: Int        // epub: 0 small, 1 medium, 2 full page
        var pdfContinuous: Bool    // pdf: continuous scroll vs one page
        var dim: Int               // 0 bright, 1 dim, 2 darker (screen overlay)

        init(id: String, kind: Kind, title: String, chapterIndex: Int = 0,
             scrollFraction: Double = 0, fontSize: Int = 17, fontFamily: Int = 0,
             lineSpacing: Int = 1, margin: Int = 1, scrollStep: Int = 0,
             pdfContinuous: Bool = true, dim: Int = 0) {
            self.id = id
            self.kind = kind
            self.title = title
            self.chapterIndex = chapterIndex
            self.scrollFraction = scrollFraction
            self.fontSize = fontSize
            self.fontFamily = fontFamily
            self.lineSpacing = lineSpacing
            self.margin = margin
            self.scrollStep = scrollStep
            self.pdfContinuous = pdfContinuous
            self.dim = dim
        }

        /// Tolerates books persisted by older versions (missing keys).
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            kind = try c.decode(Kind.self, forKey: .kind)
            title = try c.decode(String.self, forKey: .title)
            chapterIndex = try c.decodeIfPresent(Int.self, forKey: .chapterIndex) ?? 0
            scrollFraction = try c.decodeIfPresent(Double.self, forKey: .scrollFraction) ?? 0
            fontSize = try c.decodeIfPresent(Int.self, forKey: .fontSize) ?? 17
            fontFamily = try c.decodeIfPresent(Int.self, forKey: .fontFamily) ?? 0
            lineSpacing = try c.decodeIfPresent(Int.self, forKey: .lineSpacing) ?? 1
            margin = try c.decodeIfPresent(Int.self, forKey: .margin) ?? 1
            scrollStep = try c.decodeIfPresent(Int.self, forKey: .scrollStep) ?? 0
            pdfContinuous = try c.decodeIfPresent(Bool.self, forKey: .pdfContinuous) ?? true
            dim = try c.decodeIfPresent(Int.self, forKey: .dim) ?? 0
        }

        /// EPUB font choices (persisted as `fontFamily` index): display
        /// names for the settings row and CSS stacks for the web view.
        /// Indexes are shared by both arrays — keep them in sync.
        static let fontFamilyNames = ["Serif", "Sans", "Iowan", "Baskerville", "Avenir", "Typewriter"]
        static let fontFamilyStacks = [
            "Georgia,'Times New Roman',serif",
            "-apple-system,'Helvetica Neue',sans-serif",
            "'Iowan Old Style','Palatino',serif",
            "'Baskerville','Times New Roman',serif",
            "'Avenir Next','Helvetica Neue',sans-serif",
            "'American Typewriter','Courier New',serif",
        ]
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
        // One-time: the old default scroll step (70% of a screen) left a
        // repeated band between successive ticks. Page-step everything.
        if !d.bool(forKey: "reader.pageStepMigrated") {
            for i in books.indices where books[i].kind == .epub && books[i].scrollStep == 1 {
                books[i].scrollStep = 2
            }
            persist()
            d.set(true, forKey: "reader.pageStepMigrated")
        }
        // Line-boundary pages turned the page count per tick into whole
        // pages (Small = 1 page — the old full-page feel). Reset everyone
        // to it once; per-book choices made after this apply freely.
        if !d.bool(forKey: "reader.linePageMigrated") {
            for i in books.indices where books[i].kind == .epub {
                books[i].scrollStep = 0
            }
            persist()
            d.set(true, forKey: "reader.linePageMigrated")
        }
        // One-time: books created while the default scroll step was 2
        // ("Large" = 3 pages per tick) skipped pages on every wheel notch —
        // the user reads page-by-page. Heal those to 1 page per tick.
        if !d.bool(forKey: "reader.newBookStepMigrated") {
            for i in books.indices where books[i].kind == .epub && books[i].scrollStep == 2 {
                books[i].scrollStep = 0
            }
            persist()
            d.set(true, forKey: "reader.newBookStepMigrated")
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
