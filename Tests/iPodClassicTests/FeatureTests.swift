import XCTest
import Compression
@testable import iPodClassic

// MARK: - Alarm repeats

final class AlarmRepeatTests: XCTestCase {
    private let alarm = AlarmStore.shared

    override func setUp() {
        super.setUp()
        // Never touch notification scheduling from tests.
        alarm.enabled = false
    }

    override func tearDown() {
        alarm.repeatDays = [Bool](repeating: false, count: 7)
        super.tearDown()
    }

    func testRepeatLabelDefaults() {
        alarm.repeatDays = [Bool](repeating: false, count: 7)
        XCTAssertEqual(alarm.repeatLabel, "Every Day")
        alarm.repeatDays = [Bool](repeating: true, count: 7)
        XCTAssertEqual(alarm.repeatLabel, "Every Day")
    }

    func testRepeatLabelPresets() {
        // Sunday-first: Mon–Fri weekdays, Sat+Sun weekends.
        alarm.repeatDays = [false, true, true, true, true, true, false]
        XCTAssertEqual(alarm.repeatLabel, "Weekdays")
        alarm.repeatDays = [true, false, false, false, false, false, true]
        XCTAssertEqual(alarm.repeatLabel, "Weekends")
    }

    func testRepeatLabelCustomDays() {
        alarm.repeatDays = [false, true, false, true, false, false, false]  // Mon + Wed
        let label = alarm.repeatLabel
        XCTAssertTrue(label.contains("Mon"), "custom label \(label) missing Mon")
        XCTAssertTrue(label.contains("Wed"), "custom label \(label) missing Wed")
        XCTAssertFalse(label.contains("Tue"))
    }

    func testRepeatDaysPersistAsBitmask() {
        alarm.repeatDays = [true, false, true, false, false, false, false]  // Sun + Tue
        let stored = UserDefaults.standard.integer(forKey: "alarm.repeatDays")
        // Sunday-first: bit 0 = Sunday (1), bit 2 = Tuesday (4).
        XCTAssertEqual(stored, 0b101, "repeatDays should persist as a Sunday-first bitmask")
    }

    func testBitmaskRoundTripAfterReload() {
        alarm.repeatDays = [false, false, false, false, false, true, true]  // Fri + Sat
        let mask = UserDefaults.standard.integer(forKey: "alarm.repeatDays")
        XCTAssertEqual(ReaderTestsSupport.days(fromBitmask: mask), [false, false, false, false, false, true, true])
    }
}

/// Bit twiddling mirrored from AlarmStore (private there).
enum ReaderTestsSupport {
    static func days(fromBitmask mask: Int) -> [Bool] {
        (0..<7).map { mask & (1 << $0) != 0 }
    }
}

// MARK: - Player

final class PlayerModelTests: XCTestCase {
    func testVolumeClamps() {
        let player = PlayerModel()
        player.setVolume(-1)
        XCTAssertEqual(player.volume, 0, accuracy: 0.001)
        player.setVolume(2)
        XCTAssertEqual(player.volume, 1, accuracy: 0.001)
        player.setVolume(0.42)
        XCTAssertEqual(player.volume, 0.42, accuracy: 0.001)
    }

    func testEmptyQueueHasNoSong() {
        let player = PlayerModel()
        XCTAssertNil(player.currentSong)
        XCTAssertEqual(player.duration, 0)
        XCTAssertTrue(player.upNext.isEmpty)
    }
}

// MARK: - Reader store

final class ReaderStoreTests: XCTestCase {
    private var store: ReaderStore { ReaderStore.shared }

    override func tearDown() {
        for book in store.books { store.remove(book) }
        super.tearDown()
    }

    private func makeTempFile(name: String, ext: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)")
            .appendingPathExtension(ext)
        try? Data("dummy".utf8).write(to: url)
        return url
    }

    func testAddPDFRegistersBook() throws {
        let file = makeTempFile(name: "Test Book ZZ", ext: "pdf")
        let book = try store.addBook(from: file)
        defer { store.remove(book) }
        XCTAssertEqual(book.kind, .pdf)
        XCTAssertTrue(book.title.hasPrefix("Test Book ZZ"), "title was \(book.title)")
        XCTAssertTrue(store.books.contains { $0.id == book.id })
        // The copy must land in Books/.
        XCTAssertTrue(FileManager.default.fileExists(atPath: ReaderStore.booksRoot
            .appendingPathComponent(book.id).appendingPathExtension("pdf").path))
    }

    func testUnsupportedKindRejected() {
        let file = makeTempFile(name: "Not A Book", ext: "txt")
        XCTAssertThrowsError(try store.addBook(from: file))
    }

    func testDuplicateNamesGetSuffix() throws {
        let a = makeTempFile(name: "Dup Book QQ", ext: "pdf")
        let b = makeTempFile(name: "Dup Book QQ", ext: "pdf")
        let first = try store.addBook(from: a)
        let second = try store.addBook(from: b)
        defer { store.remove(first); store.remove(second) }
        XCTAssertNotEqual(first.id, second.id)
    }

    func testUpdatePersistsLocation() throws {
        let file = makeTempFile(name: "Locate Book QQ", ext: "pdf")
        let book = try store.addBook(from: file)
        defer { store.remove(book) }
        var moved = book
        moved.chapterIndex = 5
        moved.scrollFraction = 0.5
        store.update(moved)
        let fetched = store.book(id: book.id)
        XCTAssertEqual(fetched?.chapterIndex, 5)
        XCTAssertEqual(fetched?.scrollFraction ?? 0, 0.5, accuracy: 0.001)
    }

    func testRemoveDeletesFiles() throws {
        let file = makeTempFile(name: "Gone Book QQ", ext: "pdf")
        let book = try store.addBook(from: file)
        let path = ReaderStore.booksRoot.appendingPathComponent(book.id).appendingPathExtension("pdf").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        store.remove(book)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertNil(store.book(id: book.id))
    }
}

// MARK: - ZIP / EPUB

final class EpubUnzipTests: XCTestCase {
    /// Builds a ZIP byte stream with STORE or DEFLATE entries.
    private func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)] }
    private func le32(_ v: Int) -> [UInt8] { le16(v & 0xffff) + le16((v >> 16) & 0xffff) }

    private func buildZip(_ entries: [(name: String, data: Data)]) -> Data {
        var out: [UInt8] = []
        var central: [UInt8] = []

        var offsets: [Int] = []
        for e in entries {
            offsets.append(out.count)
            let name = [UInt8](e.name.utf8)
            out += [0x50, 0x4b, 0x03, 0x04]
            out += le16(20) + le16(0) + le16(0)          // version, flags, method (stored)
            out += le16(0) + le16(0)                     // time, date
            out += le32(0)                               // crc32 (extractor ignores it)
            out += le32(e.data.count) + le32(e.data.count)
            out += le16(name.count) + le16(0)
            out += name
            out += [UInt8](e.data)
        }
        // Rewrite stored sizes into central directory below (method 0).
        for (i, e) in entries.enumerated() {
            let name = [UInt8](e.name.utf8)
            central += [0x50, 0x4b, 0x01, 0x02]
            central += le16(20) + le16(20) + le16(0)     // version made/read, flags
            central += le16(0)                            // method: stored
            central += le16(0) + le16(0)                  // time, date
            central += le32(0)                            // crc32 (extractor ignores it)
            central += le32(e.data.count) + le32(e.data.count)
            central += le16(name.count) + le16(0) + le16(0) + le16(0) + le16(0)
            central += le32(0) + le32(offsets[i])
            central += name
        }
        let cdStart = out.count
        out += central
        out += [0x50, 0x4b, 0x05, 0x06]
        out += le16(0) + le16(0)
        out += le16(entries.count) + le16(entries.count)
        out += le32(central.count) + le32(cdStart)
        out += le16(0)
        return Data(out)
    }

    func testExtractsStoredEntriesWithSubdirectories() throws {
        let zip = buildZip([
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data("<container/>".utf8)),
            ("OEBPS/text/ch1.xhtml", Data("<html><body>hi</body></html>".utf8)),
        ])
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("ziptest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dest) }

        try EpubUnzip.extract(data: zip, to: dest)

        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("mimetype")), Data("application/epub+zip".utf8))
        let nested = dest.appendingPathComponent("OEBPS/text/ch1.xhtml")
        XCTAssertEqual(try String(contentsOf: nested, encoding: .utf8), "<html><body>hi</body></html>")
    }

    func testExtractsDeflatedEntries() throws {
        let payload = Data(String(repeating: "compress me ", count: 40).utf8)
        let raw = [UInt8](payload)
        var deflated = [UInt8](repeating: 0, count: raw.count + 128)
        let written = raw.withUnsafeBufferPointer { src in
            deflated.withUnsafeMutableBufferPointer { dst in
                compression_encode_buffer(dst.baseAddress!, dst.count,
                                          src.baseAddress!, src.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        XCTAssertGreaterThan(written, 0, "deflate failed")
        let compressed = Array(deflated[0..<written])

        // Assemble a zip with one DEFLATE entry (method 8).
        var out: [UInt8] = []
        var central: [UInt8] = []
        let name = [UInt8]("big.txt".utf8)
        let offset = out.count
        out += [0x50, 0x4b, 0x03, 0x04]
        out += le16(20) + le16(0) + le16(8)
        out += le16(0) + le16(0)
        out += le32(0)                          // crc32 (extractor ignores it)
        out += le32(compressed.count) + le32(raw.count)
        out += le16(name.count) + le16(0)
        out += name
        out += compressed
        central += [0x50, 0x4b, 0x01, 0x02]
        central += le16(20) + le16(20) + le16(0) + le16(8)
        central += le16(0) + le16(0)
        central += le32(0)                          // crc32 (extractor ignores it)
        central += le32(compressed.count) + le32(raw.count)
        central += le16(name.count) + le16(0) + le16(0) + le16(0) + le16(0)
        central += le32(0) + le32(offset)
        central += name
        let cdStart = out.count
        out += central
        out += [0x50, 0x4b, 0x05, 0x06] + le16(0) + le16(0) + le16(1) + le16(1) + le32(central.count) + le32(cdStart) + le16(0)

        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("ziptest-deflate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dest) }
        try EpubUnzip.extract(data: Data(out), to: dest)
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("big.txt")), payload)
    }

    func testGarbageThrows() {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("ziptest-bad-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dest) }
        XCTAssertThrowsError(try EpubUnzip.extract(data: Data("not a zip".utf8), to: dest))
    }

    func testSkipsPathTraversalEntries() throws {
        let zip = buildZip([
            ("../evil.txt", Data("nope".utf8)),
            ("safe.txt", Data("ok".utf8)),
        ])
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("ziptest-traversal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dest) }
        try EpubUnzip.extract(data: zip, to: dest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent("evil.txt").path))
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("safe.txt"), encoding: .utf8), "ok")
    }
}

final class EpubParserTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent("epub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workDir.appendingPathComponent("OEBPS"), withIntermediateDirectories: true)

        try Data("""
        <container version="1.0">
          <rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles>
        </container>
        """.utf8).write(to: workDir.appendingPathComponent("META-INF/container.xml"))

        try Data("""
        <package>
          <manifest>
            <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="c2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
            <item id="css" href="style.css" media-type="text/css"/>
          </manifest>
          <spine><itemref idref="c1"/><itemref idref="c2"/></spine>
        </package>
        """.utf8).write(to: workDir.appendingPathComponent("OEBPS/content.opf"))

        try Data("<html><head><title>Alpha Begins</title></head><body><p>x</p></body></html>".utf8)
            .write(to: workDir.appendingPathComponent("OEBPS/ch1.xhtml"))
        try Data("<html><body><p>no title here</p></body></html>".utf8)
            .write(to: workDir.appendingPathComponent("OEBPS/ch2.xhtml"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    func testSpineOrderAndTitles() {
        let chapters = EpubParser.load(bookDir: workDir)
        XCTAssertEqual(chapters.count, 2, "only spine XHTML docs become chapters")
        XCTAssertEqual(chapters[0].title, "Alpha Begins")
        XCTAssertEqual(chapters[0].url.lastPathComponent, "ch1.xhtml")
        // Missing <title> falls back to "Chapter N" (1-based over the spine).
        XCTAssertEqual(chapters[1].title, "Chapter 2")
    }

    func testSpineSkipsNonDocuments() {
        // The CSS item is in the manifest but not the spine, and must not
        // become a chapter; this just pins the count.
        let chapters = EpubParser.load(bookDir: workDir)
        XCTAssertFalse(chapters.contains { $0.url.pathExtension == "css" })
    }

    func testTitleParsingHelpers() {
        let url = workDir.appendingPathComponent("OEBPS/ch1.xhtml")
        XCTAssertEqual(EpubParser.documentTitle(url, fallback: "F"), "Alpha Begins")
        XCTAssertEqual(EpubParser.documentTitle(workDir.appendingPathComponent("missing.xhtml"), fallback: "F"), "F")
    }
}
