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

/// Parses container.xml → OPF manifest/spine into an ordered chapter list
/// with human titles pulled from each document's <title>.
enum EpubParser {
    static func load(bookDir: URL) -> [EpubChapter] {
        let containerURL = bookDir.appendingPathComponent("META-INF/container.xml")
        guard let containerData = try? Data(contentsOf: containerURL),
              let rootFile = parseContainer(containerData) else { return [] }

        let opfURL = bookDir.appendingPathComponent(rootFile)
        guard let opfData = try? Data(contentsOf: opfURL) else { return [] }
        let opf = parseOPF(opfData)
        let opfDir = opfURL.deletingLastPathComponent()

        var chapters: [EpubChapter] = []
        for idref in opf.spine {
            guard let item = opf.manifest[idref] else { continue }
            let media = item.mediaType.lowercased()
            guard media.contains("xhtml") || media.contains("html") else { continue }
            let href = item.href.removingPercentEncoding ?? item.href
            let url = opfDir.appendingPathComponent(href)
            let title = documentTitle(url, fallback: "Chapter \(chapters.count + 1)")
            chapters.append(EpubChapter(index: chapters.count, title: title, url: url))
        }
        return chapters
    }

    // MARK: XML plumbing

    private static func parseContainer(_ data: Data) -> String? {
        let delegate = ContainerDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.rootFile
    }

    private static func parseOPF(_ data: Data) -> (manifest: [String: (href: String, mediaType: String)], spine: [String]) {
        let delegate = OPFDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return (delegate.manifest, delegate.spine)
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
        var manifest: [String: (href: String, mediaType: String)] = [:]
        var spine: [String] = []

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            if name == "item", let id = attributes["id"], let href = attributes["href"] {
                manifest[id] = (href, attributes["media-type"] ?? "")
            } else if name == "itemref", let idref = attributes["idref"] {
                spine.append(idref)
            }
        }
    }

    /// <title> of a document (tags/entities stripped); falls back to <h1>.
    static func documentTitle(_ url: URL, fallback: String) -> String {
        guard let html = try? String(contentsOf: url, encoding: .utf8) else { return fallback }
        let patterns = ["<title[^>]*>([\\s\\S]*?)</title>", "<h1[^>]*>([\\s\\S]*?)</h1>"]
        for p in patterns {
            if let regex = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]),
               let m = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let r = Range(m.range(at: 1), in: html) {
                let raw = String(html[r])
                var text = raw.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                text = text.replacingOccurrences(of: "&nbsp;", with: " ")
                    .replacingOccurrences(of: "&amp;", with: "&")
                    .replacingOccurrences(of: "&lt;", with: "<")
                    .replacingOccurrences(of: "&gt;", with: ">")
                    .replacingOccurrences(of: "&quot;", with: "\"")
                    .replacingOccurrences(of: "&#39;", with: "'")
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return fallback
    }
}
