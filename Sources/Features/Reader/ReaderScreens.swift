import SwiftUI
import PDFKit
import WebKit
import UniformTypeIdentifiers
import UIKit

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
/// Wheel scrolls; center opens chapters/contents; hold center opens the
/// book's settings (font, spacing, margins, scroll step, PDF view mode);
/// prev/next change chapter/page.
struct BookScreen: View {
    let bookID: String

    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase
    @State private var book: ReaderStore.Book?
    @State private var chapters: [EpubChapter] = []
    @State private var outline: [OutlineEntry] = []
    @State private var panelOpen = false
    @State private var panelIsSettings = false
    @State private var panelSelection = 0
    @State private var toast = ""
    @State private var highlights: [BookHighlight] = []
    @State private var selectedText = ""
    @State private var pdfSelectionToken: NSObjectProtocol?
    @State private var epubController = EpubController()
    @State private var pdfController = PDFBookController()

    private var isPDF: Bool { book?.kind == .pdf }

    private static let dimOverlays: [Double] = [0, 0.18, 0.38]

    private var dimOpacity: Double {
        guard let book else { return 0 }
        return Self.dimOverlays[min(max(book.dim, 0), 2)]
    }

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
        .onAppear {
            if book == nil {
                book = model.reader.book(id: bookID)
                if book?.kind == .epub {
                    chapters = EpubParser.load(bookDir: Self.epubDir(for: book!))
                    highlights = HighlightStore.load(bookID: bookID, kind: .epub)
                }
            }
            // PDFKit posts selection changes; surface them in the
            // highlight bar (only one PDF view exists in the app).
            if pdfSelectionToken == nil {
                pdfSelectionToken = NotificationCenter.default.addObserver(
                    forName: .PDFViewSelectionChanged, object: nil, queue: .main) { _ in
                        guard self.book?.kind == .pdf else { return }
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
            if let token = pdfSelectionToken {
                NotificationCenter.default.removeObserver(token)
                pdfSelectionToken = nil
            }
            saveLocation()
        }
    }

    @ViewBuilder
    private func content(book: ReaderStore.Book) -> some View {
        if book.kind == .pdf {
            // A little air above and below the pages (the progress bar
            // sits in its own row beneath the reading area).
            PDFBookView(url: Self.pdfURL(for: book), controller: pdfController,
                        initialPage: book.chapterIndex, continuous: book.pdfContinuous)
                .padding(.top, 10)
                .padding(.bottom, 10)
        } else {
            EpubWebView(
                chapter: chapters.indices.contains(book.chapterIndex) ? chapters[book.chapterIndex] : nil,
                bookDir: Self.epubDir(for: book),
                book: book,
                restoreFraction: book.scrollFraction,
                controller: epubController,
                highlightTexts: highlights.filter { $0.chapter == book.chapterIndex }.map(\.text),
                onSelection: { text in
                    withAnimation(.easeOut(duration: 0.15)) { selectedText = text }
                }
            )
        }
    }

    /// Thin whole-book progress line in its own row below the reading
    /// area (chapter/page granularity — never covers the text).
    private func bookProgressBar(_ book: ReaderStore.Book) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(0.25))
                Capsule().fill(SelectionGradient())
                    .frame(width: max(5, geo.size.width * progressFraction(book)))
            }
        }
        .frame(height: 4)
        .padding(.horizontal, 10)
    }

    private func progressFraction(_ book: ReaderStore.Book) -> Double {
        if book.kind == .pdf, let count = pdfController.document?.pageCount, count > 0 {
            return (Double(min(book.chapterIndex, count - 1)) + 0.5) / Double(count)
        }
        guard !chapters.isEmpty else { return 0 }
        return (Double(min(book.chapterIndex, chapters.count - 1)) + 0.5) / Double(chapters.count)
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
                    if isPDF {
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

    private func capsuleLabel(_ text: String, primary: Bool) -> some View {
        Text(text)
            .font(Theme.font(12, .bold))
            .foregroundStyle(primary ? Color.white : Theme.ink)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(Capsule().fill(primary ? AnyShapeStyle(SelectionGradient())
                                               : AnyShapeStyle(Color(white: 0.82))))
    }

    static func epubDir(for book: ReaderStore.Book) -> URL {
        ReaderStore.booksRoot.appendingPathComponent(book.id)
    }

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

    private static let fontSizes = [15, 17, 19, 22, 25]
    private static let scrollFractions = [0.4, 0.7, 1.0]

    private var bookSettings: [BookSetting] {
        guard let book else { return [] }
        if book.kind == .pdf {
            return [
                BookSetting(id: "view", title: "View", values: ["Continuous", "One Page"],
                            index: book.pdfContinuous ? 0 : 1),
                BookSetting(id: "dim", title: "Screen", values: ["Bright", "Dim", "Darker"],
                            index: min(max(book.dim, 0), 2)),
            ]
        }
        let sizeIndex = max(0, Self.fontSizes.firstIndex(of: book.fontSize) ?? 1)
        return [
            BookSetting(id: "size", title: "Font Size", values: Self.fontSizes.map { "\($0) px" }, index: sizeIndex),
            BookSetting(id: "family", title: "Font", values: ["Serif", "Sans"], index: min(max(book.fontFamily, 0), 1)),
            BookSetting(id: "spacing", title: "Line Spacing", values: ["Compact", "Normal", "Wide"], index: min(max(book.lineSpacing, 0), 2)),
            BookSetting(id: "margin", title: "Margins", values: ["Narrow", "Normal", "Wide"], index: min(max(book.margin, 0), 2)),
            BookSetting(id: "scroll", title: "Scroll Step", values: ["Small", "Medium", "Large"], index: min(max(book.scrollStep, 0), 2)),
            BookSetting(id: "dim", title: "Screen", values: ["Bright", "Dim", "Darker"], index: min(max(book.dim, 0), 2)),
        ]
    }

    private var panelRows: [MenuItem] {
        if panelIsSettings {
            return bookSettings.map { setting in
                MenuItem(id: setting.id, title: setting.title,
                         detail: setting.values.indices.contains(setting.index) ? setting.values[setting.index] : "",
                         showsChevron: false)
            }
        }
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
        ModalPanel(title: panelTitle, onClose: { closePanel() }) {
            MenuList(items: panelRows, selection: panelSelection, compact: true, emptyText: "No Contents")
                .padding(.top, 2)
        }
    }

    private var panelTitle: String {
        panelIsSettings ? "Book Settings" : (isPDF ? "Contents" : "Chapters")
    }

    private func closePanel() {
        withAnimation(.easeIn(duration: 0.15)) { panelOpen = false }
    }

    private func openContents() {
        if isPDF && outline.isEmpty {
            outline = PDFBookView.flattenOutline(pdfController.document?.outlineRoot, document: pdfController.document)
        }
        panelIsSettings = false
        panelSelection = 0
        withAnimation(.easeOut(duration: 0.18)) { panelOpen = true }
    }

    private func openSettings() {
        panelIsSettings = true
        panelSelection = 0
        withAnimation(.easeOut(duration: 0.18)) { panelOpen = true }
    }

    private func activatePanelRow() {
        let rows = panelRows
        guard rows.indices.contains(panelSelection) else { return }
        if panelIsSettings {
            cycleSetting(id: rows[panelSelection].id)
            return
        }
        let id = rows[panelSelection].id
        if isPDF {
            let idx = Int(id.dropFirst("out.".count)) ?? 0
            if outline.indices.contains(idx), let page = outline[idx].pageIndex {
                pdfController.goToPage(page)
                book?.chapterIndex = page
            }
            saveLocation()
        } else {
            let idx = Int(id.dropFirst("ch.".count)) ?? 0
            if chapters.indices.contains(idx), var b = book {
                b.chapterIndex = idx
                b.scrollFraction = 0
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
        func wrapped(_ current: Int, _ count: Int) -> Int { (current + 1) % count }
        switch id {
        case "view":
            b.pdfContinuous.toggle()
            pdfController.setDisplayMode(continuous: b.pdfContinuous)
        case "size":
            let idx = max(0, Self.fontSizes.firstIndex(of: b.fontSize) ?? 1)
            b.fontSize = Self.fontSizes[wrapped(idx, Self.fontSizes.count)]
            epubController.applyStyle(to: b)
        case "family":
            b.fontFamily = wrapped(min(max(b.fontFamily, 0), 1), 2)
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
        default:
            break
        }
        book = b
        model.reader.update(b)
    }

    // MARK: Actions

    /// Wraps the current selection in a persistent mark (EPUB: DOM marks;
    /// PDF: highlight annotations written into the file), stores it, and
    /// mirrors it into the book's Highlights note.
    private func saveHighlight() {
        guard var b = book else { return }
        if b.kind == .epub {
            epubController.wrapSelection { text in
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                withAnimation(.easeIn(duration: 0.15)) { selectedText = "" }
                guard !trimmed.isEmpty else { return }
                let highlight = BookHighlight(id: UUID().uuidString, chapter: b.chapterIndex, text: trimmed)
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

    private func stepChapter(_ delta: Int) {
        guard var b = book else { return }
        if b.kind == .pdf {
            if delta > 0 { pdfController.nextPage() } else { pdfController.prevPage() }
            b.chapterIndex = pdfController.currentPageIndex
            book = b
            saveLocation()
        } else {
            let next = b.chapterIndex + delta
            guard chapters.indices.contains(next) else {
                showToast(delta > 0 ? "End of Book" : "Start of Book")
                return
            }
            b.chapterIndex = next
            b.scrollFraction = 0
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
                // currentPage settles asynchronously; keep the progress
                // bar honest.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    if self.book?.kind == .pdf {
                        self.book?.chapterIndex = self.pdfController.currentPageIndex
                    }
                }
            } else {
                // Instant viewport-fraction jumps track the wheel 1:1.
                let step = Self.scrollFractions[min(max(book?.scrollStep ?? 1, 0), Self.scrollFractions.count - 1)]
                epubController.scrollByPage(fraction: d > 0 ? step : -step)
            }
        case .select:
            if panelOpen {
                activatePanelRow()
            } else {
                openContents()
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
    /// Body line height in points (from the applied style), so wheel steps
    /// can snap to whole lines — pages then end at complete lines instead
    /// of cutting one at the viewport edge.
    var linePixelHeight: CGFloat = 24

    /// Page-stepped scroll snapped to whole lines: a tick moves a multiple
    /// of the line height that fits the readable area, so the last line of
    /// every page is complete, with clean whitespace before the edge.
    func scrollByPage(fraction: Double) {
        guard let scrollView = webView?.scrollView else { return }
        let lh = max(8, linePixelHeight)
        let readable = scrollView.bounds.height
            - scrollView.contentInset.top
            - scrollView.contentInset.bottom
        let linesPerPage = max(1, Int(readable / lh))
        let lines = max(1, Int((fraction * Double(linesPerPage)).rounded()))
        var offset = scrollView.contentOffset
        offset.y += CGFloat(lines) * lh
        let maxY = max(0, scrollView.contentSize.height + scrollView.contentInset.bottom
                        - scrollView.bounds.height)
        offset.y = min(max(offset.y, -scrollView.contentInset.top), maxY)
        scrollView.setContentOffset(offset, animated: false)
    }

    func applyStyle(to book: ReaderStore.Book) {
        linePixelHeight = CGFloat((Double(book.fontSize)
            * Double(EpubController.lineHeightMultiplier(book))).rounded())
        webView?.evaluateJavaScript(EpubController.cssJS(for: book), completionHandler: nil)
    }

    /// Wraps the current selection in persistent marks; returns its text.
    func wrapSelection(completion: @escaping (String) -> Void) {
        webView?.evaluateJavaScript(HighlightJS.wrapSelection) { value, _ in
            let text = value as? String ?? ""
            DispatchQueue.main.async { completion(text) }
        }
    }

    func clearSelection() {
        webView?.evaluateJavaScript(HighlightJS.clearSelection, completionHandler: nil)
    }

    func scrollFraction(completion: @escaping (Double) -> Void) {
        let js = "document.documentElement.scrollHeight > window.innerHeight + 1 ? window.scrollY / (document.documentElement.scrollHeight - window.innerHeight) : 1"
        webView?.evaluateJavaScript(js) { value, _ in
            let f = (value as? NSNumber)?.doubleValue ?? 0
            DispatchQueue.main.async { completion(min(max(f, 0), 1)) }
        }
    }

    /// The unitless CSS line-height multiplier for a book's spacing setting.
    static func lineHeightMultiplier(_ book: ReaderStore.Book) -> Double {
        [1.4, 1.55, 1.75][min(max(book.lineSpacing, 0), 2)]
    }

    static func cssJS(for book: ReaderStore.Book) -> String {
        let families = ["Georgia,'Times New Roman',serif", "-apple-system,'Helvetica Neue',sans-serif"]
        let family = families[min(max(book.fontFamily, 0), families.count - 1)]
        let lineHeight = lineHeightMultiplier(book)
        let paddings = [10, 16, 24]
        let padding = paddings[min(max(book.margin, 0), paddings.count - 1)]
        return """
        (function(){
          var s = document.getElementById('ipod-reader-css');
          if (!s) { s = document.createElement('style'); s.id = 'ipod-reader-css'; document.head.appendChild(s); }
          s.textContent = "html{scroll-behavior:auto !important;font-size:\(book.fontSize)px !important;} body{font-size:\(book.fontSize)px !important;line-height:\(lineHeight) !important;font-family:\(family) !important;padding:\(padding)px !important;} p,div,li,blockquote,section,article,aside,td,th,dd,dt,figcaption,pre,code{font-size:inherit !important;} mark.ipod-hl{background:rgba(255,208,0,0.45) !important;color:inherit !important;} img,svg,video{max-width:100% !important;height:auto !important;} pre,code{white-space:pre-wrap !important;word-break:break-word !important;}";
        })()
        """
    }
}

/// Wheel scroll fractions for the scroll-step setting (S/M/L).
enum ReaderScrollStep {
    static let fractions = [0.4, 0.7, 1.0]
}

/// Reflowing EPUB document view. Chapters are XHTML rendered natively by
/// the web view (reflow is inherent); we inject a reader stylesheet built
/// from the book's settings, restore the saved scroll position on load,
/// watch text selection (highlighting), and re-wrap saved highlights.
struct EpubWebView: UIViewRepresentable {
    let chapter: EpubChapter?
    let bookDir: URL
    let book: ReaderStore.Book
    let restoreFraction: Double
    let controller: EpubController
    var highlightTexts: [String] = []
    var onSelection: ((String) -> Void)?

    func makeUIView(context: Context) -> WKWebView {
        let wv = WKWebView(frame: .zero)
        wv.navigationDelegate = context.coordinator
        wv.scrollView.indicatorStyle = .black
        wv.backgroundColor = .systemBackground
        // Page-stepping must map 1:1 to the visible screen: no bounce
        // overshoot, no hidden safe-area insets shrinking the viewport.
        wv.scrollView.bounces = false
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        // Gentle breathing room at the top of the page; the progress bar
        // lives below the reading area now, so no bottom reservation.
        wv.scrollView.contentInset = UIEdgeInsets(
            top: CGFloat(book.fontSize) + 8,
            left: 0,
            bottom: 10,
            right: 0)
        let cfg = wv.configuration.userContentController
        cfg.addUserScript(WKUserScript(source: HighlightJS.selectionWatch,
                                       injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        cfg.add(context.coordinator, name: "selection")
        controller.webView = wv
        controller.linePixelHeight = CGFloat((Double(book.fontSize)
            * Double(EpubController.lineHeightMultiplier(book))).rounded())
        if let chapter {
            context.coordinator.loadedURL = chapter.url
            context.coordinator.appliedStyle = book
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
        } else if context.coordinator.appliedStyle != book {
            context.coordinator.appliedStyle = book
            wv.evaluateJavaScript(EpubController.cssJS(for: book), completionHandler: nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: EpubWebView
        var loadedURL: URL?
        var appliedStyle: ReaderStore.Book?

        init(parent: EpubWebView) {
            self.parent = parent
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "selection", let text = message.body as? String else { return }
            DispatchQueue.main.async { self.parent.onSelection?(text) }
        }

        func webView(_ webview: WKWebView, didFinish navigation: WKNavigation!) {
            // Inject the reader stylesheet, restore highlights, then the
            // saved scroll position. The CSS reflow changes the document
            // height, so restore twice: immediately and again after layout
            // settles (the second corrects the first using the final
            // scrollHeight, e.g. after images load).
            webview.evaluateJavaScript(EpubController.cssJS(for: parent.book), completionHandler: nil)
            if !parent.highlightTexts.isEmpty {
                webview.evaluateJavaScript(HighlightJS.restore(texts: parent.highlightTexts), completionHandler: nil)
            }
            let fraction = parent.restoreFraction
            let js = "document.documentElement.scrollHeight > window.innerHeight + 1 ? window.scrollTo(0, \(fraction) * (document.documentElement.scrollHeight - window.innerHeight)) : window.scrollTo(0,0)"
            webview.evaluateJavaScript(js, completionHandler: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
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

    func clearSelection() {
        view?.clearSelection()
    }

    func goToPage(_ index: Int) {
        guard let doc = view?.document, (0..<doc.pageCount).contains(index), let page = doc.page(at: index) else { return }
        view?.go(to: page)
    }

    /// Continuous scroll vs one-page-at-a-time, keeping the current page.
    func setDisplayMode(continuous: Bool) {
        guard let view else { return }
        let page = view.currentPage
        view.displayMode = continuous ? .singlePageContinuous : .singlePage
        if let page { view.go(to: page) }
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
    let continuous: Bool

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

    func updateUIView(_ v: PDFView, context: Context) {
        controller.view = v
        if context.coordinator.continuous != context.coordinator.parent.continuous {
            context.coordinator.continuous = context.coordinator.parent.continuous
            let page = v.currentPage
            v.displayMode = context.coordinator.continuous ? .singlePageContinuous : .singlePage
            if let page { v.go(to: page) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator {
        var parent: PDFBookView
        var continuous: Bool

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
