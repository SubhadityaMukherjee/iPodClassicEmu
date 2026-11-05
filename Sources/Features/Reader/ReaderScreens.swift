import SwiftUI
import PDFKit
import WebKit
import UniformTypeIdentifiers

/// Reader menu: "Add from Files" plus the imported books.
struct ReaderScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings
    @State private var selection = 0
    @State private var showingPicker = false
    @State private var deleteCandidate: ReaderStore.Book?
    @State private var deleteSelection = 0
    @State private var toast = ""

    private var store: ReaderStore { model.reader }

    private var items: [MenuItem] {
        var rows = [MenuItem(id: "hdr.add", title: "Add from Files", symbol: "plus.circle.fill", showsChevron: false, isActionRow: true)]
        rows += store.books.map { book in
            MenuItem(id: book.id, title: book.title, detail: book.kind == .pdf ? "PDF" : "EPUB")
        }
        return rows
    }

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

    private func importBook(_ url: URL) {
        do {
            let book = try store.addBook(from: url)
            showToast("Added \(book.title)")
        } catch {
            showToast(error.localizedDescription)
        }
    }

    private func showToast(_ text: String) {
        withAnimation(.easeOut(duration: 0.2)) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation(.easeIn(duration: 0.3)) { toast = "" }
        }
    }

    // MARK: Input

    private func handle(_ event: ControlEvent) {
        switch event {
        case .tick(let d):
            moveListSelection(&selection, count: items.count, delta: d, settings: settings)
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
            if selection > 0, store.books.indices.contains(selection - 1) {
                deleteCandidate = store.books[selection - 1]
                deleteSelection = 0
                WheelHaptics.shared.ensureRunning()
                WheelHaptics.shared.buttonPress(strength: 0.85)
            }
        case .menu:
            model.pop()
        default:
            break
        }
    }
}

/// Document picker (Files app) for PDF/EPUB. `asCopy` hands us a plain
/// copy URL, so no security-scoped bookmark juggling.
struct DocumentPicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.pdf, UTType.epub], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) }
        }
    }
}

// MARK: - Book screen

/// One open book: reflowing EPUB (WKWebView) or paginated PDF (PDFKit).
/// Wheel scrolls pages; center opens chapters; hold center cycles font
/// size (EPUB only); prev/next change chapter/page.
struct BookScreen: View {
    let bookID: String

    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings
    @State private var book: ReaderStore.Book?
    @State private var chapters: [EpubChapter] = []
    @State private var outline: [OutlineEntry] = []
    @State private var panelOpen = false
    @State private var panelSelection = 0
    @State private var toast = ""
    @State private var epubController = EpubController()
    @State private var pdfController = PDFBookController()

    private var isPDF: Bool { book?.kind == .pdf }

    var body: some View {
        ZStack {
            if let book {
                if book.kind == .pdf {
                    PDFBookView(url: Self.pdfURL(for: book), controller: pdfController, initialPage: book.chapterIndex)
                } else {
                    EpubWebView(
                        chapter: chapters.indices.contains(book.chapterIndex) ? chapters[book.chapterIndex] : nil,
                        bookDir: Self.epubDir(for: book),
                        fontSize: book.fontSize,
                        restoreFraction: book.scrollFraction,
                        controller: epubController
                    )
                }
                if panelOpen {
                    ModalHost { panel }
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
        .onWheel { handle($0) }
        .onAppear {
            if book == nil {
                book = model.reader.book(id: bookID)
                if book?.kind == .epub {
                    chapters = EpubParser.load(bookDir: Self.epubDir(for: book!))
                }
            }
            model.transportClaimedByScreen = true
        }
        .onDisappear {
            model.transportClaimedByScreen = false
            saveLocation()
        }
    }

    static func epubDir(for book: ReaderStore.Book) -> URL {
        ReaderStore.booksRoot.appendingPathComponent(book.id)
    }

    static func pdfURL(for book: ReaderStore.Book) -> URL {
        ReaderStore.booksRoot.appendingPathComponent(book.id).appendingPathExtension("pdf")
    }

    // MARK: Panels

    private var panelRows: [MenuItem] {
        if isPDF {
            return outline.map { entry in
                let indent = String(repeating: "    ", count: entry.level)
                return MenuItem(id: "out.\(entry.id)", title: indent + entry.title, showsChevron: false)
            }
        }
        return chapters.map { ch in
            MenuItem(id: "ch.\(ch.index)", title: ch.title, showsChevron: false)
        }
    }

    private var panel: some View {
        ModalPanel(title: isPDF ? "Contents" : "Chapters", onClose: { closePanel() }) {
            MenuList(items: panelRows, selection: panelSelection, compact: true, emptyText: "No Contents")
                .padding(.top, 2)
        }
    }

    private func closePanel() {
        withAnimation(.easeIn(duration: 0.15)) { panelOpen = false }
    }

    private func openPanel() {
        if isPDF && outline.isEmpty {
            outline = PDFBookView.flattenOutline(pdfController.document?.outlineRoot, document: pdfController.document)
        }
        panelSelection = 0
        withAnimation(.easeOut(duration: 0.18)) { panelOpen = true }
    }

    private func activatePanelRow() {
        let rows = panelRows
        guard rows.indices.contains(panelSelection) else { return }
        let id = rows[panelSelection].id
        if isPDF {
            let idx = Int(id.dropFirst("out.".count)) ?? 0
            if outline.indices.contains(idx), let page = outline[idx].pageIndex {
                pdfController.goToPage(page)
                book?.chapterIndex = page
            }
        } else {
            let idx = Int(id.dropFirst("ch.".count)) ?? 0
            if chapters.indices.contains(idx) {
                book?.chapterIndex = idx
                book?.scrollFraction = 0
            }
        }
        saveLocation()
        closePanel()
    }

    // MARK: Actions

    private func cycleFontSize() {
        let sizes = [15, 17, 19, 22]
        let current = book?.fontSize ?? 17
        let next = sizes.first(where: { $0 > current }) ?? sizes[0]
        book?.fontSize = next
        epubController.applyFontSize(next)
        showToast("Font Size \(next)")
    }

    private func stepChapter(_ delta: Int) {
        guard var b = book else { return }
        if b.kind == .pdf {
            if delta > 0 { pdfController.nextPage() } else { pdfController.prevPage() }
            b.chapterIndex = pdfController.currentPageIndex
        } else {
            let next = b.chapterIndex + delta
            guard chapters.indices.contains(next) else {
                showToast(delta > 0 ? "End of Book" : "Start of Book")
                return
            }
            b.chapterIndex = next
            b.scrollFraction = 0
        }
        book = b
        saveLocation()
    }

    /// Asks the web view for the current scroll position, then persists.
    private func saveLocation() {
        guard var b = book else { return }
        if b.kind == .pdf {
            b.chapterIndex = pdfController.currentPageIndex
            model.reader.update(b)
            book = b
        } else {
            epubController.scrollFraction { fraction in
                b.scrollFraction = fraction
                self.model.reader.update(b)
                DispatchQueue.main.async { self.book = b }
            }
        }
    }

    private func showToast(_ text: String) {
        withAnimation(.easeOut(duration: 0.2)) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation(.easeIn(duration: 0.3)) { toast = "" }
        }
    }

    // MARK: Input

    private func handle(_ event: ControlEvent) {
        switch event {
        case .tick(let d):
            if panelOpen {
                moveListSelection(&panelSelection, count: panelRows.count, delta: d, settings: settings)
            } else if isPDF {
                if d > 0 { pdfController.nextPage() } else { pdfController.prevPage() }
            } else {
                epubController.scroll(by: d > 0 ? 240 : -240)
            }
        case .select:
            if panelOpen {
                activatePanelRow()
            } else {
                openPanel()
            }
        case .centerHold:
            guard !panelOpen, let book, book.kind == .epub else { break }
            WheelHaptics.shared.ensureRunning()
            WheelHaptics.shared.buttonPress(strength: 0.85)
            cycleFontSize()
        case .next, .nextHold:
            stepChapter(1)
        case .prev, .prevHold:
            stepChapter(-1)
        case .menu:
            if panelOpen {
                closePanel()
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
    weak var webView: WKWebView?

    func scroll(by dy: CGFloat) {
        webView?.evaluateJavaScript("window.scrollBy({top: \(dy), behavior: 'smooth'})", completionHandler: nil)
    }

    func applyFontSize(_ px: Int) {
        webView?.evaluateJavaScript(Self.cssJS(px: px), completionHandler: nil)
    }

    func scrollFraction(completion: @escaping (Double) -> Void) {
        let js = "document.documentElement.scrollHeight > window.innerHeight + 1 ? window.scrollY / (document.documentElement.scrollHeight - window.innerHeight) : 1"
        webView?.evaluateJavaScript(js) { value, _ in
            let f = (value as? NSNumber)?.doubleValue ?? 0
            DispatchQueue.main.async { completion(min(max(f, 0), 1)) }
        }
    }

    static func cssJS(px: Int) -> String {
        """
        (function(){
          var s = document.getElementById('ipod-reader-css');
          if (!s) { s = document.createElement('style'); s.id = 'ipod-reader-css'; document.head.appendChild(s); }
          s.textContent = "body{font-size:\\(px)px !important;line-height:1.55 !important;font-family:Georgia,'Times New Roman',serif !important;padding:16px 14px !important;} img,svg,video{max-width:100% !important;height:auto !important;} pre,code{white-space:pre-wrap !important;word-break:break-word !important;}";
        })()
        """
    }
}

/// Reflowing EPUB document view. Chapters are XHTML rendered natively by
/// the web view (reflow is inherent); we inject a reader stylesheet for
/// font size and restore the saved scroll position on load.
struct EpubWebView: UIViewRepresentable {
    let chapter: EpubChapter?
    let bookDir: URL
    let fontSize: Int
    let restoreFraction: Double
    let controller: EpubController

    func makeUIView(context: Context) -> WKWebView {
        let wv = WKWebView(frame: .zero)
        wv.navigationDelegate = context.coordinator
        wv.scrollView.indicatorStyle = .black
        wv.backgroundColor = .systemBackground
        controller.webView = wv
        if let chapter {
            context.coordinator.loadedURL = chapter.url
            wv.loadFileURL(chapter.url, allowingReadAccessTo: bookDir)
        }
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {
        context.coordinator.parent = self
        controller.webView = wv
        if let chapter, context.coordinator.loadedURL != chapter.url {
            context.coordinator.loadedURL = chapter.url
            wv.loadFileURL(chapter.url, allowingReadAccessTo: bookDir)
        } else if context.coordinator.appliedFontSize != fontSize {
            context.coordinator.appliedFontSize = fontSize
            wv.evaluateJavaScript(EpubController.cssJS(px: fontSize), completionHandler: nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: EpubWebView
        var loadedURL: URL?
        var appliedFontSize: Int = 0

        init(parent: EpubWebView) {
            self.parent = parent
        }

        func webView(_ webview: WKWebView, didFinish navigation: WKNavigation!) {
            // Inject the reader stylesheet, then restore the saved scroll.
            let px = parent.fontSize
            webview.evaluateJavaScript(EpubController.cssJS(px: px), completionHandler: nil)
            let fraction = parent.restoreFraction
            let js = "document.documentElement.scrollHeight > window.innerHeight + 1 ? window.scrollTo(0, \(fraction) * (document.documentElement.scrollHeight - window.innerHeight)) : window.scrollTo(0,0)"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                webview.evaluateJavaScript(js, completionHandler: nil)
            }
        }
    }
}

// MARK: - PDF rendering

/// One flattened PDF outline entry.
struct OutlineEntry: Identifiable {
    let id: Int
    let title: String
    let pageIndex: Int?
    let level: Int
}

/// Command handle for the parent screen to drive the PDF view.
final class PDFBookController {
    weak var view: PDFView?

    var document: PDFDocument? { view?.document }

    func nextPage() { view?.goToNextPage(nil) }
    func prevPage() { view?.goToPreviousPage(nil) }

    func goToPage(_ index: Int) {
        guard let doc = view?.document, (0..<doc.pageCount).contains(index), let page = doc.page(at: index) else { return }
        view?.go(to: page)
    }

    var currentPageIndex: Int {
        guard let view, let doc = view.document, let page = view.currentPage else { return 0 }
        return doc.index(for: page)
    }
}

struct PDFBookView: UIViewRepresentable {
    let url: URL
    let controller: PDFBookController
    let initialPage: Int

    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displayDirection = .vertical
        v.backgroundColor = .systemBackground
        v.document = PDFDocument(url: url)
        controller.view = v
        if let doc = v.document, (0..<doc.pageCount).contains(initialPage), let page = doc.page(at: initialPage) {
            v.go(to: page)
        }
        return v
    }

    func updateUIView(_ v: PDFView, context: Context) {
        controller.view = v
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
