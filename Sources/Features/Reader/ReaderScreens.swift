import SwiftUI
import PDFKit
import WebKit
import UniformTypeIdentifiers
import UIKit
import os

/// Reader top level: Books and Articles (Read Later) are kept apart —
/// both open the same reading screen, only the lists differ.
struct ReaderHomeScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings
    @State private var selection = 0

    /// The shared reader store (from the app model).
    private var store: ReaderStore { model.reader }

    /// The two top-level rows: Books and Articles, each with its count.
    private var items: [MenuItem] {
        [
            MenuItem(id: "books", title: "Books",
                     detail: "\(store.books.count - store.articles.count)", symbol: "book"),
            MenuItem(id: "articles", title: "Articles",
                     detail: "\(store.articles.count)", symbol: "newspaper"),
        ]
    }

    /// The Books/Articles selector list, driven by the wheel.
    var body: some View {
        MenuList(items: items, selection: selection)
            .onWheel { handle($0) }
    }

    /// Wheel routing: ticks move the row, center opens the picked list,
    /// MENU pops back to the parent menu.
    private func handle(_ event: ControlEvent) {
        switch event {
        case .tick(let d):
            moveListSelection(&selection, count: items.count, delta: d, settings: settings)
        case .select:
            model.push(items.indices.contains(selection) && selection == 1
                       ? .readerArticles : .readerBooks)
        case .menu:
            model.pop()
        default:
            break
        }
    }
}

/// Reader menu: "Add from Files" plus the imported books.
struct ReaderScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings
    @State private var selection = 0
    @State private var showingPicker = false
    @State private var deleteCandidate: ReaderStore.Book?
    @State private var deleteSelection = 0
    @State private var toast = ""

    /// The shared reader store (from the app model).
    private var store: ReaderStore { model.reader }

    /// Books only — articles (Read Later) live in their own list.
    private var books: [ReaderStore.Book] { store.books.filter { $0.sourceURL == nil } }

    /// Menu rows: the import action on top, then one row per book.
    private var items: [MenuItem] {
        var rows = [MenuItem(id: "hdr.add", title: "Add from Files", symbol: "plus.circle.fill", showsChevron: false, isActionRow: true)]
        rows += books.map { book in
            MenuItem(id: book.id, title: book.title, detail: book.kind == .pdf ? "PDF" : "EPUB")
        }
        return rows
    }

    /// Book list plus the delete-confirmation panel and toast overlays.
    var body: some View {
        ZStack {
            MenuList(items: items, selection: selection, emptyText: "No Books")
            if deleteCandidate != nil {
                ModalHost { deletePanel }
                    .zIndex(2)
            }
            if !toast.isEmpty {
                ToastCapsule(text: toast)
                    .zIndex(3)
            }
        }
        .onWheel { handle($0) }
        .sheet(isPresented: $showingPicker) {
            DocumentPicker { url in
                importBook(url)
            }
        }
    }

    /// Confirmation panel for deleting the held book row.
    private var deletePanel: some View {
        ModalPanel(title: "Delete Book", onClose: { deleteCandidate = nil }) {
            VStack(spacing: 8) {
                Text("\"\(deleteCandidate?.title ?? "")\" will be removed.")
                    .font(Theme.font(13, .medium))
                    .foregroundStyle(Theme.inkDim)
                MenuList(
                    items: [MenuItem(id: "cancel", title: "Cancel"),
                            MenuItem(id: "delete", title: "Delete")],
                    selection: deleteSelection, compact: true
                )
            }
        }
    }

    /// Imports a picked file through the store and reports the outcome
    /// via toast.
    private func importBook(_ url: URL) {
        do {
            let book = try store.addBook(from: url)
            showToast("Added \(book.title)")
        } catch {
            showToast(error.localizedDescription)
        }
    }

    /// Shows a transient toast; it fades out after two seconds.
    private func showToast(_ text: String) {
        withAnimation(.easeOut(duration: 0.2)) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation(.easeIn(duration: 0.3)) { toast = "" }
        }
    }

    // MARK: Input

    /// Wheel routing; while the delete panel is up, input drives the
    /// panel instead of the list.
    private func handle(_ event: ControlEvent) {
        switch event {
        case .tick(let d):
            if deleteCandidate != nil {
                // The confirmation panel is up: wheel moves its rows.
                moveListSelection(&deleteSelection, count: 2, delta: d, settings: settings)
            } else {
                moveListSelection(&selection, count: items.count, delta: d, settings: settings)
            }
        case .select:
            if deleteCandidate != nil {
                let id = ["cancel", "delete"][min(deleteSelection, 1)]
                if id == "delete", let book = deleteCandidate {
                    store.remove(book)
                    showToast("Deleted")
                }
                deleteCandidate = nil
                selection = 0
            } else if items.indices.contains(selection) {
                let item = items[selection]
                if item.id == "hdr.add" {
                    showingPicker = true
                } else if let book = store.book(id: item.id) {
                    model.push(.readerBook(book.id))
                }
            }
        case .centerHold:
            // Hold a book row: delete it (with confirmation).
            if selection > 0, books.indices.contains(selection - 1) {
                deleteCandidate = books[selection - 1]
                deleteSelection = 0
                WheelHaptics.shared.ensureRunning()
                WheelHaptics.shared.buttonPress(strength: 0.85)
            }
        case .menu:
            if deleteCandidate != nil {
                // MENU closes the confirmation first.
                deleteCandidate = nil
            } else {
                model.pop()
            }
        default:
            break
        }
    }
}

/// Articles (Read Later): URLs shared or pasted into the app, extracted
/// to clean text, read through the same book pipeline. "Add Article"
/// opens a touch-keyboard entry row; hold an article row to delete.
struct ArticleListScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings

    @State private var selection = 0
    @State private var deleteCandidate: ReaderStore.Book?
    @State private var deleteSelection = 0
    @State private var adding = false
    @State private var urlString = ""
    @State private var fetching = false
    @State private var toast = ""
    @FocusState private var focused: Bool

    /// The shared reader store (from the app model).
    private var store: ReaderStore { model.reader }

    /// Menu rows: the add-article action on top, then saved articles
    /// (subtitle = source domain).
    private var items: [MenuItem] {
        var rows = [MenuItem(id: "hdr.add", title: "Add Article", symbol: "plus.circle.fill", showsChevron: false, isActionRow: true)]
        rows += store.articles.map { article in
            MenuItem(id: article.id, title: article.title, detail: domain(of: article.sourceURL))
        }
        return rows
    }

    /// Article list with the URL entry bar, delete panel, and toast.
    var body: some View {
        ZStack {
            VStack(spacing: 4) {
                if adding {
                    entryBar
                }
                MenuList(items: items, selection: selection, emptyText: "No Articles")
                    .frame(maxHeight: .infinity)
            }
            .padding(.top, 4)
            if deleteCandidate != nil {
                ModalHost { deletePanel }
                    .zIndex(2)
            }
            if !toast.isEmpty {
                ToastCapsule(text: toast)
                    .zIndex(3)
            }
        }
        .onWheel { handle($0) }
        .task {
            // QA hook: add an article without typing (sim screenshots/tests).
            if let url = ProcessInfo.processInfo.environment["READER_ADD_URL"], !fetching {
                await add(url)
            }
        }
    }

    /// URL entry row (touch keyboard): link icon, field, clear button.
    private var entryBar: some View {
        HStack(spacing: 5) {
            Image(systemName: "link")
                .font(Theme.font(13, .semibold))
                .foregroundStyle(Theme.inkDim)
            TextField("Paste article URL", text: $urlString)
                .focused($focused)
                .font(Theme.font(13, .medium))
                .foregroundStyle(Theme.ink)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.go)
                .padding(.vertical, 4)
                .environment(\.colorScheme, .dark)
                .onSubmit { commitAdd() }
            if !urlString.isEmpty {
                Button {
                    urlString = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(Theme.font(13))
                        .foregroundStyle(Theme.inkDim)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(white: 0.92))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.18), lineWidth: 0.8))
        )
        .padding(.horizontal, 6)
        .onTapGesture { focused = true }
    }

    /// Confirmation panel for deleting the held article row.
    private var deletePanel: some View {
        ModalPanel(title: "Delete Article", onClose: { deleteCandidate = nil }) {
            VStack(spacing: 8) {
                Text("\"\(deleteCandidate?.title ?? "")\" will be removed.")
                    .font(Theme.font(13, .medium))
                    .foregroundStyle(Theme.inkDim)
                MenuList(
                    items: [MenuItem(id: "cancel", title: "Cancel"),
                            MenuItem(id: "delete", title: "Delete")],
                    selection: deleteSelection, compact: true
                )
            }
        }
    }

    /// Host of an article's origin URL, for the row subtitle.
    ///
    /// - Returns: "" when the URL can't be parsed.
    private func domain(of urlString: String?) -> String {
        guard let urlString, let url = URL(string: urlString) else { return "" }
        return url.host ?? ""
    }

    /// Reveals the URL entry bar, cleared for a fresh paste.
    private func beginAdd() {
        adding = true
        urlString = ""
        // Focusing during the push transition corrupts the layout engine
        // (SIGABRT in NSISEngine) — same guard as the music search.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            focused = true
        }
    }

    /// Commits the typed URL (center press or keyboard Go).
    private func commitAdd() {
        focused = false
        let url = urlString
        adding = false
        guard !url.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Task { await add(url) }
    }

    /// Fetches and registers an article, surfacing progress/errors as
    /// toasts; resets the selection afterwards.
    private func add(_ urlString: String) async {
        fetching = true
        showToast("Fetching…")
        do {
            let book = try await store.addArticle(from: urlString)
            showToast("Added \(book.title)")
        } catch {
            showToast(error.localizedDescription)
        }
        fetching = false
        selection = 0
    }

    /// Shows a transient toast; it fades out after two seconds.
    private func showToast(_ text: String) {
        withAnimation(.easeOut(duration: 0.2)) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation(.easeIn(duration: 0.3)) { toast = "" }
        }
    }

    // MARK: Input

    /// Wheel routing; the delete panel and keyboard entry each take
    /// priority over the list.
    private func handle(_ event: ControlEvent) {
        switch event {
        case .tick(let d):
            if deleteCandidate != nil {
                moveListSelection(&deleteSelection, count: 2, delta: d, settings: settings)
            } else if adding {
                break // keyboard entry: wheel does nothing
            } else {
                moveListSelection(&selection, count: items.count, delta: d, settings: settings)
            }
        case .select:
            if deleteCandidate != nil {
                let id = ["cancel", "delete"][min(deleteSelection, 1)]
                if id == "delete", let article = deleteCandidate {
                    store.remove(article)
                    showToast("Deleted")
                }
                deleteCandidate = nil
                selection = 0
            } else if adding {
                commitAdd()
            } else if items.indices.contains(selection) {
                let item = items[selection]
                if item.id == "hdr.add" {
                    beginAdd()
                } else {
                    model.push(.readerBook(item.id))
                }
            }
        case .centerHold:
            // Hold an article row: delete it (with confirmation).
            if !adding, selection > 0, store.articles.indices.contains(selection - 1) {
                deleteCandidate = store.articles[selection - 1]
                deleteSelection = 0
                WheelHaptics.shared.ensureRunning()
                WheelHaptics.shared.buttonPress(strength: 0.85)
            }
        case .menu:
            if deleteCandidate != nil {
                deleteCandidate = nil
            } else if adding {
                adding = false
                focused = false
            } else {
                model.pop()
            }
        default:
            break
        }
    }
}

/// Document picker (Files app) for PDF/EPUB. `asCopy` hands us a plain
/// copy URL, so no security-scoped bookmark juggling.
struct DocumentPicker: UIViewControllerRepresentable {
    /// Called with the picked file's copy URL.
    var onPick: (URL) -> Void

    /// Creates the system picker limited to PDF/EPUB, in copy mode.
    ///
    /// Concept: swiftui-views-and-state → docs/concepts/swiftui-views-and-state.md
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.pdf, UTType.epub], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    /// No-op: the picker is configured entirely at creation.
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    /// SwiftUI coordinator factory (delegate target).
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    /// Bridges picker delegate callbacks into the SwiftUI closure.
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        /// The SwiftUI-side callback, retained here.
        let onPick: (URL) -> Void

        /// Stores the escaping callback.
        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }

        /// Hands the first picked URL to the callback.
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) }
        }
    }
}

// MARK: - Book screen

/// One open book: reflowing EPUB (WKWebView) or paginated PDF (PDFKit).
/// Wheel scrolls; center opens chapters/contents; hold center opens the
/// book's settings (font, spacing, margins, scroll step, PDF view mode);
/// prev/next change chapter/page.
struct BookScreen: View {
    /// Identity of the book to open (Books/Articles list row).
    let bookID: String

    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase
    /// The open book's record; nil until onAppear resolves the ID (or
    /// permanently when the book was deleted).
    @State private var book: ReaderStore.Book?
    /// EPUB spine chapters — or the reflow chapters once generated.
    @State private var chapters: [EpubChapter] = []
    /// Flattened PDF outline, built lazily when Contents first opens.
    @State private var outline: [OutlineEntry] = []
    /// Shared modal state: `panelIsSettings` picks which panel shows.
    @State private var panelOpen = false
    @State private var panelIsSettings = false
    @State private var panelSelection = 0
    /// Transient toast message (empty = hidden).
    @State private var toast = ""
    /// Saved text highlights for the open book.
    @State private var highlights: [BookHighlight] = []
    /// Live text selection (EPUB JS or PDFKit), driving the action bar.
    @State private var selectedText = ""
    /// PDFViewSelectionChanged observer token (removed on disappear).
    @State private var pdfSelectionToken: NSObjectProtocol?
    /// Command handles for the two renderers; @State keeps them alive
    /// across re-renders while the representable views re-attach.
    ///
    /// Concept: swift-property-wrappers → docs/concepts/swift-property-wrappers.md
    @State private var epubController = EpubController()
    @State private var pdfController = PDFBookController()
    /// Pages per chapter. Estimates come from each chapter's text length
    /// and the current typography; visited chapters get EXACT counts from
    /// the live web view (readerPosition), which also calibrates the
    /// estimates for the whole book.
    @State private var chapterPages: [Int] = []
    /// Stripped-text length per chapter — the estimate input.
    @State private var chapterChars: [Int] = []
    /// Chars-per-page prior once calibrated by a real page count
    /// (0 = still using the built-in prior).
    @State private var charsPerPage: Double = 0
    /// Live in-chapter position, updated on page turns so the progress
    /// bar tracks pages, not just chapters.
    @State private var liveFraction = 0.0
    /// PDF reflow: generated text chapters + generation state.
    @State private var reflowChapters: [EpubChapter] = []
    /// True while reflow chapters are being generated (spinner state).
    @State private var reflowPreparing = false

    /// True when the open book is a PDF (any view mode).
    private var isPDF: Bool { book?.kind == .pdf }
    /// Reflowed text mode: the EPUB pipeline renders extracted text.
    private var isReflow: Bool { book?.kind == .pdf && book?.pdfMode == 2 }
    /// The original PDFKit page view (any mode but reflow).
    private var isPDFOriginal: Bool { isPDF && !isReflow }

    /// Reflow keeps its own position fields so switching view modes never
    /// moves the page view (and vice versa).
    private func chapterIndex(of b: ReaderStore.Book) -> Int { isReflow ? b.reflowChapter : b.chapterIndex }
    /// In-chapter position for the ACTIVE view mode (0–1).
    private func fraction(of b: ReaderStore.Book) -> Double { isReflow ? b.reflowFraction : b.scrollFraction }
    /// Writes the chapter index into the ACTIVE view mode's field.
    private func setChapter(_ v: Int, on b: inout ReaderStore.Book) {
        if isReflow { b.reflowChapter = v } else { b.chapterIndex = v }
    }
    /// Writes the in-chapter position into the ACTIVE view mode's field.
    private func setFraction(_ v: Double, on b: inout ReaderStore.Book) {
        if isReflow { b.reflowFraction = v } else { b.scrollFraction = v }
    }

    /// Black-overlay opacity per `dim` level (bright/dim/darker).
    private static let dimOverlays: [Double] = [0, 0.18, 0.38]

    /// Overlay opacity for the open book's dim setting.
    private var dimOpacity: Double {
        guard let book else { return 0 }
        return Self.dimOverlays[min(max(book.dim, 0), 2)]
    }

    /// The open book: reading area, progress bar, panels, toasts, and
    /// the dim overlay.
    var body: some View {
        VStack(spacing: 4) {
            // Reading area: strictly between the title bar and the progress
            // bar row — the bar never overlays the text, at any offset.
            ZStack {
                if let book {
                    content(book: book)
                    if panelOpen {
                        ModalHost { panel }
                            .zIndex(2)
                    }
                    if !selectedText.isEmpty && !panelOpen {
                        selectionBar
                            .zIndex(2)
                    }
                    if !toast.isEmpty {
                        ToastCapsule(text: toast)
                            .zIndex(3)
                    }
                } else {
                    Text("Book not found")
                        .font(Theme.font(15, .semibold))
                        .foregroundStyle(Theme.inkDim)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let book {
                bookProgressBar(book)
            }
        }
        .overlay(Color.black.opacity(dimOpacity)
            .allowsHitTesting(false))
        .onWheel { handle($0) }
        .onAppear {
            if book == nil {                book = model.reader.book(id: bookID)
                // Recents: this book is the one to resume from home.
                if let title = book?.title {
                    model.recents.record(book: .init(id: bookID, title: title))
                }
                if book?.kind == .epub {
                    chapters = EpubParser.load(bookDir: Self.epubDir(for: book!))
                    highlights = HighlightStore.load(bookID: bookID, kind: .epub)
                    liveFraction = book?.scrollFraction ?? 0
                    chapterChars = chapters.map { textLength($0.url) }
                    computeEstimates()
                }
                // QA hook: force reflowed text for a PDF (screenshots/tests).
                if ProcessInfo.processInfo.environment["READER_PDF_REFLOW"] == "1",
                   book?.kind == .pdf, book?.pdfMode != 2 {
                    book?.pdfMode = 2
                    model.reader.update(book!)
                    Logger(subsystem: "com.ipodclassic.app", category: "reader-debug").notice("REFLOW HOOK fired, pdfMode=2")
                }
                if isReflow, let b = book {
                    Logger(subsystem: "com.ipodclassic.app", category: "reader-debug").notice("REFLOW appear: isReflow=true, ensuring chapters")
                    highlights = HighlightStore.load(bookID: bookID, kind: .pdf)
                    liveFraction = fraction(of: b)
                    ensureReflow()
                }
                // QA hook: open a specific chapter (visual checks).
                if let cs = ProcessInfo.processInfo.environment["READER_CHAPTER"],
                   let c = Int(cs), chapters.indices.contains(c), !isReflow {
                    book?.chapterIndex = c
                }
                // QA hook: open at an in-chapter fraction (visual checks).
                if let fs = ProcessInfo.processInfo.environment["READER_FRACTION"],
                   let f = Double(fs), book?.kind == .epub || isReflow {
                    if var b = book { setFraction(f, on: &b); book = b }
                }
                // QA hook: force a font family index (visual checks of the
                // font setting; the styleKey machinery applies it on load).
                if let vis = ProcessInfo.processInfo.environment["READER_FONT"],
                   let v = Int(vis), book?.kind == .epub || isReflow {
                    book?.fontFamily = v
                }
                // QA hook: perform N page turns after load (visual checks).
                if let ts = ProcessInfo.processInfo.environment["READER_TICKS"],
                   let n = Int(ts), book?.kind == .epub {
                    scheduleQATicks(n, controller: epubController)
                }
                // QA hook: open the book settings panel (screenshots).
                if ProcessInfo.processInfo.environment["BOOK_SETTINGS"] == "1" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        panelIsSettings = true
                        panelSelection = 0
                        panelOpen = true
                    }
                }
                // QA hook: start read-aloud automatically (device checks).
                if ProcessInfo.processInfo.environment["READ_ALOUD_START"] == "1" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        startReadAloud()
                    }
                }
            }
            // PDFKit posts selection changes; surface them in the
            // highlight bar (only one PDF view exists in the app).
            if pdfSelectionToken == nil {
                pdfSelectionToken = NotificationCenter.default.addObserver(
                    forName: .PDFViewSelectionChanged, object: nil, queue: .main) { _ in
                        guard self.isPDFOriginal else { return }
                        let text = self.pdfController.view?.currentSelection?.string ?? ""
                        if text.isEmpty {
                            if !self.selectedText.isEmpty {
                                withAnimation(.easeIn(duration: 0.15)) { self.selectedText = "" }
                            }
                        } else {
                            withAnimation(.easeOut(duration: 0.15)) { self.selectedText = text }
                        }
                }
            }
            model.transportClaimedByScreen = true
        }
        .onDisappear {
            model.transportClaimedByScreen = false
            model.audiobook.stop()
            if let token = pdfSelectionToken {
                NotificationCenter.default.removeObserver(token)
                pdfSelectionToken = nil
            }
            saveLocation()
        }
        .onChange(of: model.audiobook.state) { _, state in
            if case .failed(let message) = state {
                showToast(message)
            }
        }
        .onChange(of: styleStamp) { _, _ in
            // Font/margin changes change the page capacity — the old
            // calibration no longer applies, so re-estimate from the prior.
            charsPerPage = 0
            computeEstimates()
        }
        .onChange(of: scenePhase) { _, phase in
            // Leaving the foreground (or quitting) — flush the position;
            // onDisappear alone never runs on a kill or an app update.
            if phase != .active { saveLocation() }
        }
        .task {
            // Rolling autosave. NB: Timer.publish + onReceive would reset
            // on every body re-evaluation (saveLocation mutates state) and
            // never fire; .task survives re-renders.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if !panelOpen { saveLocation() }
            }
        }
    }

    /// The reading surface for the active mode: the original PDF view, a
    /// preparing/no-text placeholder while reflow generates, or the EPUB
    /// web view (EPUB, articles, and reflow all render through it).
    @ViewBuilder
    private func content(book: ReaderStore.Book) -> some View {
        if isPDFOriginal {
            // A little air above and below the pages (the progress bar
            // sits in its own row beneath the reading area).
            PDFBookView(url: Self.pdfURL(for: book), controller: pdfController,
                        initialPage: chapterIndex(of: book), continuous: book.pdfMode != 1)
                .padding(.top, 10)
                .padding(.bottom, 10)
        } else if isReflow && reflowChapters.isEmpty {
            VStack(spacing: 8) {
                Text(reflowPreparing ? "Preparing text…" : "No extractable text")
                    .font(Theme.font(13, .medium))
                    .foregroundStyle(Theme.inkDim)
                if reflowPreparing { ProgressView() }
            }
        } else {
            EpubWebView(
                chapter: chapters.indices.contains(chapterIndex(of: book)) ? chapters[chapterIndex(of: book)] : nil,
                bookDir: Self.epubDir(for: book),
                book: book,
                restoreFraction: fraction(of: book),
                controller: epubController,
                highlightTexts: highlights.filter { $0.chapter == chapterIndex(of: book) }.map(\.text),
                onSelection: { text in
                    withAnimation(.easeOut(duration: 0.15)) { selectedText = text }
                }
            )
        }
    }

    /// Thin whole-book progress line with a tiny page readout (e.g.
    /// "137/412"), in its own row below the reading area — the bar never
    /// covers the text. The readout derives from the same numbers as the
    /// bar fraction, so they always agree.
    private func bookProgressBar(_ book: ReaderStore.Book) -> some View {
        HStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.black.opacity(0.22))
                    Capsule().fill(SelectionGradient())
                        .frame(width: max(5, geo.size.width * progressFraction(book)))
                }
            }
            .frame(height: 4)
            if let pages = pageCountLabel(book) {
                Text(pages)
                    .font(Theme.font(8, .medium))
                    .foregroundStyle(Theme.inkDim)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 10)
    }

    /// Page counts per chapter for progress; unmeasured chapters count as
    /// the average of measured ones (converges to exact as the background
    /// measurement finishes).
    private func chapterPageEstimates() -> [Double] {
        let measured = chapterPages.filter { $0 > 0 }
        let fallback = measured.isEmpty ? 12.0 : Double(measured.reduce(0, +)) / Double(measured.count)
        return chapters.indices.map { i in
            chapterPages.indices.contains(i) && chapterPages[i] > 0
                ? Double(chapterPages[i]) : fallback
        }
    }

    /// Whole-book progress 0–1: the PDF page view centers the current
    /// page in its slot; web-view modes add the live in-chapter fraction
    /// on top of the estimated pages before the current chapter.
    ///
    /// - Returns: 0 when nothing is loaded.
    private func progressFraction(_ book: ReaderStore.Book) -> Double {
        if isPDFOriginal, let count = pdfController.document?.pageCount, count > 0 {
            return (Double(min(chapterIndex(of: book), count - 1)) + 0.5) / Double(count)
        }
        let pages = chapterPageEstimates()
        guard !pages.isEmpty else { return 0 }
        let ch = min(chapterIndex(of: book), pages.count - 1)
        let before = pages.prefix(ch).reduce(0, +)
        let total = max(pages.reduce(0, +), 1)
        return min(1, (before + liveFraction * pages[ch]) / total)
    }

    /// Tiny "current/total" page readout for the progress row; nil while
    /// nothing measurable is loaded (PDF not open, no chapters).
    private func pageCountLabel(_ book: ReaderStore.Book) -> String? {
        if isPDFOriginal {
            guard let count = pdfController.document?.pageCount, count > 0 else { return nil }
            let current = min(chapterIndex(of: book), count - 1) + 1
            return "\(current)/\(count)"
        }
        guard !chapters.isEmpty else { return nil }
        let pages = chapterPageEstimates()
        let ch = min(chapterIndex(of: book), pages.count - 1)
        let before = pages.prefix(ch).reduce(0, +)
        let total = max(Int(pages.reduce(0, +).rounded()), 1)
        let current = min(max(Int((before + liveFraction * pages[ch]).rounded()) + 1, 1), total)
        return "\(current)/\(total)"
    }

    /// Identity of the typography settings; a change invalidates the
    /// page estimates (capacity changed) and triggers re-estimation.
    private var styleStamp: String {
        "\(book?.fontSize ?? 0)|\(book?.fontFamily ?? 0)|\(book?.lineSpacing ?? 0)|\(book?.margin ?? 0)"
    }

    /// Stripped text length of a chapter file — the basis of page
    /// estimates (layout-proportional).
    private func textLength(_ url: URL) -> Int {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        let stripped = raw.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return stripped.count
    }

    /// Pages a chapter of `chars` characters occupies at the current
    /// typography. Calibrated per book once a real count is known;
    /// otherwise a 0.44em average glyph advance prior.
    private func pageCapacity() -> Double {
        if charsPerPage > 0 { return charsPerPage }
        let sides = [10.0, 16.0, 24.0]
        let side: Double = sides[min(max(book?.margin ?? 1, 0), 2)]
        let lineHeights = [1.4, 1.55, 1.75]
        let lineHeight: Double = lineHeights[min(max(book?.lineSpacing ?? 1, 0), 2)]
        let fontSize = Double(book?.fontSize ?? 17)
        let viewW = epubController.webView?.bounds.width ?? 384
        let viewH = epubController.webView?.bounds.height ?? 251
        let vPad = Double((book?.fontSize ?? 17) / 2 + 8)
        let pageW = max(120, viewW - 2 * side)
        let pageH = max(120, viewH - 2 * vPad)
        let charsPerLine = max(8, pageW / (fontSize * 0.44))
        let linesPerPage = max(4, pageH / (fontSize * lineHeight))
        return max(50, charsPerLine * linesPerPage)
    }

    /// Fills `chapterPages` from `chapterChars` at the current capacity.
    /// Estimates only — NEVER re-add an offscreen WKWebView measurer to
    /// "improve" these: iOS WebKit paginates columns asynchronously
    /// (scrollWidth overshoots then tightens, and about:blank races made
    /// the old hidden measurer report every chapter as 1 page). Exact
    /// counts arrive via readerPosition as chapters are visited (see
    /// `exactPages(_:forChapter:)`).
    private func computeEstimates() {
        guard chapterChars.count == chapters.count else { return }
        let cap = pageCapacity()
        chapterPages = chapterChars.map { chars -> Int in
            let pages = (Double(chars) / cap).rounded()
            return max(1, Int(pages))
        }
    }

    /// Exact count for the chapter the web view reports, and recalibration
    /// of every estimate from that data point. Degenerate chapters (a
    /// mostly-empty span) are excluded — one would skew the shared
    /// char-per-page ratio for the whole book.
    private func exactPages(_ n: Int, forChapter ch: Int) {
        guard chapterChars.indices.contains(ch), ch < chapterPages.count, n > 0 else { return }
        let chars = chapterChars[ch]
        if chars > 300 { charsPerPage = Double(chars) / Double(n) }
        computeEstimates()
        chapterPages[ch] = n
    }

    /// Touch action bar shown while text is selected in an EPUB.
    private var selectionBar: some View {
        VStack(spacing: 6) {
            Text(selectedText)
                .lineLimit(2)
                .font(Theme.font(11, .medium))
                .foregroundStyle(Theme.inkDim)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(width: 250, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(white: 0.95))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.black.opacity(0.2), lineWidth: 0.8))
                )
            HStack(spacing: 10) {
                Button(action: saveHighlight) {
                    capsuleLabel("Highlight", primary: true)
                }
                .buttonStyle(.plain)
                Button {
                    if isPDFOriginal {
                        pdfController.clearSelection()
                    } else {
                        epubController.clearSelection()
                    }
                    withAnimation(.easeIn(duration: 0.15)) { selectedText = "" }
                } label: {
                    capsuleLabel("Cancel", primary: false)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 36)
    }

    /// Action-button look for the selection bar.
    private func capsuleLabel(_ text: String, primary: Bool) -> some View {
        Text(text)
            .font(Theme.font(12, .bold))
            .foregroundStyle(primary ? Color.white : Theme.ink)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(Capsule().fill(primary ? AnyShapeStyle(SelectionGradient())
                                               : AnyShapeStyle(Color(white: 0.82))))
    }

    /// Extraction folder of a book's EPUB (also the reflow output root).
    static func epubDir(for book: ReaderStore.Book) -> URL {
        ReaderStore.booksRoot.appendingPathComponent(book.id)
    }

    /// On-disk PDF file of a book.
    static func pdfURL(for book: ReaderStore.Book) -> URL {
        ReaderStore.booksRoot.appendingPathComponent(book.id).appendingPathExtension("pdf")
    }

    // MARK: Panels

    /// One adjustable book setting: title, possible values, current index.
    private struct BookSetting: Identifiable {
        let id: String
        let title: String
        let values: [String]
        var index: Int
    }

    /// Selectable body sizes (px) for the Font Size setting row.
    private static let fontSizes = [11, 13, 15, 17, 19, 22, 25]

    /// Rows for the Book Settings panel; a PDF in reflow mode gets the
    /// full typography set too. ("Read Aloud" activates instead of
    /// cycling; the panel swaps to audiobook rows while it runs.)
    private var bookSettings: [BookSetting] {
        guard let book else { return [] }
        // Read Aloud is the top row in both branches; while an audiobook
        // is active the panel switches to the audiobook rows entirely.
        let readAloud = BookSetting(id: "tts", title: "Read Aloud", values: ["Off"], index: 0)
        if book.kind == .pdf {
            var rows = [readAloud, BookSetting(id: "view", title: "View", values: ["Continuous", "One Page", "Reflowed"],
                                    index: min(max(book.pdfMode, 0), 2))]
            if isReflow {
                let sizeIndex = Self.fontSizes.firstIndex(of: book.fontSize) ?? 3
                rows += [
                    BookSetting(id: "size", title: "Font Size", values: Self.fontSizes.map { "\($0) px" }, index: sizeIndex),
                    BookSetting(id: "family", title: "Font", values: ReaderStore.Book.fontFamilyNames,
                                index: min(max(book.fontFamily, 0), ReaderStore.Book.fontFamilyNames.count - 1)),
                    BookSetting(id: "spacing", title: "Line Spacing", values: ["Compact", "Normal", "Wide"], index: min(max(book.lineSpacing, 0), 2)),
                    BookSetting(id: "margin", title: "Margins", values: ["Narrow", "Normal", "Wide"], index: min(max(book.margin, 0), 2)),
                    BookSetting(id: "scroll", title: "Scroll Step", values: ["Small", "Medium", "Large"], index: min(max(book.scrollStep, 0), 2)),
                ]
            }
            rows.append(BookSetting(id: "dim", title: "Screen", values: ["Bright", "Dim", "Darker"],
                                    index: min(max(book.dim, 0), 2)))
            return rows
        }
        let sizeIndex = Self.fontSizes.firstIndex(of: book.fontSize) ?? 3
        return [
            readAloud,
            BookSetting(id: "size", title: "Font Size", values: Self.fontSizes.map { "\($0) px" }, index: sizeIndex),
            BookSetting(id: "family", title: "Font", values: ReaderStore.Book.fontFamilyNames,
                        index: min(max(book.fontFamily, 0), ReaderStore.Book.fontFamilyNames.count - 1)),
            BookSetting(id: "spacing", title: "Line Spacing", values: ["Compact", "Normal", "Wide"], index: min(max(book.lineSpacing, 0), 2)),
            BookSetting(id: "margin", title: "Margins", values: ["Narrow", "Normal", "Wide"], index: min(max(book.margin, 0), 2)),
            BookSetting(id: "scroll", title: "Scroll Step", values: ["Small", "Medium", "Large"], index: min(max(book.scrollStep, 0), 2)),
            BookSetting(id: "dim", title: "Screen", values: ["Bright", "Dim", "Darker"], index: min(max(book.dim, 0), 2)),
        ]
    }

    /// Rows of whichever panel is open: settings rows, the PDF outline
    /// (indented by level), or EPUB chapters.
    private var panelRows: [MenuItem] {
        if panelIsSettings {
            if model.audiobook.isActive {
                return [
                    MenuItem(id: "ttsState", title: model.audiobook.statusText, showsChevron: false),
                    MenuItem(id: "voice", title: "Voice", detail: model.audiobook.voiceLabel, showsChevron: false),
                    MenuItem(id: "volume", title: "Volume", detail: model.audiobook.volumeLabel, showsChevron: false),
                    MenuItem(id: "speed", title: "Speed", detail: model.audiobook.speedLabel, showsChevron: false),
                    MenuItem(id: "ttsExit", title: "Exit Read Aloud", showsChevron: false),
                ]
            }
            return bookSettings.map { setting in
                MenuItem(id: setting.id, title: setting.title,
                         detail: setting.values.indices.contains(setting.index) ? setting.values[setting.index] : "",
                         showsChevron: false)
            }
        }
        if isPDFOriginal {
            return outline.map { entry in
                let indent = String(repeating: "    ", count: entry.level)
                return MenuItem(id: "out.\(entry.id)", title: indent + entry.title, showsChevron: false)
            }
        }
        return chapters.map { ch in
            MenuItem(id: "ch.\(ch.index)", title: ch.title, showsChevron: false)
        }
    }

    /// The open modal panel over the reading area.
    private var panel: some View {
        ModalPanel(title: panelTitle, onClose: { closePanel() }) {
            MenuList(items: panelRows, selection: panelSelection, compact: true, emptyText: "No Contents")
                .padding(.top, 2)
        }
    }

    /// Title of the open panel.
    private var panelTitle: String {
        if panelIsSettings {
            return model.audiobook.isActive ? "Read Aloud" : "Book Settings"
        }
        return isPDFOriginal ? "Contents" : "Chapters"
    }

    /// Dismisses the open panel.
    private func closePanel() {
        withAnimation(.easeIn(duration: 0.15)) { panelOpen = false }
    }

    /// Opens the contents panel (chapters, or the PDF outline flattened
    /// on first open).
    private func openContents() {
        if isPDFOriginal && outline.isEmpty {
            outline = PDFBookView.flattenOutline(pdfController.document?.outlineRoot, document: pdfController.document)
        }
        panelIsSettings = false
        panelSelection = 0
        withAnimation(.easeOut(duration: 0.18)) { panelOpen = true }
    }

    /// Opens the book-settings panel.
    private func openSettings() {
        panelIsSettings = true
        panelSelection = 0
        withAnimation(.easeOut(duration: 0.18)) { panelOpen = true }
    }

    /// Center-press on a panel row: settings rows cycle their value,
    /// outline rows jump to that page, chapter rows open that chapter
    /// (persisted directly — the old chapter's fraction must not leak
    /// into the new one).
    private func activatePanelRow() {
        let rows = panelRows
        guard rows.indices.contains(panelSelection) else { return }
        if panelIsSettings {
            cycleSetting(id: rows[panelSelection].id)
            return
        }
        let id = rows[panelSelection].id
        if isPDFOriginal {
            let idx = Int(id.dropFirst("out.".count)) ?? 0
            if outline.indices.contains(idx), let page = outline[idx].pageIndex {
                pdfController.goToPage(page)
                book?.chapterIndex = page
            }
            saveLocation()
        } else {
            let idx = Int(id.dropFirst("ch.".count)) ?? 0
            if chapters.indices.contains(idx), var b = book {
                setChapter(idx, on: &b)
                setFraction(0, on: &b)
                book = b
                // Persist directly; sampling the old chapter's fraction
                // here would mis-restore the new one.
                model.reader.update(b)
            }
        }
        closePanel()
    }

    /// Cycles one setting to its next value and applies it immediately.
    private func cycleSetting(id: String) {
        guard var b = book else { return }
        /// Next index in a 0..<count cycle (wrap past the end).
        func wrapped(_ current: Int, _ count: Int) -> Int { (current + 1) % count }
        switch id {
        case "view":
            // Continuous → One Page → Reflowed → Continuous…
            let next = isReflow ? 0 : (b.pdfMode + 1) % 3
            switchViewMode(next, on: &b)
        case "size":
            let idx = max(0, Self.fontSizes.firstIndex(of: b.fontSize) ?? 1)
            b.fontSize = Self.fontSizes[wrapped(idx, Self.fontSizes.count)]
            epubController.applyStyle(to: b)
        case "family":
            b.fontFamily = wrapped(min(max(b.fontFamily, 0), ReaderStore.Book.fontFamilyNames.count - 1),
                                   ReaderStore.Book.fontFamilyNames.count)
            epubController.applyStyle(to: b)
        case "spacing":
            b.lineSpacing = wrapped(min(max(b.lineSpacing, 0), 2), 3)
            epubController.applyStyle(to: b)
        case "margin":
            b.margin = wrapped(min(max(b.margin, 0), 2), 3)
            epubController.applyStyle(to: b)
        case "scroll":
            b.scrollStep = wrapped(min(max(b.scrollStep, 0), 2), 3)
        case "dim":
            b.dim = wrapped(min(max(b.dim, 0), 2), 3)
        case "tts":
            // Not a cycle: activates read-aloud from the settings row.
            startReadAloud()
            return
        case "ttsState":
            // Status display row — nothing to cycle.
            return
        case "voice":
            model.audiobook.voiceIndex += 1
            return
        case "volume":
            model.audiobook.volumeIndex += 1
            return
        case "speed":
            model.audiobook.speedIndex += 1
            return
        case "ttsExit":
            model.audiobook.stop()
            showToast("Read Aloud off")
            closePanel()
            return
        default:
            break
        }
        book = b
        model.reader.update(b)
    }

    /// Switches the PDF view mode. Position: leaving reflow persists its
    /// own fields untouched (the direct update deliberately skips position
    /// sampling — see stepChapter); the page view keeps its page index.
    private func switchViewMode(_ mode: Int, on b: inout ReaderStore.Book) {
        guard b.pdfMode != mode else { return }
        b.pdfMode = mode
        if mode == 2 {
            ensureReflow()
        } else if !reflowChapters.isEmpty || reflowPreparing {
            showToast(mode == 0 ? "Continuous" : "One Page")
        }
    }

    /// Generates the reflowed text chapters once (cached on disk).
    private func ensureReflow() {
        guard let b = book, isReflow, !reflowPreparing, reflowChapters.isEmpty else { return }
        reflowPreparing = true
        let pdfURL = Self.pdfURL(for: b)
        let outDir = Self.epubDir(for: b).appendingPathComponent("reflow", isDirectory: true)
        Task {
            let doc = PDFDocument(url: pdfURL)
            let entries: [OutlineEntry] = await MainActor.run {
                PDFBookView.flattenOutline(doc?.outlineRoot, document: doc)
            }
            let spans = PDFReflow.spans(outline: entries, pageCount: doc?.pageCount ?? 0)
            let generated = await PDFReflow.generateChapters(pdfURL: pdfURL, outDir: outDir, spans: spans)
            await MainActor.run {
                // Image-only PDF (no extractable text anywhere): back to
                // page view. Judge by TOTAL text — the first outline span
                // is often just the image cover/title pages (e.g. Lost
                // City of the Monkey God), which must not veto reflow.
                let totalBytes = generated.reduce(0) { sum, ch -> Int in
                    sum + ((try? FileManager.default.attributesOfItem(atPath: ch.url.path))?[.size] as? Int ?? 0)
                }
                // Drop degenerate chapters (image cover/title spans with
                // no extractable text): they'd render as blank pages and
                // their exact-count recalibration would poison the global
                // char-per-page estimate.
                let usable = generated.filter { ch -> Bool in
                    let size = (try? FileManager.default.attributesOfItem(atPath: ch.url.path))?[.size] as? Int ?? 0
                    return size > 200
                }
                guard !usable.isEmpty, totalBytes > 200 else {
                    reflowPreparing = false
                    if var bb = book {
                        bb.pdfMode = 0
                        book = bb
                        model.reader.update(bb)
                    }
                    Logger(subsystem: "com.ipodclassic.app", category: "reader-debug").notice("REFLOW REVERT: generated=\(generated.count) totalBytes=\(totalBytes)")
                    showToast("No extractable text")
                    return
                }
                Logger(subsystem: "com.ipodclassic.app", category: "reader-debug").notice("REFLOW OK: chapters=\(usable.count)/\(generated.count) totalBytes=\(totalBytes)")
                reflowChapters = usable
                chapters = usable
                chapterPages = Array(repeating: 0, count: usable.count)
                reflowPreparing = false
                // QA hooks (reflow chapters only exist after generation).
                if let cs = ProcessInfo.processInfo.environment["READER_CHAPTER"],
                   let c = Int(cs), usable.indices.contains(c), var bb = book {
                    setChapter(c, on: &bb)
                    book = bb
                }
                if let fs = ProcessInfo.processInfo.environment["READER_FRACTION"],
                   let f = Double(fs), var bb = book {
                    setFraction(f, on: &bb)
                    liveFraction = f
                    book = bb
                }
                if let ts = ProcessInfo.processInfo.environment["READER_TICKS"],
                   let n = Int(ts) {
                    scheduleQATicks(n, controller: epubController)
                }
                if let bb = book {
                    chapterChars = generated.map { textLength($0.url) }
                    liveFraction = fraction(of: bb)
                    computeEstimates()
                }
            }
        }
    }

    /// QA: N page turns after the web view settles, then log the fraction.
    private func scheduleQATicks(_ n: Int, controller: EpubController) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            for i in 0..<n {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2 * Double(i)) {
                    controller.scrollByPages(1)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2 * Double(n) + 0.3) {
                controller.scrollFraction { f in
                    Logger(subsystem: "com.ipodclassic.app", category: "qa").notice("TICKS DONE fraction=\(f, privacy: .public)")
                }
            }
        }
    }

    // MARK: Read aloud

    /// Starts audiobook mode at the page the reader is showing. Music
    /// yields — one audio source at a time.
    @MainActor private func startReadAloud() {
        guard book != nil else { return }
        if model.player.isPlaying { model.player.togglePlayPause() }
        model.audiobook.start(provider: makeAudiobookProvider())
        closePanel()
        showToast("Read Aloud starting")
    }

    /// Bundles this screen's rendering closures into the model-facing
    /// provider (the model stays ignorant of WKWebView/PDFKit).
    @MainActor private func makeAudiobookProvider() -> AudiobookPageProvider {
        AudiobookPageProvider(
            segments: { await self.audiobookSegments() },
            showPage: { self.audiobookShowPage($0) },
            currentPage: { await self.audiobookCurrentPage() },
            stepChapter: { self.audiobookStepChapter($0) },
            language: { await self.audiobookLanguage() }
        )
    }

    /// Page-view PDFs speak the current PDF page only; everything through
    /// the web view (EPUB, articles, reflow) speaks the whole chapter
    /// bucketed per page via the DOM extraction.
    @MainActor private func audiobookSegments() async -> [AudiobookSegment] {
        guard book != nil else { return [] }
        if isPDFOriginal {
            let idx = pdfController.currentPageIndex
            let text = pdfController.document?.page(at: idx)?.string ?? ""
            return text.isEmpty ? [] : [AudiobookSegment(page: idx, text: text)]
        }
        return await epubController.chapterSegments()
    }

    /// Turns the real reader to `page` — the same page turns manual
    /// reading uses, so position persistence just works.
    @MainActor private func audiobookShowPage(_ page: Int) {
        guard book != nil else { return }
        if isPDFOriginal {
            pdfController.goToPage(page)
            book?.chapterIndex = page
        } else {
            epubController.scrollToPage(page)
            epubController.readerPosition { f, n in
                self.liveFraction = f
                if let b = self.book, let n, !self.isPDFOriginal {
                    self.exactPages(n, forChapter: self.chapterIndex(of: b))
                }
            }
        }
    }

    /// Page index the reader is currently showing — where playback
    /// starts and where seeks re-land.
    @MainActor private func audiobookCurrentPage() async -> Int {
        guard book != nil else { return 0 }
        if isPDFOriginal { return pdfController.currentPageIndex }
        let (f, n) = await epubController.readerPositionAsync()
        guard let n, n > 0 else { return 0 }
        return min(n - 1, max(0, Int((f * Double(n)).rounded())))
    }

    /// Chapter step (PDF page-view: page step). Returns whether the
    /// position actually moved — false ends the book.
    @MainActor private func audiobookStepChapter(_ delta: Int) -> Bool {
        guard var b = book else { return false }
        if isPDFOriginal {
            let before = pdfController.currentPageIndex
            if delta > 0 { pdfController.nextPage() } else { pdfController.prevPage() }
            let after = pdfController.currentPageIndex
            b.chapterIndex = after
            book = b
            return after != before
        }
        let next = chapterIndex(of: b) + delta
        guard chapters.indices.contains(next) else { return false }
        setChapter(next, on: &b)
        setFraction(0, on: &b)
        liveFraction = 0
        book = b
        model.reader.update(b)
        return true
    }

    /// Language for synthesis, detected over the first pages of the
    /// current chapter (stopword counts).
    @MainActor private func audiobookLanguage() async -> String {
        let segments = await audiobookSegments()
        let text = segments.prefix(3).map(\.text).joined(separator: " ")
        return AudiobookLanguage.detect(text)
    }

    // MARK: Actions

    /// Wraps the current selection in a persistent mark (EPUB: DOM marks;
    /// PDF: highlight annotations written into the file), stores it, and
    /// mirrors it into the book's Highlights note.
    private func saveHighlight() {
        guard var b = book else { return }
        if !isPDFOriginal {
            // EPUB and reflowed text both highlight through the DOM.
            epubController.wrapSelection { text in
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                withAnimation(.easeIn(duration: 0.15)) { selectedText = "" }
                guard !trimmed.isEmpty else { return }
                let highlight = BookHighlight(id: UUID().uuidString, chapter: chapterIndex(of: b), text: trimmed)
                highlights.append(highlight)
                HighlightStore.save(highlights, bookID: b.id, kind: b.kind)
                appendHighlightToNotes(highlight, book: b)
                showToast("Highlighted")
            }
        } else {
            pdfHighlightSelection(book: b)
        }
    }

    /// PDF: native annotation highlighting; annotations are saved into the
    /// PDF file itself so they stay with the book.
    private func pdfHighlightSelection(book: ReaderStore.Book) {
        guard let selection = pdfController.view?.currentSelection,
              let text = selection.string, !text.isEmpty else {
            withAnimation(.easeIn(duration: 0.15)) { selectedText = "" }
            return
        }
        for page in selection.pages {
            let bounds = selection.bounds(for: page)
            let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
            annotation.color = UIColor.systemYellow.withAlphaComponent(0.4)
            page.addAnnotation(annotation)
        }
        pdfController.clearSelection()
        _ = pdfController.document?.write(to: Self.pdfURL(for: book))
        let highlight = BookHighlight(id: UUID().uuidString,
                                      chapter: pdfController.currentPageIndex,
                                      text: text)
        appendHighlightToNotes(highlight, book: book)
        withAnimation(.easeIn(duration: 0.15)) { selectedText = "" }
        showToast("Highlighted")
    }

    /// Mirror into Documents/Notes — one line per highlight: - "text"
    private func appendHighlightToNotes(_ highlight: BookHighlight, book: ReaderStore.Book) {
        let noteName = "\(book.title) - Highlights"
        let body = model.notes.read(noteName)
        model.notes.write(noteName, "\(body)- \"\(highlight.text)\"\n")
    }

    /// prev/next handler: one chapter (PDF page view: one page). EPUB
    /// steps persist directly rather than via `saveLocation()` — the
    /// async position callback would sample the OLD chapter's fraction
    /// and restore the new one near its bottom.
    private func stepChapter(_ delta: Int) {
        guard var b = book else { return }
        if isPDFOriginal {
            if delta > 0 { pdfController.nextPage() } else { pdfController.prevPage() }
            b.chapterIndex = pdfController.currentPageIndex
            book = b
            saveLocation()
        } else {
            let next = chapterIndex(of: b) + delta
            guard chapters.indices.contains(next) else {
                showToast(delta > 0 ? "End of Book" : "Start of Book")
                return
            }
            setChapter(next, on: &b)
            setFraction(0, on: &b)
            liveFraction = 0
            book = b
            // Persist directly — saveLocation() would sample the OLD
            // chapter's scroll fraction (async callback) and the new
            // chapter would restore near its bottom.
            model.reader.update(b)
        }
    }

    /// Asks the web view for the current scroll position, then persists.
    private func saveLocation() {
        guard var b = book else { return }
        if isPDFOriginal {
            b.chapterIndex = pdfController.currentPageIndex
            model.reader.update(b)
            book = b
        } else {
            epubController.readerPosition { fraction, n in
                self.setFraction(fraction, on: &b)
                self.model.reader.update(b)
                DispatchQueue.main.async { self.book = b }
                if let n, let bb = self.book, !self.isPDFOriginal {
                    self.exactPages(n, forChapter: self.chapterIndex(of: bb))
                }
            }
        }
    }

    /// Shows a transient toast; it fades out after ~1.4 s.
    private func showToast(_ text: String) {
        withAnimation(.easeOut(duration: 0.2)) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation(.easeIn(duration: 0.3)) { toast = "" }
        }
    }

    // MARK: Input

    /// Wheel routing. Ticks page-turn the active renderer (1–3 pages
    /// per tick per Scroll Step) and flag the audiobook to re-sync;
    /// center opens contents, or play/pauses while read-aloud runs;
    /// MENU closes the panel, then audiobook mode, then the book.
    private func handle(_ event: ControlEvent) {
        switch event {
        case .tick(let d):
            WheelFeedback.tick(dir: d)
            if panelOpen {
                moveListSelection(&panelSelection, count: panelRows.count, delta: d, settings: settings)
            } else if isPDFOriginal {
                if d > 0 { pdfController.nextPage() } else { pdfController.prevPage() }
                model.audiobook.readerMoved(to: pdfController.currentPageIndex)
                // currentPage settles asynchronously; keep the progress
                // bar honest. The delayed echo reports the SETTLED page —
                // if the loop is already speaking it, readerMoved(to:)
                // ignores it (a same-page echo restarted the page
                // mid-sentence).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    if self.isPDFOriginal {
                        self.book?.chapterIndex = self.pdfController.currentPageIndex
                    }
                    self.model.audiobook.readerMoved(to: self.pdfController.currentPageIndex)
                }
            } else {
                // Instant viewport-fraction jumps track the wheel 1:1.
                // Column paging: one wheel tick turns a page (or several,
                // per the Scroll Step setting). Instant, no animation.
                let pages = [1, 2, 3][min(max(book?.scrollStep ?? 0, 0), 2)]
                epubController.scrollByPages(d > 0 ? pages : -pages)
                model.audiobook.readerMoved()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    // Exact page count for the open chapter converges the
                    // whole book's estimates as a side effect.
                    self.epubController.readerPosition { f, n in
                        self.liveFraction = f
                        if let b = self.book, let n, !self.isPDFOriginal {
                            self.exactPages(n, forChapter: self.chapterIndex(of: b))
                        }
                        // Wheel = seek while reading aloud: the loop
                        // re-syncs to the page now showing — UNLESS the
                        // loop already turned here itself (same-page echo
                        // guard, see readerMoved(to:)).
                        if let n, n > 0 {
                            let shown = min(n - 1, max(0, Int((f * Double(n)).rounded())))
                            self.model.audiobook.readerMoved(to: shown)
                        } else {
                            self.model.audiobook.readerMoved()
                        }
                    }
                }
            }
        case .select:
            if panelOpen {
                activatePanelRow()
            } else if model.audiobook.isActive {
                // While read-aloud is active, center = play/pause.
                model.audiobook.togglePlayPause()
                showToast(model.audiobook.state == .playing ? "Reading" : "Paused")
            } else {
                openContents()
            }
        case .playPause:
            // The reader claims transport while open; without an active
            // audiobook the buttons do nothing here (music is stopped).
            if model.audiobook.isActive {
                model.audiobook.togglePlayPause()
                showToast(model.audiobook.state == .playing ? "Reading" : "Paused")
            }
        case .centerHold:
            // Hold center: book settings (both PDF and EPUB).
            guard !panelOpen, book != nil else { break }
            WheelHaptics.shared.ensureRunning()
            WheelHaptics.shared.buttonPress(strength: 0.85)
            openSettings()
        case .next, .nextHold:
            stepChapter(1)
        case .prev, .prevHold:
            stepChapter(-1)
        case .menu:
            if panelOpen {
                closePanel()
            } else if model.audiobook.isActive {
                // First MENU leaves audiobook mode; a second one exits the book.
                model.audiobook.stop()
                showToast("Read Aloud off")
            } else {
                saveLocation()
                model.pop()
            }
        default:
            break
        }
    }
}

// MARK: - EPUB rendering

/// Command handle for the parent screen to drive the web view.
final class EpubController {
    /// The live web view, set by EpubWebView (weak — SwiftUI owns the view).
    weak var webView: WKWebView?

    /// Turns `count` pages (negative = backwards). A column period is one
    /// viewport width (column + equal gap = 100vw), so integer multiples
    /// land exactly on page starts, symmetric margins included.
    /// Scrolled through the DOM — WebKit owns the horizontal offset and
    /// reverts native scrollView writes.
    func scrollByPages(_ count: Int) {
        webView?.evaluateJavaScript("window.scrollBy(window.innerWidth * \(count), 0)", completionHandler: nil)
        if ProcessInfo.processInfo.environment["READER_DEBUG"] == "1" {
            webView?.evaluateJavaScript("""
            (function(){
              var b = document.body.getBoundingClientRect();
              return JSON.stringify({innerW: window.innerWidth, innerH: window.innerHeight,
                clientW: document.documentElement.clientWidth,
                scrollW: document.documentElement.scrollWidth,
                bodyX: b.x, bodyW: b.width, dpr: window.devicePixelRatio,
                visualScale: window.visualViewport ? window.visualViewport.scale : null,
                visualW: window.visualViewport ? window.visualViewport.width : null});
            })()
            """) { v, _ in
                Logger(subsystem: "com.ipodclassic.app", category: "reader-debug").notice("GEOM \(v as? String ?? "?", privacy: .public)")
            }
        }
    }

    /// Re-injects the reader stylesheet after a settings change.
    ///
    /// Concept: webkit-wkwebview → docs/concepts/webkit-wkwebview.md
    func applyStyle(to book: ReaderStore.Book) {
        webView?.evaluateJavaScript(EpubController.cssJS(for: book), completionHandler: nil)
    }

    /// Wraps the current selection in persistent marks; returns its text.
    func wrapSelection(completion: @escaping (String) -> Void) {
        webView?.evaluateJavaScript(HighlightJS.wrapSelection) { value, _ in
            let text = value as? String ?? ""
            DispatchQueue.main.async { completion(text) }
        }
    }

    /// Collapses the text selection without altering the DOM.
    func clearSelection() {
        webView?.evaluateJavaScript(HighlightJS.clearSelection, completionHandler: nil)
    }

    /// Current position as a fraction of pages through the chapter, plus
    /// the chapter's real laid-out page count (maxIdx). Read from the DOM:
    /// page turns go through window.scrollBy and WebKit does not mirror
    /// horizontal DOM scroll into the native scrollView offset (which
    /// stays 0 — reading it would always save page 0).
    func readerPosition(completion: @escaping (Double, Int?) -> Void) {
        let js = """
        (function(){
          var period = window.innerWidth;
          var max = document.documentElement.scrollWidth - window.innerWidth;
          if (max <= 0) return {f: 1, n: 1};
          var maxIdx = Math.max(1, Math.round(max / period));
          var idx = Math.min(maxIdx, Math.max(0, Math.round(window.scrollX / period)));
          return {f: idx / maxIdx, n: maxIdx};
        })()
        """
        webView?.evaluateJavaScript(js) { value, _ in
            guard let dict = value as? [String: Any] else {
                DispatchQueue.main.async { completion(0, nil) }
                return
            }
            let f = (dict["f"] as? NSNumber)?.doubleValue ?? 0
            let n = (dict["n"] as? NSNumber)?.intValue
            DispatchQueue.main.async { completion(min(max(f, 0), 1), n) }
        }
    }

    /// Fraction-only convenience over `readerPosition`.
    func scrollFraction(completion: @escaping (Double) -> Void) {
        readerPosition { f, _ in completion(f) }
    }

    /// Jumps to the page nearest to `fraction` through the chapter (DOM
    /// scroll — WebKit reverts native horizontal offsets).
    func restorePosition(fraction: Double) {
        let js = """
        (function(){
          var period = window.innerWidth;
          var max = document.documentElement.scrollWidth - window.innerWidth;
          if (max <= 0) { window.scrollTo(0, 0); return; }
          var maxIdx = Math.max(1, Math.round(max / period));
          var idx = Math.round(\(fraction) * maxIdx);
          window.scrollTo(idx * period, 0);
        })()
        """
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: Read-aloud support

    /// URL whose didFinish navigation has fired; page extraction waits
    /// until the web view's current URL matches it.
    var lastFinishedURL: URL?

    /// Jumps to an exact page index (audiobook page sync — DOM scroll,
    /// same path as page turns).
    @MainActor func scrollToPage(_ page: Int) {
        webView?.evaluateJavaScript("window.scrollTo(window.innerWidth * \(page), 0)", completionHandler: nil)
    }

    /// Async flavor of `readerPosition` for the audiobook loop.
    ///
    /// - Returns: (fraction 0–1, page count or nil).
    @MainActor func readerPositionAsync() async -> (Double, Int?) {
        await withCheckedContinuation { continuation in
            readerPosition { fraction, count in
                continuation.resume(returning: (fraction, count))
            }
        }
    }

    /// Waits until the loaded chapter's didFinish has fired (and layout
    /// has had a beat to settle, mirroring the double restore in the
    /// navigation delegate), so page geometry is trustworthy. Retries
    /// well past the initial load window — returning early would make an
    /// un-settled chapter look like an empty one and get skipped.
    @MainActor func awaitChapterSettled() async -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let url = webView?.url, url == lastFinishedURL {
                try? await Task.sleep(nanoseconds: 700_000_000)
                return true
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        Logger(subsystem: "com.ipodclassic.app", category: "tts")
            .notice("chapter settle timeout url=\(self.webView?.url?.lastPathComponent ?? "nil", privacy: .public) finished=\(self.lastFinishedURL?.lastPathComponent ?? "nil", privacy: .public)")
        return false
    }

    /// JSON shape returned by the segments script (short keys keep the
    /// bridge payload small).
    private struct RawSegment: Codable {
        let p: Int
        let t: String
    }

    /// The chapter's text bucketed per page: split every text node into
    /// sentences, map each to its column via the range's document-space
    /// rect (page = floor((rect.left + scrollX) / viewportWidth)), then
    /// merge consecutive same-page sentences into one speakable unit.
    ///
    /// The sentence splitter is a MANUAL scanner, not a global-regex exec
    /// loop: a regex match can only START where a sentence pattern fits,
    /// so a mid-word dot (www.gutenberg.org, "Mr.", initials) made exec
    /// skip forward past everything between the previous sentence and the
    /// next matchable position — silently DROPPING chunks of text (heard
    /// as "Read Aloud skips sentences"; 112 of 134 paragraphs in a real
    /// book lost pieces). The scanner consumes every character: a dot run
    /// is a boundary only when followed by a closer/whitespace/end, and
    /// all preceding text stays in the current piece. Pieces reassemble
    /// to the node exactly.
    /// Static script — no interpolation.
    private static let segmentsJS = """
    (function(){
      var period = window.innerWidth;
      var out = [];
      function sentences(text) {
        var res = [], start = 0, i = 0, n = text.length;
        while (i < n) {
          var c = text[i];
          if (c === '.' || c === '!' || c === '?' || c === '…') {
            var j = i + 1;
            while (j < n && '.!?…'.indexOf(text[j]) >= 0) j++;
            var k = j;
            while (k < n && '"\\')\\u201d\\u2019]'.indexOf(text[k]) >= 0) k++;
            if (k >= n || /\\s/.test(text[k])) {
              var end = k < n ? k + 1 : k;
              res.push(text.slice(start, end));
              start = end; i = end;
              continue;
            }
            i = j;
            continue;
          }
          if (c === '\\n' || c === '\\r') {
            res.push(text.slice(start, i + 1));
            start = i + 1;
          }
          i++;
        }
        if (start < n) res.push(text.slice(start));
        return res;
      }
      var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
      var node;
      while ((node = walker.nextNode())) {
        var tag = node.parentElement ? node.parentElement.tagName : '';
        if (tag === 'STYLE' || tag === 'SCRIPT') continue;
        var text = node.nodeValue;
        if (!text || !text.trim()) continue;
        var pos = 0;
        var pieces = sentences(text);
        for (var idx = 0; idx < pieces.length; idx++) {
          var piece = pieces[idx];
          if (!piece.trim()) { pos += piece.length; continue; }
          var r = document.createRange();
          r.setStart(node, pos);
          r.setEnd(node, pos + piece.length);
          pos += piece.length;
          var rect = r.getBoundingClientRect();
          if (!rect || (rect.width < 0.5 && rect.height < 0.5)) continue;
          var page = Math.max(0, Math.floor((rect.left + window.scrollX) / period));
          out.push({p: page, t: piece.replace(/\\s+/g, ' ').trim()});
        }
      }
      var merged = [];
      for (var i = 0; i < out.length; i++) {
        var last = merged[merged.length - 1];
        if (last && last.p === out[i].p) { last.t += ' ' + out[i].t; }
        else merged.push({p: out[i].p, t: out[i].t});
      }
      for (var j = 0; j < merged.length; j++) merged[j].t = merged[j].t.trim();
      return JSON.stringify(merged);
    })()
    """

    /// Per-page segments for the loaded chapter (EPUB, article, or PDF
    /// reflow — everything that renders through the web view).
    @MainActor func chapterSegments() async -> [AudiobookSegment] {
        guard await awaitChapterSettled(), let webView else { return [] }
        let raw: String? = await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(Self.segmentsJS) { value, _ in
                continuation.resume(returning: value as? String)
            }
        }
        guard let data = raw?.data(using: .utf8),
              let items = try? JSONDecoder().decode([RawSegment].self, from: data) else { return [] }
        return items.filter { !$0.t.isEmpty }.map { AudiobookSegment(page: $0.p, text: $0.t) }
    }

    /// Reader stylesheet: viewport-sized columns (true pages). Body is
    /// one viewport tall, so the browser fills columns with COMPLETE
    /// lines only; side margins come from body padding + an equal column
    /// gap, giving every page identical breathing room.
    ///
    /// Built with SINGLE-backslash interpolation — `\\(x)` here would
    /// emit the literal text `\(x)` and silently break the CSS.
    /// Concept: WKWebView → docs/concepts/webkit-wkwebview.md
    static func cssJS(for book: ReaderStore.Book) -> String {
        let family = ReaderStore.Book.fontFamilyStacks[
            min(max(book.fontFamily, 0), ReaderStore.Book.fontFamilyStacks.count - 1)
        ]
        let lineHeights = [1.4, 1.55, 1.75]
        let lineHeight = lineHeights[min(max(book.lineSpacing, 0), lineHeights.count - 1)]
        let paddings = [10, 16, 24]
        let side = paddings[min(max(book.margin, 0), paddings.count - 1)]
        let vPad = book.fontSize / 2 + 8
        return """
        (function(){
          var s = document.getElementById('ipod-reader-css');
          if (!s) { s = document.createElement('style'); s.id = 'ipod-reader-css'; document.head.appendChild(s); }
          s.textContent = "html{scroll-behavior:auto !important;font-size:\(book.fontSize)px !important;-webkit-text-size-adjust:100% !important;} body{margin:\(vPad)px \(side)px !important;height:calc(100vh - \(2 * vPad)px) !important;column-width:calc(100vw - \(2 * side)px) !important;column-gap:\(2 * side)px !important;column-fill:auto !important;font-size:\(book.fontSize)px !important;line-height:\(lineHeight) !important;font-family:\(family) !important;text-align:left !important;overflow-wrap:break-word !important;-webkit-hyphens:auto !important;hyphens:auto !important;orphans:2 !important;widows:2 !important;} p,div,li,blockquote,section,article,aside,td,th,dd,dt,figcaption,h1,h2,h3,h4,h5,h6{font-size:inherit !important;text-align:left !important;} mark.ipod-hl{background:rgba(255,208,0,0.45) !important;color:inherit !important;} img,svg,video{max-width:100% !important;height:auto !important;} pre,code{white-space:pre-wrap !important;word-break:break-word !important;}";
        })()
        """
    }
}

/// Reflowing EPUB document view. Chapters are XHTML rendered natively by
/// the web view (reflow is inherent); we inject a reader stylesheet built
/// from the book's settings, restore the saved scroll position on load,
/// watch text selection (highlighting), and re-wrap saved highlights.
struct EpubWebView: UIViewRepresentable {
    /// Chapter to render; nil = nothing loadable yet.
    let chapter: EpubChapter?
    /// Root folder the web view may read (EPUB resources load relatively).
    let bookDir: URL
    /// Settings source for the injected stylesheet.
    let book: ReaderStore.Book
    /// In-chapter position (0–1) to restore once layout settles.
    let restoreFraction: Double
    /// Parent screen's command handle; receives the created web view.
    let controller: EpubController
    /// Saved highlight texts for THIS chapter (re-wrapped after load).
    var highlightTexts: [String] = []
    /// Selection-change callback driving the highlight action bar.
    var onSelection: ((String) -> Void)?

    /// Creates the web view: horizontal-column scroll config, a
    /// document-start user script injecting a device-width viewport when
    /// the book lacks one (otherwise WebKit lays out at 980 px and each
    /// page shows a slice), a document-end selection watcher, and the
    /// "selection" message handler; then loads the first chapter.
    ///
    /// Concept: webkit-wkwebview → docs/concepts/webkit-wkwebview.md
    func makeUIView(context: Context) -> WKWebView {
        let wv = WKWebView(frame: .zero)
        wv.navigationDelegate = context.coordinator
        wv.scrollView.indicatorStyle = .black
        wv.backgroundColor = .systemBackground
        // Pages are horizontal columns: no bounce overshoot, no insets —
        // the column layout reserves its own breathing room.
        wv.scrollView.bounces = false
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        wv.scrollView.contentInset = .zero
        // Books without <meta viewport> lay out at 980px (desktop width),
        // so the visible 384pt window shows only a slice of each page.
        // Force the layout viewport to the device width before first use.
        let viewportScript = WKUserScript(source: """
        document.addEventListener('DOMContentLoaded', function(){
          if (!document.querySelector('meta[name=viewport]')) {
            var m = document.createElement('meta');
            m.name = 'viewport';
            m.content = 'width=device-width, initial-scale=1';
            document.head.appendChild(m);
          }
        });
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        let cfg = wv.configuration.userContentController
        cfg.addUserScript(viewportScript)
        cfg.addUserScript(WKUserScript(source: HighlightJS.selectionWatch,
                                       injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        cfg.add(context.coordinator, name: "selection")
        controller.webView = wv
        if let chapter {
            context.coordinator.loadedURL = chapter.url
            context.coordinator.appliedStyle = book
            wv.loadFileURL(chapter.url, allowingReadAccessTo: bookDir)
        }
        return wv
    }

    /// Reloads when the chapter changes; re-injects the stylesheet only
    /// when style-relevant fields changed (see `styleMatches`).
    func updateUIView(_ wv: WKWebView, context: Context) {
        context.coordinator.parent = self
        controller.webView = wv
        if let chapter, context.coordinator.loadedURL != chapter.url {
            context.coordinator.loadedURL = chapter.url
            wv.loadFileURL(chapter.url, allowingReadAccessTo: bookDir)
        } else if !styleMatches(context.coordinator.appliedStyle, book) {
            context.coordinator.appliedStyle = book
            wv.evaluateJavaScript(EpubController.cssJS(for: book), completionHandler: nil)
        }
    }

    /// Only style-relevant fields — position/highlight saves mutate the
    /// book constantly and must NOT re-inject the stylesheet (a re-layout
    /// on every autosave is churn at best and a scroll reset at worst).
    private func styleMatches(_ a: ReaderStore.Book?, _ b: ReaderStore.Book) -> Bool {
        guard let a else { return false }
        return a.fontSize == b.fontSize && a.fontFamily == b.fontFamily
            && a.lineSpacing == b.lineSpacing && a.margin == b.margin
    }

    /// SwiftUI coordinator factory (delegate + script-message target).
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    /// Bridges web-view callbacks back to SwiftUI, holding the newest
    /// parent (the struct is recreated on every re-render).
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        /// Latest view values (kept current by updateUIView).
        var parent: EpubWebView
        /// Chapter currently loaded — guards against redundant loads.
        var loadedURL: URL?
        /// Book snapshot whose stylesheet was applied — guards against
        /// re-injecting identical CSS.
        var appliedStyle: ReaderStore.Book?

        /// Keeps the newest view values.
        init(parent: EpubWebView) {
            self.parent = parent
        }

        /// Selection-watch messages hop to the main thread here.
        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "selection", let text = message.body as? String else { return }
            DispatchQueue.main.async { self.parent.onSelection?(text) }
        }

        /// Load settled: record the URL (page extraction waits for it),
        /// inject the stylesheet, restore saved highlights, then restore
        /// the scroll position — twice, because reflow/images change the
        /// document height after the first pass (both restores are
        /// idempotent, and the second never yanks back once reading has
        /// moved on).
        func webView(_ webview: WKWebView, didFinish navigation: WKNavigation!) {
            // Inject the reader stylesheet, restore highlights, then the
            // saved scroll position. Reflow (CSS + images) changes the
            // document height, so restore twice: immediately and again
            // after layout settles — both are idempotent.
            parent.controller.lastFinishedURL = webview.url
            webview.evaluateJavaScript(EpubController.cssJS(for: parent.book), completionHandler: nil)
            if !parent.highlightTexts.isEmpty {
                webview.evaluateJavaScript(HighlightJS.restore(texts: parent.highlightTexts), completionHandler: nil)
            }
            let fraction = parent.restoreFraction
            let controller = parent.controller
            controller.restorePosition(fraction: fraction)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                // Correct the first restore if layout was still settling —
                // but NEVER yank back if reading already started (the
                // entry position would stomp the current page).
                controller.webView?.evaluateJavaScript("window.scrollX") { value, _ in
                    let x = (value as? NSNumber)?.doubleValue ?? 0
                    if x < 1 {
                        controller.restorePosition(fraction: fraction)
                    }
                }
            }
        }
    }
}

// MARK: - PDF rendering

/// One flattened PDF outline entry.
struct OutlineEntry: Identifiable {
    let id: Int
    let title: String
    /// Resolved page index; nil when the destination doesn't land on a page.
    let pageIndex: Int?
    let level: Int
}

/// Command handle for the parent screen to drive the PDF view.
final class PDFBookController {
    /// The live PDF view, set by PDFBookView (weak).
    weak var view: PDFView?

    /// The open document, via the attached view.
    var document: PDFDocument? { view?.document }

    /// Steps one page forward.
    func nextPage() { view?.goToNextPage(nil) }
    /// Steps one page backward.
    func prevPage() { view?.goToPreviousPage(nil) }

    /// Clears the text selection.
    func clearSelection() {
        view?.clearSelection()
    }

    /// Jumps to a page index (bounds-checked — this SDK's PDFDocument
    /// has no `.pages`; use `page(at:)` with `pageCount`).
    func goToPage(_ index: Int) {
        guard let doc = view?.document, (0..<doc.pageCount).contains(index), let page = doc.page(at: index) else { return }
        view?.go(to: page)
    }

    /// Index of the visible page via `index(for:)` (this SDK's
    /// alternative to a `.pages` collection); 0 when nothing shows.
    var currentPageIndex: Int {
        guard let view, let doc = view.document, let page = view.currentPage else { return 0 }
        return doc.index(for: page)
    }
}

/// PDFKit-backed page view. Note this SDK's PDFKit shape: documents
/// expose `pageCount`/`page(at:)`/`index(for:)` — there is no `.pages`
/// collection — and outlines iterate via `numberOfChildren` +
/// `child(at:)` (see `flattenOutline`).
struct PDFBookView: UIViewRepresentable {
    /// File URL of the copied PDF.
    let url: URL
    /// Parent screen's command handle; receives the created view.
    let controller: PDFBookController
    /// Page to show on first display (restored reading position).
    let initialPage: Int
    /// Continuous scroll vs one-page-at-a-time display mode.
    let continuous: Bool

    /// Creates the PDFView (auto-scaling, vertical), loads the document,
    /// and jumps to the initial page.
    ///
    /// Concept: pdfkit → docs/concepts/pdfkit.md
    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = context.coordinator.continuous ? .singlePageContinuous : .singlePage
        v.displayDirection = .vertical
        v.backgroundColor = .systemBackground
        v.document = PDFDocument(url: url)
        controller.view = v
        if let doc = v.document, (0..<doc.pageCount).contains(initialPage), let page = doc.page(at: initialPage) {
            v.go(to: page)
        }
        return v
    }

    /// Switches display mode when `continuous` changes, keeping the
    /// current page on screen.
    func updateUIView(_ v: PDFView, context: Context) {
        controller.view = v
        if context.coordinator.continuous != context.coordinator.parent.continuous {
            context.coordinator.continuous = context.coordinator.parent.continuous
            let page = v.currentPage
            v.displayMode = context.coordinator.continuous ? .singlePageContinuous : .singlePage
            if let page { v.go(to: page) }
        }
    }

    /// SwiftUI coordinator factory.
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    /// Remembers the last-applied display mode so updateUIView can
    /// detect changes.
    final class Coordinator {
        /// Latest view values (kept current by updateUIView).
        var parent: PDFBookView
        /// Display mode currently applied to the view.
        var continuous: Bool

        /// Snapshots the initial display mode.
        init(parent: PDFBookView) {
            self.parent = parent
            self.continuous = parent.continuous
        }
    }

    /// Depth-first outline flatten, resolving destinations to page indexes.
    static func flattenOutline(_ outline: PDFOutline?, document: PDFDocument?, level: Int = 0) -> [OutlineEntry] {
        guard let document else { return [] }
        var result: [OutlineEntry] = []
        guard let container = outline else { return result }
        var id = 0
        for i in 0..<container.numberOfChildren {
            guard let n = container.child(at: i) else { continue }
            var pageIndex: Int?
            if let dest = n.destination, let page = dest.page {
                let idx = document.index(for: page)
                pageIndex = idx >= 0 ? idx : nil
            }
            result.append(OutlineEntry(id: id, title: n.label ?? "Untitled", pageIndex: pageIndex, level: level))
            id += 1
            result += flattenOutline(n, document: document, level: level + 1)
        }
        return result
    }
}
