import Foundation
import PDFKit

/// Registry of imported books (Documents/Books) with each book's reading
/// position and font size, persisted in UserDefaults. EPUBs are extracted
/// to a folder per book so the web view can load resources relatively;
/// PDFs are copied as files.
@Observable
final class ReaderStore {
    /// One imported book's registry record: identity, reading position,
    /// and typography settings, persisted as JSON in UserDefaults.
    /// EPUBs live as extracted folders under Books/<id>/; PDFs as copied
    /// files Books/<id>.pdf.
    struct Book: Codable, Identifiable, Equatable {
        /// Storage format — selects the rendering pipeline (web view vs
        /// PDFKit) and where highlights are kept.
        enum Kind: String, Codable {
            case pdf, epub
        }

        /// Books/<id> folder name (EPUB) or file stem (PDF) — doubles as
        /// the stable identity across launches.
        let id: String             // folder (epub) or file stem (pdf) under Books/
        /// Which pipeline renders and stores this book.
        let kind: Kind
        /// Display title (imported file name or article headline).
        var title: String
        /// Reading position by chapter: EPUB spine index / reflow chapter
        /// index, or PDF page index.
        var chapterIndex: Int      // epub: spine index; pdf: page index
        /// Position within the chapter, 0–1 (page-view modes; reflow
        /// tracks its own field so switching modes never moves either).
        var scrollFraction: Double // epub: position within the chapter
        /// CSS body font size in px (EPUB and reflow only).
        var fontSize: Int          // epub: CSS body font size in px
        /// Index into fontFamilyNames/fontFamilyStacks (parallel arrays).
        var fontFamily: Int        // epub: index into fontFamilies (0..count-1)
        /// 0 compact / 1 normal / 2 wide — index into the CSS line-height table.
        var lineSpacing: Int       // epub: 0 compact, 1 normal, 2 wide
        /// 0 narrow / 1 normal / 2 wide — side padding in px.
        var margin: Int            // epub: 0 narrow, 1 normal, 2 wide
        /// Wheel tick size: 0 Small (1 page/tick), 1 Medium (2), 2 Large (3).
        var scrollStep: Int        // epub: 0 small, 1 medium, 2 full page
        /// PDF view mode: 0 Continuous, 1 One Page, 2 Reflowed text.
        var pdfMode: Int           // pdf: 0 continuous, 1 one page, 2 reflowed text
        /// Reflow-mode chapter index (own fields so switching view modes
        /// never moves the page view).
        var reflowChapter: Int     // pdf reflow: chapter index (kept separate so
                                   // switching view modes never moves the page view)
        /// Reflow-mode position within the chapter, 0–1.
        var reflowFraction: Double // pdf reflow: position within the chapter
        /// Screen dim overlay level; maps to BookScreen.dimOverlays.
        var dim: Int               // 0 bright, 1 dim, 2 darker (screen overlay)
        /// Non-nil = Read Later article; the origin URL (nil = real book).
        var sourceURL: String?     // non-nil = article (Read Later); the origin URL

        /// Explicit because decoding must still read the retired
        /// `pdfContinuous` Bool that pre-reflow books persisted.
        enum CodingKeys: String, CodingKey {
            case id, kind, title, chapterIndex, scrollFraction, fontSize
            case fontFamily, lineSpacing, margin, scrollStep, pdfMode
            case reflowChapter, reflowFraction, dim, sourceURL
            case pdfContinuousLegacy = "pdfContinuous"
        }

        /// Creates a record with reading defaults: start of book, 17 px
        /// body text, normal spacing/margins — and `scrollStep` 0 (one
        /// page per wheel tick; larger defaults made fresh books skip).
        init(id: String, kind: Kind, title: String, chapterIndex: Int = 0,
             scrollFraction: Double = 0, fontSize: Int = 17, fontFamily: Int = 0,
             lineSpacing: Int = 1, margin: Int = 1, scrollStep: Int = 0,
             pdfMode: Int = 0, reflowChapter: Int = 0, reflowFraction: Double = 0,
             dim: Int = 0, sourceURL: String? = nil) {
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
            self.pdfMode = pdfMode
            self.reflowChapter = reflowChapter
            self.reflowFraction = reflowFraction
            self.dim = dim
            self.sourceURL = sourceURL
        }

        /// Tolerates books persisted by older versions (missing keys).
        init(from decoder: Decoder) throws {            let c = try decoder.container(keyedBy: CodingKeys.self)
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
            // Legacy books persisted a Bool (continuous vs one page).
            if let m = try c.decodeIfPresent(Int.self, forKey: .pdfMode) {
                pdfMode = min(max(m, 0), 2)
            } else {
                pdfMode = (try c.decodeIfPresent(Bool.self, forKey: .pdfContinuousLegacy) ?? true) ? 0 : 1
            }
            reflowChapter = try c.decodeIfPresent(Int.self, forKey: .reflowChapter) ?? 0
            reflowFraction = try c.decodeIfPresent(Double.self, forKey: .reflowFraction) ?? 0
            dim = try c.decodeIfPresent(Int.self, forKey: .dim) ?? 0
            sourceURL = try c.decodeIfPresent(String.self, forKey: .sourceURL)
        }

        /// Hand-written because CodingKeys carries the decode-only legacy
        /// `pdfContinuousLegacy` case, which blocks encoder synthesis.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(kind, forKey: .kind)
            try c.encode(title, forKey: .title)
            try c.encode(chapterIndex, forKey: .chapterIndex)
            try c.encode(scrollFraction, forKey: .scrollFraction)
            try c.encode(fontSize, forKey: .fontSize)
            try c.encode(fontFamily, forKey: .fontFamily)
            try c.encode(lineSpacing, forKey: .lineSpacing)
            try c.encode(margin, forKey: .margin)
            try c.encode(scrollStep, forKey: .scrollStep)
            try c.encode(pdfMode, forKey: .pdfMode)
            try c.encode(reflowChapter, forKey: .reflowChapter)
            try c.encode(reflowFraction, forKey: .reflowFraction)
            try c.encode(dim, forKey: .dim)
            try c.encodeIfPresent(sourceURL, forKey: .sourceURL)
        }

        /// EPUB font choices (persisted as `fontFamily` index): display
        /// names for the settings row and CSS stacks for the web view.
        /// Indexes are shared by both arrays — keep them in sync.
        static let fontFamilyNames = ["Serif", "Sans", "Iowan", "Baskerville", "Avenir", "Typewriter"]
        /// CSS font stacks injected into the reader stylesheet, one per
        /// name above (same index).
        static let fontFamilyStacks = [
            "Georgia,'Times New Roman',serif",
            "-apple-system,'Helvetica Neue',sans-serif",
            "'Iowan Old Style','Palatino',serif",
            "'Baskerville','Times New Roman',serif",
            "'Avenir Next','Helvetica Neue',sans-serif",
            "'American Typewriter','Courier New',serif",
        ]
    }

    /// Import failures surfaced to the user as a toast.
    enum ImportError: LocalizedError {
        case unsupported
        case badEPUB

        /// User-facing message (how LocalizedError reaches the UI).
        var errorDescription: String? {
            switch self {
            case .unsupported: return "Only PDF and EPUB files are supported"
            case .badEPUB: return "The EPUB file could not be read"
            }
        }
    }

    /// Process-wide store, created lazily on first access.
    static let shared = ReaderStore()

    /// Every imported book and article, newest first. Tracked by the
    /// @Observable macro, so reads in views update on mutation.
    ///
    /// Concept: Observation → docs/concepts/swiftui-views-and-state.md
    private(set) var books: [Book] = []

    /// Backing storage for the encoded registry.
    private let d = UserDefaults.standard
    /// Defaults key the registry is encoded under.
    private static let key = "reader.books"

    /// Loads the registry, then applies one-time migrations that heal
    /// books persisted under retired scroll-step defaults. Each migration
    /// is guarded by its own defaults flag so it runs exactly once.
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
        // Registry-loss self-heal: the registry lives in UserDefaults,
        // which QA hooks (RESET_DEFAULTS=1) and other defaults resets can
        // clear while the extracted files survive in Documents/Books —
        // without this, those books vanish from the list until
        // re-imported (a device lost its whole list with every file
        // intact, 2026-11-19).
        healOrphans()
    }

    /// Re-registers books whose files exist under `Books/` but are
    /// missing from the registry, with default reading settings. EPUBs
    /// are detected by their extracted `META-INF/container.xml` (a PDF's
    /// reflow dir contains only `reflow/` and is owned by its `.pdf`
    /// file); PDFs by the copied `<id>.pdf` file. Idempotent — books
    /// already registered are left untouched.
    func healOrphans() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: Self.booksRoot, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        var known = Set(books.map(\.id))
        var healed = 0
        for entry in entries {
            let name = entry.lastPathComponent
            if name.hasPrefix(".") { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                guard !known.contains(name),
                      fm.fileExists(atPath: entry.appendingPathComponent("META-INF/container.xml").path)
                else { continue }
                books.append(Book(id: name, kind: .epub, title: Self.epubTitle(in: entry) ?? name))
                known.insert(name)
                healed += 1
            } else if name.hasSuffix(".pdf") {
                let id = String(name.dropLast(4))
                guard !known.contains(id) else { continue }
                books.append(Book(id: id, kind: .pdf, title: id))
                known.insert(id)
                healed += 1
            }
        }
        if healed > 0 { persist() }
    }

    /// Best-effort display title for a healed EPUB: the OPF's
    /// `<dc:title>` (searched at the book root and in `OEBPS/`), decoded
    /// for the common XML entities, falling back to nil when absent so
    /// the caller can use the folder name.
    private static func epubTitle(in dir: URL) -> String? {
        let fm = FileManager.default
        for base in [dir, dir.appendingPathComponent("OEBPS")] {
            guard let names = try? fm.contentsOfDirectory(atPath: base.path) else { continue }
            for name in names where name.hasSuffix(".opf") {
                guard let text = try? String(contentsOf: base.appendingPathComponent(name), encoding: .utf8),
                      let open = text.range(of: "<dc:title", options: .caseInsensitive)
                else { continue }
                var tail = text[open.upperBound...]
                // Skip any tag attributes up to the closing bracket.
                if let bracket = tail.range(of: ">") { tail = tail[bracket.upperBound...] }
                guard let end = tail.range(of: "</dc:title>", options: .caseInsensitive) else { continue }
                let title = tail[..<end.lowerBound]
                    .replacingOccurrences(of: "&amp;", with: "&")
                    .replacingOccurrences(of: "&#39;", with: "'")
                    .replacingOccurrences(of: "&apos;", with: "'")
                    .replacingOccurrences(of: "&quot;", with: "\"")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty { return title }
            }
        }
        return nil
    }

    /// Root folder for all imported books.
    static var booksRoot: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Books", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Looks up a record by its persisted identity.
    ///
    /// - Parameter id: folder/file-stem ID from `Book.id`.
    /// - Returns: the book, or nil if it is no longer registered.
    func book(id: String) -> Book? {
        books.first { $0.id == id }
    }

    /// Replaces a book's entry and persists (reading position, font size).
    func update(_ book: Book) {
        guard let idx = books.firstIndex(where: { $0.id == book.id }) else { return }
        books[idx] = book
        persist()
    }

    /// Removes a book from the registry and disk. Both on-disk shapes
    /// are tried (EPUB folder `<id>/` and PDF file `<id>.pdf`); deletes
    /// are best effort — filesystem failures are ignored.
    func remove(_ book: Book) {
        books.removeAll { $0.id == book.id }
        persist()
        let target = Self.booksRoot.appendingPathComponent(book.id)
        try? FileManager.default.removeItem(at: target)               // epub dir
        try? FileManager.default.removeItem(at: target.appendingPathExtension("pdf"))  // pdf file
    }

    // MARK: Articles (Read Later)

    /// Articles are one-chapter mini-EPUBs written by ArticleExtractor —
    /// identical reading pipeline (pagination, fonts, highlights), but
    /// listed separately and tagged with their origin URL.
    var articles: [Book] { books.filter { $0.sourceURL != nil } }

    /// Downloads and extracts a web article, then registers it. Async:
    /// the network fetch runs off the main actor.
    @discardableResult
    func addArticle(from urlString: String) async throws -> Book {
        let html = try await ArticleExtractor.fetch(from: urlString)
        let (title, paragraphs) = await Task.detached(priority: .userInitiated) {
            ArticleExtractor.extract(html: html)
        }.value
        let xhtml = ArticleExtractor.xhtml(title: title, paragraphs: paragraphs)
        let id = Self.uniqueArticleID(base: Self.articleID(for: title))
        let dest = Self.booksRoot.appendingPathComponent(id)
        try ArticleExtractor.writeMiniEpub(dir: dest, title: title, xhtml: xhtml)
        let book = Book(id: id, kind: .epub, title: title, sourceURL: urlString)
        books.insert(book, at: 0)
        persist()
        return book
    }

    /// "slug", "slug 2", … — never overwrites an existing article/book.
    private static func uniqueArticleID(base: String) -> String {
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

    /// Article folder ID: a readable slug from the title.
    private static func articleID(for title: String) -> String {
        var slug = String(title.lowercased().map { ch -> Character in
            ch.isLetter || ch.isNumber ? ch : "-"
        })
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        let trimmed = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "article" : String(trimmed.prefix(48))
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

        var pdfMode = 0
        if kind == .pdf {
            let fileDest = dest.appendingPathExtension("pdf")
            try? FileManager.default.removeItem(at: fileDest)
            try FileManager.default.copyItem(at: url, to: fileDest)
            // Text PDFs open in Reflowed mode (that's why they're here);
            // scanned/image-only PDFs stay in Continuous page view.
            if let doc = PDFDocument(url: fileDest) {
                var textLen = 0
                for i in 0..<min(6, doc.pageCount) {
                    textLen += doc.page(at: i)?.string?.count ?? 0
                }
                if textLen > 200 { pdfMode = 2 }
            }
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
                        chapterIndex: 0, scrollFraction: 0, fontSize: 17,
                        pdfMode: pdfMode)
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

    /// Encodes the registry to UserDefaults; called after every mutation.
    ///
    /// Concept: userdefaults → docs/concepts/userdefaults.md
    private func persist() {
        if let data = try? JSONEncoder().encode(books) {
            d.set(data, forKey: Self.key)
        }
    }
}
