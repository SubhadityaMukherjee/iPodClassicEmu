import Foundation
import PDFKit

/// PDF text reflow: extracts the document's text once into per-chapter
/// HTML files and reuses the EPUB column-pagination pipeline (wheel
/// paging, progress, font settings). Original page view stays available;
/// image-only PDFs (no extractable text) are refused by the caller.
enum PDFReflow {
    /// One reflow chapter: a page range [start, end) with a title — from
    /// the PDF's top-level outline when present, else the whole book.
    struct Span {
        let title: String
        let start: Int
        let end: Int
    }

    // MARK: Chapter spans

    /// Top-level outline entries become chapters; nested entries fold into
    /// their parent's range. Entries without a resolvable page are skipped.
    static func spans(outline: [OutlineEntry], pageCount: Int) -> [Span] {
        guard pageCount > 0 else { return [] }
        let tops = outline.filter { $0.level == 0 && $0.pageIndex != nil }
            .sorted { ($0.pageIndex ?? 0) < ($1.pageIndex ?? 0) }
        var starts: [(title: String, page: Int)] = []
        for e in tops {
            let page = min(max(e.pageIndex ?? 0, 0), pageCount - 1)
            if let last = starts.last, last.page == page { continue }
            starts.append((e.title, page))
        }
        guard !starts.isEmpty else {
            return [Span(title: "Book", start: 0, end: pageCount)]
        }
        return starts.enumerated().map { i, entry in
            let end = i + 1 < starts.count ? starts[i + 1].page : pageCount
            return Span(title: entry.title, start: entry.page, end: max(end, entry.page + 1))
        }
    }

    // MARK: Text → paragraphs

    /// Joins extracted text lines into paragraphs. PDFKit yields one line
    /// per rendered line; a paragraph break is a line ending with terminal
    /// punctuation (the last line of a paragraph). Hyphenated line-ends
    /// join without a space. Imperfect on headings (they glue to the next
    /// paragraph) but stable on book prose.
    static func paragraphs(from lines: [String]) -> [String] {
        var out: [String] = []
        var buf: [String] = []
        func flush() {
            guard !buf.isEmpty else { return }
            out.append(buf.joined(separator: " "))
            buf = []
        }
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let last = buf.last, let joined = dehyphenate(last, next: line) {
                buf[buf.count - 1] = joined
                continue
            }
            if let last = buf.last, endsSentence(last) { flush() }
            buf.append(line)
        }
        flush()
        return out
    }

    /// "consider-" + "able" → "considerable" (only a real hyphenated
    /// word-end: a letter right before the hyphen).
    private static func dehyphenate(_ line: String, next: String) -> String? {
        guard line.hasSuffix("-"), line.count > 1 else { return nil }
        let beforeHyphen = line[line.index(before: line.index(before: line.endIndex))]
        guard beforeHyphen.isLetter else { return nil }
        return String(line.dropLast()) + next
    }

    private static func endsSentence(_ line: String) -> Bool {
        guard let c = line.unicodeScalars.last else { return false }
        return ".?!…:;\"”’)]".contains(Character(c))
    }

    // MARK: HTML

    static func html(title: String, paragraphs: [String]) -> String {
        let body = paragraphs.map { "<p>\(escapeHTML($0))</p>" }.joined(separator: "\n")
        return """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escapeHTML(title))</title></head><body>
        \(body)
        </body></html>
        """
    }

    static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: Generation

    /// Extracts every span's text and writes reflow/<i>.html under the
    /// book's directory (style-independent — the reader stylesheet is
    /// injected at runtime, so font changes never regenerate). Cached:
    /// if all files exist they are reused. Returns chapters; empty when
    /// the document can't be read.
    static func generateChapters(pdfURL: URL, outDir: URL, spans: [Span]) async -> [EpubChapter] {
        guard !spans.isEmpty else { return [] }
        let fm = FileManager.default
        try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        let allCached = spans.indices.allSatisfy {
            fm.fileExists(atPath: outDir.appendingPathComponent("\($0).html").path)
        }
        if allCached {
            return spans.enumerated().map { i, span in
                EpubChapter(index: i, title: span.title,
                            url: outDir.appendingPathComponent("\(i).html"))
            }
        }
        return await Task.detached(priority: .userInitiated) { () -> [EpubChapter] in
            guard let doc = PDFDocument(url: pdfURL) else { return [] }
            var chapters: [EpubChapter] = []
            for (i, span) in spans.enumerated() {
                var lines: [String] = []
                for p in span.start..<min(span.end, doc.pageCount) {
                    let text = doc.page(at: p)?.string ?? ""
                    lines.append(contentsOf: text.components(separatedBy: .newlines))
                }
                let url = outDir.appendingPathComponent("\(i).html")
                try? html(title: span.title, paragraphs: paragraphs(from: lines))
                    .write(to: url, atomically: true, encoding: .utf8)
                chapters.append(EpubChapter(index: i, title: span.title, url: url))
            }
            return chapters
        }.value
    }
}
