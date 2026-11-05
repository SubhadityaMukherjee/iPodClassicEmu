import Foundation
import Compression

/// Minimal ZIP reader for EPUB containers. Reads the central directory
/// (sizes are always present there), then inflates each entry — Apple's
/// COMPRESSION_ZLIB is raw deflate, which is exactly what ZIP uses.
enum EpubUnzip {
    enum UnzipError: LocalizedError {
        case badArchive
        case unsupportedEntry(String)

        var errorDescription: String? {
            switch self {
            case .badArchive: return "Not a valid ZIP/EPUB file"
            case .unsupportedEntry(let name): return "Unsupported compression for \(name)"
            }
        }
    }

    static func extract(zipURL: URL, to destination: URL) throws {
        let data = try Data(contentsOf: zipURL)
        try extract(data: data, to: destination)
    }

    static func extract(data: Data, to destination: URL) throws {
        let bytes = [UInt8](data)
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        let cd = try centralDirectory(bytes)
        for entry in cd.entries {
            let name = String(decoding: entry.name, as: UTF8.self)
            let safeComponents = name.split(separator: "/", omittingEmptySubsequences: true)
            guard !safeComponents.isEmpty, !safeComponents.contains("..") else { continue }
            var target = destination
            for c in safeComponents { target = target.appendingPathComponent(String(c)) }

            if name.hasSuffix("/") {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            let fileData = try entryData(bytes, entry)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileData.write(to: target)
        }
    }

    // MARK: ZIP structures

    private struct CDEntry {
        let name: [UInt8]
        let method: Int
        let compressedSize: Int
        let uncompressedSize: Int
        let localOffset: Int
    }

    private struct CentralDirectory {
        var entries: [CDEntry] = []
    }

    private static func u16(_ b: [UInt8], _ o: Int) -> Int {
        Int(b[o]) | (Int(b[o + 1]) << 8)
    }

    private static func u32(_ b: [UInt8], _ o: Int) -> Int {
        u16(b, o) | (u16(b, o + 2) << 16)
    }

    /// End-of-central-directory record: scan backwards (comment may follow).
    private static func findEOCD(_ b: [UInt8]) throws -> Int {
        let sig: [UInt8] = [0x50, 0x4b, 0x05, 0x06]
        guard b.count >= 22 else { throw UnzipError.badArchive }
        var i = b.count - 22
        while i >= 0 {
            if b[i] == sig[0], b[i + 1] == sig[1], b[i + 2] == sig[2], b[i + 3] == sig[3] {
                return i
            }
            i -= 1
        }
        throw UnzipError.badArchive
    }

    private static func centralDirectory(_ b: [UInt8]) throws -> CentralDirectory {
        let eocd = try findEOCD(b)
        let count = u16(b, eocd + 10)
        var offset = u32(b, eocd + 16)
        var result = CentralDirectory()
        let sig: [UInt8] = [0x50, 0x4b, 0x01, 0x02]
        for _ in 0..<count {
            guard offset + 46 <= b.count, Array(b[offset..<offset + 4]) == sig else { break }
            let nameLen = u16(b, offset + 28)
            let extraLen = u16(b, offset + 30)
            let commentLen = u16(b, offset + 32)
            result.entries.append(CDEntry(
                name: Array(b[(offset + 46)..<(offset + 46 + nameLen)]),
                method: u16(b, offset + 10),
                compressedSize: u32(b, offset + 20),
                uncompressedSize: u32(b, offset + 24),
                localOffset: u32(b, offset + 42)))
            offset += 46 + nameLen + extraLen + commentLen
        }
        return result
    }

    /// Data of one entry: skip past its local header (name/extra lengths in
    /// the local header can differ from the central directory's).
    private static func entryData(_ b: [UInt8], _ entry: CDEntry) throws -> Data {
        let localSig: [UInt8] = [0x50, 0x4b, 0x03, 0x04]
        let o = entry.localOffset
        guard o + 30 <= b.count, Array(b[o..<o + 4]) == localSig else { throw UnzipError.badArchive }
        let nameLen = u16(b, o + 26)
        let extraLen = u16(b, o + 28)
        let start = o + 30 + nameLen + extraLen
        let end = start + entry.compressedSize
        guard end <= b.count else { throw UnzipError.badArchive }

        let compressed = Array(b[start..<end])
        switch entry.method {
        case 0:  // stored
            return Data(compressed)
        case 8:  // deflate
            let inflated = try inflate(compressed, outputSize: entry.uncompressedSize)
            return Data(inflated)
        default:
            throw UnzipError.unsupportedEntry(String(decoding: entry.name, as: UTF8.self))
        }
    }

    private static func inflate(_ input: [UInt8], outputSize: Int) throws -> [UInt8] {
        guard outputSize > 0 else { return [] }
        var output = [UInt8](repeating: 0, count: outputSize)
        let written = input.withUnsafeBufferPointer { src -> Int in
            output.withUnsafeMutableBufferPointer { dst -> Int in
                compression_decode_buffer(
                    dst.baseAddress!, dst.count,
                    src.baseAddress!, src.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard written == outputSize else { throw UnzipError.badArchive }
        return output
    }
}

// MARK: - EPUB structure

/// One readable chapter (spine document) of an EPUB.
struct EpubChapter: Identifiable, Equatable {
    let index: Int
    let title: String
    let url: URL

    var id: Int { index }
}

/// Parses container.xml → OPF manifest/spine into an ordered chapter list.
/// Titles come from the book's own TOC when present (EPUB2 toc.ncx /
/// EPUB3 nav document, the authoritative names), then each document's
/// <title>/<h1>/<h2>, then a "Chapter N" fallback.
enum EpubParser {
    static func load(bookDir: URL) -> [EpubChapter] {
        let containerURL = bookDir.appendingPathComponent("META-INF/container.xml")
        guard let containerData = try? Data(contentsOf: containerURL),
              let rootFile = parseContainer(containerData) else { return [] }

        let opfURL = bookDir.appendingPathComponent(rootFile)
        guard let opfData = try? Data(contentsOf: opfURL) else { return [] }
        let opf = parseOPF(opfData)
        let opfDir = opfURL.deletingLastPathComponent()

        // The TOC maps OPF-relative hrefs to human titles.
        let tocMap = parseTOC(bookDir: bookDir, opfDir: opfDir, opf: opf)

        var chapters: [EpubChapter] = []
        for idref in opf.spine {
            guard let item = opf.manifest[idref] else { continue }
            let media = item.mediaType.lowercased()
            guard media.contains("xhtml") || media.contains("html") else { continue }
            let href = item.href.removingPercentEncoding ?? item.href
            let url = opfDir.appendingPathComponent(href)
            let fallback = "Chapter \(chapters.count + 1)"
            let title = tocMap[normalizeHref(href)]
                ?? documentTitle(url, fallback: fallback)
            chapters.append(EpubChapter(index: chapters.count, title: title, url: url))
        }
        return chapters
    }

    /// Strips fragments and leading "./" so OPF and TOC hrefs compare equal.
    static func normalizeHref(_ href: String) -> String {
        let noFragment = href.split(separator: "#").first.map(String.init) ?? href
        var h = noFragment
        while h.hasPrefix("./") { h = String(h.dropFirst(2)) }
        return h
    }

    // MARK: TOC (NCX + EPUB3 nav)

    private struct ManifestItem {
        let href: String
        let mediaType: String
        let properties: String
    }

    private struct OPF {
        var manifest: [String: ManifestItem] = [:]
        var spine: [String] = []
        var tocID: String?
    }

    private static func parseTOC(bookDir: URL, opfDir: URL, opf: OPF) -> [String: String] {
        var map: [String: String] = [:]

        // EPUB2: the NCX file named by spine@toc or by media type.
        var ncxHref: String? = opf.manifest.values.first { $0.mediaType.lowercased().contains("dtbncx") }?.href
            ?? opf.manifest[opf.tocID ?? ""]?.href
        if let href = ncxHref, !href.isEmpty {
            let url = opfDir.appendingPathComponent(href.removingPercentEncoding ?? href)
            if let data = try? Data(contentsOf: url) {
                let delegate = NCXDelegate()
                let parser = XMLParser(data: data)
                parser.delegate = delegate
                parser.parse()
                for entry in delegate.entries {
                    map[normalizeHref(entry.src)] = entry.label
                }
            }
        }

        // EPUB3: the manifest item marked properties="…nav…" is the nav
        // document — an XHTML list of links in reading order.
        if let navItem = opf.manifest.values.first(where: { $0.properties.lowercased().contains("nav") }) {
            let url = opfDir.appendingPathComponent(navItem.href.removingPercentEncoding ?? navItem.href)
            if let html = try? String(contentsOf: url, encoding: .utf8) {
                let pattern = "<a[^>]*href\\s*=\\s*\"([^\"]+)\"[^>]*>([\\s\\S]*?)</a>"
                if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                    let ns = html as NSString
                    for m in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                        let src = ns.substring(with: m.range(at: 1))
                        let label = stripTags(ns.substring(with: m.range(at: 2)))
                        if !label.isEmpty { map[normalizeHref(src)] = label }
                    }
                }
            }
        }
        return map
    }

    // MARK: XML plumbing

    private static func parseContainer(_ data: Data) -> String? {
        let delegate = ContainerDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.rootFile
    }

    private static func parseOPF(_ data: Data) -> OPF {
        let delegate = OPFDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.opf
    }

    private final class ContainerDelegate: NSObject, XMLParserDelegate {
        var rootFile: String?

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            if name == "rootfile", rootFile == nil {
                rootFile = attributes["full-path"]
            }
        }
    }

    private final class OPFDelegate: NSObject, XMLParserDelegate {
        var opf = OPF()

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            if name == "item", let id = attributes["id"], let href = attributes["href"] {
                opf.manifest[id] = ManifestItem(href: href,
                                                mediaType: attributes["media-type"] ?? "",
                                                properties: attributes["properties"] ?? "")
            } else if name == "itemref", let idref = attributes["idref"] {
                opf.spine.append(idref)
                if let toc = attributes["toc"] { opf.tocID = toc }
            }
        }
    }

    /// Flattens the NCX navMap (navPoints nest) into (src, label) pairs.
    private final class NCXDelegate: NSObject, XMLParserDelegate {
        var entries: [(src: String, label: String)] = []
        private var frames: [(label: String?, src: String?)] = []
        private var inText = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            if name == "navPoint" {
                frames.append((nil, nil))
            } else if name == "text" && !frames.isEmpty {
                inText = true
                if frames[frames.count - 1].label == nil { frames[frames.count - 1].label = "" }
            } else if name == "content", !frames.isEmpty {
                frames[frames.count - 1].src = attributes["src"]
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inText, !frames.isEmpty, frames[frames.count - 1].label != nil {
                frames[frames.count - 1].label?.append(string)
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "text" {
                inText = false
            } else if name == "navPoint", !frames.isEmpty {
                let frame = frames.removeLast()
                if let label = frame.label?.trimmingCharacters(in: .whitespacesAndNewlines),
                   let src = frame.src, !label.isEmpty {
                    entries.append((src, label))
                }
            }
        }
    }

    // MARK: Titles without a TOC

    /// Strips tags and decodes entities; whitespace collapsed.
    private static func stripTags(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (entity, char) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
                               ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"),
                               ("&hellip;", "…"), ("&mdash;", "—"), ("&ndash;", "–")] {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        // Numeric entities: &#123; decimal and &#x1F; hex.
        text = decodeNumericEntities(text)
        return text
            .components(separatedBy: .whitespacesAndNewlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Replaces &#123; / &#xAB; with their characters.
    private static func decodeNumericEntities(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);", options: [.caseInsensitive]) else { return text }
        let ns = text as NSString
        var out = ""
        var cursor = 0
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match, match.range.location != NSNotFound else { return }
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let isHex = !ns.substring(with: match.range(at: 1)).isEmpty
            let digits = ns.substring(with: match.range(at: 2))
            let value = isHex ? Int(digits, radix: 16) : Int(digits)
            if let v = value, let scalar = Unicode.Scalar(v) {
                out += String(Character(scalar))
            }
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    /// <title> of a document (tags/entities stripped), then <h1>/<h2>;
    /// generic titles ("untitled", book-wide placeholders) are skipped in
    /// favor of the heading. Falls back to the caller's fallback.
    static func documentTitle(_ url: URL, fallback: String) -> String {
        guard let html = try? String(contentsOf: url, encoding: .utf8) else { return fallback }
        let generic = ["untitled", "table of contents", "content", "contents", "title"]
        var titleTag: String?
        var heading: String?
        for p in ["<title[^>]*>([\\s\\S]*?)</title>",
                  "<h1[^>]*>([\\s\\S]*?)</h1>",
                  "<h2[^>]*>([\\s\\S]*?)</h2>"] {
            guard let regex = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]),
                  let m = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let r = Range(m.range(at: 1), in: html) else { continue }
            let cleaned = stripTags(String(html[r]))
            if cleaned.isEmpty { continue }
            if titleTag == nil, p.contains("title") {
                if generic.contains(cleaned.lowercased()) { continue }
                titleTag = cleaned
            } else if heading == nil {
                heading = cleaned
            }
            if titleTag != nil || heading != nil { break }
        }
        return titleTag ?? heading ?? fallback
    }
}
