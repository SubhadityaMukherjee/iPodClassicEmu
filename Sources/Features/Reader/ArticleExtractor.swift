import Foundation

/// Read Later: turns a web article into a one-chapter "mini EPUB" that
/// rides the existing reader pipeline (column pagination, fonts,
/// highlights, progress). Extraction is deliberately simple and robust:
/// drop boilerplate containers, keep the text of paragraph-ish elements,
/// and rebuild clean XHTML. No external dependencies.
enum ArticleExtractor {
    struct ExtractionError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: Fetch

    /// Downloads the article page and returns raw HTML.
    static func fetch(from urlString: String) async throws -> String {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw ExtractionError(message: "Not a web URL")
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ExtractionError(message: "Server returned \(http.statusCode)")
        }
        return decode(data)
    }

    /// UTF-8 first, falling back to Latin-1 (common on older EU sites).
    private static func decode(_ data: Data) -> String {
        if let s = String(data: data, encoding: .utf8) { return s }
        return String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
    }

    // MARK: Extraction (pure — unit tested)

    /// Extracts a title and paragraph list from article HTML.
    static func extract(html: String) -> (title: String, paragraphs: [String]) {
        var clean = html

        // Comments and boilerplate containers first (they can contain
        // markup that would confuse the paragraph scan).
        clean = dropComments(clean)
        for tag in ["script", "style", "noscript", "nav", "header", "footer",
                    "aside", "form", "button", "svg", "figure", "iframe"] {
            clean = dropElement(tag, in: clean)
        }

        let title = pageTitle(in: clean) ?? "Article"

        // Prefer semantic containers when present; fall back to <main>,
        // then the whole remainder.
        var scope = clean
        if let a = firstBlock("article", in: clean) {
            scope = a
        } else if let m = firstBlock("main", in: clean) {
            scope = m
        }

        // Collect text from paragraph-ish elements.
        var paragraphs: [String] = []
        var searchStart = scope.startIndex
        while searchStart < scope.endIndex,
              let open = scope[searchStart...].range(of: paragraphOpenPattern,
                                                     options: .regularExpression) {
            // The matched text looks like "<p>", "<p class=x>", "<blockquote>".
            let matched = String(scope[open.lowerBound..<open.upperBound])
            let tag = matched.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                .split(separator: " ").first.map(String.init) ?? "p"
            guard let end = scope[open.upperBound...].range(of: "</\(tag)>",
                                                            options: .caseInsensitive) else { break }
            let inner = String(scope[open.upperBound..<end.lowerBound])
            let text = unescape(stripTags(inner))
            if text.count >= 3 {
                paragraphs.append(text)
            }
            searchStart = end.upperBound
        }
        // The content's own headline often repeats og:title — drop it.
        if paragraphs.first?.caseInsensitiveCompare(title) == .orderedSame {
            paragraphs.removeFirst()
        }
        return (title, paragraphs)
    }

    /// Builds the single-chapter XHTML document shown in the reader.
    static func xhtml(title: String, paragraphs: [String]) -> String {
        let escapedTitle = escape(title)
        var body = "<h1>\(escapedTitle)</h1>\n"
        if paragraphs.isEmpty {
            body += "<p>(No extractable text on that page.)</p>\n"
        } else {
            for p in paragraphs {
                body += "<p>\(escape(p))</p>\n"
            }
        }
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>\(escapedTitle)</title></head>
        <body>
        \(body)</body>
        </html>
        """
    }

    // MARK: Mini-EPUB assembly

    /// Writes container.xml + content.opf + article.xhtml so EpubParser
    /// and the whole reader pipeline treat the article like any EPUB.
    static func writeMiniEpub(dir: URL, title: String, xhtml: String) throws {
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("META-INF", isDirectory: true),
            withIntermediateDirectories: true)
        let container = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="bookid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>\(escape(title))</dc:title>
            <dc:identifier id="bookid">urn:uuid:\(UUID().uuidString)</dc:identifier>
          </metadata>
          <manifest>
            <item id="article" href="article.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine>
            <itemref idref="article"/>
          </spine>
        </package>
        """
        try container.data(using: .utf8)?.write(
            to: dir.appendingPathComponent("META-INF/container.xml"))
        try opf.data(using: .utf8)?.write(to: dir.appendingPathComponent("content.opf"))
        try xhtml.data(using: .utf8)?.write(to: dir.appendingPathComponent("article.xhtml"))
    }

    // MARK: Helpers

    private static let paragraphOpenPattern = "<(p|h1|h2|h3|blockquote|li)(\\s[^>]*)?>"

    private static func stripTags(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Removes `<tag …>…</tag>` spans (case-insensitive). An unclosed
    /// element drops to the end of the document.
    private static func dropElement(_ tag: String, in source: String) -> String {
        var out = source
        let open = "<\(tag)"
        let close = "</\(tag)>"
        while let openRange = out.range(of: open, options: .caseInsensitive) {
            guard let gt = out[openRange.upperBound...].range(of: ">") else { break }
            guard let closeRange = out[gt.upperBound...].range(of: close, options: .caseInsensitive) else {
                out = String(out[..<openRange.lowerBound])
                break
            }
            out = String(out[..<openRange.lowerBound]) + String(out[closeRange.upperBound...])
        }
        return out
    }

    private static func dropComments(_ source: String) -> String {
        var out = source
        while let open = out.range(of: "<!--"), let close = out[open.upperBound...].range(of: "-->") {
            out = String(out[..<open.lowerBound]) + String(out[close.upperBound...])
        }
        return out
    }

    private static func firstBlock(_ tag: String, in source: String) -> String? {
        guard let open = source.range(of: "<\(tag)", options: .caseInsensitive),
              let gt = source[open.upperBound...].range(of: ">"),
              let close = source[gt.upperBound...].range(of: "</\(tag)>", options: .caseInsensitive)
        else { return nil }
        return String(source[open.lowerBound..<close.upperBound])
    }

    private static func pageTitle(in html: String) -> String? {
        // og:title / twitter:title meta tags first (cleaner than <title>).
        for (attr, name) in [("property", "og:title"), ("name", "twitter:title")] {
            let pattern = "<meta[^>]*\(attr)=[\"']\(name)[\"'][^>]*>"
            if let tagRange = html.range(of: pattern, options: .regularExpression) {
                let tag = String(html[tagRange])
                if let c = tag.range(of: "content=\"", options: .caseInsensitive) {
                    let rest = tag[c.upperBound...]
                    if let end = rest.range(of: "\"") {
                        let value = String(rest[..<end.lowerBound]).trimmingCharacters(in: .whitespaces)
                        if !value.isEmpty { return String(value.prefix(120)) }
                    }
                }
            }
        }
        guard let open = html.range(of: "<title", options: .caseInsensitive),
              let gt = html[open.upperBound...].range(of: ">"),
              let close = html[gt.upperBound...].range(of: "</title>", options: .caseInsensitive)
        else { return nil }
        let raw = String(html[gt.upperBound..<close.lowerBound])
        let t = unescape(stripTags(raw))
        return t.isEmpty ? nil : String(t.prefix(120))
    }

    private static let namedEntities: [(String, String)] = [
        ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
        ("&apos;", "'"), ("&#39;", "'"), ("&nbsp;", " "), ("&mdash;", "—"),
        ("&ndash;", "–"), ("&hellip;", "…"), ("&rsquo;", "\u{2019}"),
        ("&lsquo;", "\u{2018}"), ("&ldquo;", "\u{201C}"), ("&rdquo;", "\u{201D}"),
    ]

    /// Entity decode incl. numeric refs (`&#72;`, `&#x48;`); unknown
    /// named entities are dropped.
    static func unescape(_ s: String) -> String {
        var out = s
        for (entity, char) in namedEntities {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        // Numeric refs, scanned by hand (no regex-closure API exists).
        var result = ""
        var i = out.startIndex
        while i < out.endIndex {
            if out[i] == "&", i < out.endIndex {
                let rest = out[i...]
                if rest.hasPrefix("&#") {
                    let afterHash = rest.index(rest.startIndex, offsetBy: 2, limitedBy: rest.endIndex) ?? rest.endIndex
                    let isHex = afterHash < rest.endIndex && (rest[afterHash] == "x" || rest[afterHash] == "X")
                    let digitsStart = isHex ? rest.index(after: afterHash) : afterHash
                    var j = digitsStart
                    while j < rest.endIndex, rest[j].isHexDigit { j = rest.index(after: j) }
                    if j < rest.endIndex, j > digitsStart, rest[j] == ";" {
                        let digits = String(rest[digitsStart..<j])
                        let value = isHex ? UInt32(digits, radix: 16) : UInt32(digits)
                        if let v = value, let scalar = Unicode.Scalar(v),
                           !(0xD800...0xDFFF).contains(v) {
                            result.append(Character(scalar))
                            i = rest.index(after: j)
                            continue
                        }
                    }
                }
            }
            result.append(out[i])
            i = out.index(after: i)
        }
        // Any leftover named entity we don't know: strip it.
        return result.replacingOccurrences(of: "&[a-zA-Z]+;", with: "",
                                           options: .regularExpression)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
