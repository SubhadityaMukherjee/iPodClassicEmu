import XCTest
@testable import iPodClassic

/// PDF text reflow: paragraph joining heuristics, chapter spans from the
/// outline, HTML escaping, and legacy PDF book decode (pdfMode migration).
final class PDFReflowTests: XCTestCase {
    // MARK: Paragraphs

    func testParagraphsJoinLinesAndBreakOnSentenceEnd() {
        let lines = [
            "It was at one time recognized that without",
            "social efficiency, no permanent progress",
            "was possible.",                       // paragraph last line
            "The second paragraph starts here and",
            "keeps going!",                        // terminal punct → break
            "A short trailing line",
        ]
        let paras = PDFReflow.paragraphs(from: lines)
        XCTAssertEqual(paras.count, 3)
        XCTAssertEqual(paras[0], "It was at one time recognized that without social efficiency, no permanent progress was possible.")
        XCTAssertEqual(paras[1], "The second paragraph starts here and keeps going!")
        XCTAssertEqual(paras[2], "A short trailing line")
    }

    func testParagraphsDehyphenateLineBreaks() {
        let paras = PDFReflow.paragraphs(from: ["a long and consid-", "erable intro-,", "duction line."])
        // "consid-/erable" joins without a space (letter before the
        // hyphen); "intro-," keeps its hyphen and joins with a space
        // (the line ends with a comma, not a hyphenated word break).
        XCTAssertEqual(paras, ["a long and considerable intro-, duction line."])
    }

    func testParagraphsSkipBlankLines() {
        XCTAssertEqual(PDFReflow.paragraphs(from: ["one.", "", "  ", "two."]), ["one.", "two."])
    }

    func testEscapeHTML() {
        XCTAssertEqual(PDFReflow.escapeHTML("a & b <c> \"d\""), "a &amp; b &lt;c&gt; \"d\"")
    }

    func testHtmlCarriesViewportAndParagraphs() {
        let html = PDFReflow.html(title: "Ch <1>", paragraphs: ["first", "second"])
        XCTAssertTrue(html.contains("width=device-width"))
        XCTAssertTrue(html.contains("<p>first</p>"))
        XCTAssertTrue(html.contains("<title>Ch &lt;1&gt;</title>"))
    }

    // MARK: Spans

    private func entry(_ id: Int, _ title: String, page: Int?, level: Int = 0) -> OutlineEntry {
        OutlineEntry(id: id, title: title, pageIndex: page, level: level)
    }

    func testSpansFromTopLevelOutline() {
        let outline = [
            entry(0, "Preface", page: 0),
            entry(1, "Part One", page: 3),
            entry(2, "Intro", page: 4, level: 1),   // nested → folded into Part One
            entry(3, "Part Two", page: 9),
            entry(4, "Duplicate at same page", page: 9),
            entry(5, "No destination", page: nil),
        ]
        let spans = PDFReflow.spans(outline: outline, pageCount: 20)
        XCTAssertEqual(spans.map(\.title), ["Preface", "Part One", "Part Two"])
        XCTAssertEqual(spans.map(\.start), [0, 3, 9])
        XCTAssertEqual(spans.map(\.end), [3, 9, 20])
    }

    func testSpansWithoutOutlineSingleChapter() {
        let spans = PDFReflow.spans(outline: [], pageCount: 50)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].start, 0)
        XCTAssertEqual(spans[0].end, 50)
        XCTAssertEqual(spans[0].title, "Book")
    }

    func testSpansRefuseEmptyPageCount() {
        XCTAssertTrue(PDFReflow.spans(outline: [entry(0, "X", page: 0)], pageCount: 0).isEmpty)
    }

    // MARK: Legacy decode

    func testLegacyPdfContinuousDecodesToMode() {
        let cont = try! JSONDecoder().decode(ReaderStore.Book.self, from: Data(
            #"{"id":"p","kind":"pdf","title":"P","pdfContinuous":true}"#.utf8))
        XCTAssertEqual(cont.pdfMode, 0)
        let single = try! JSONDecoder().decode(ReaderStore.Book.self, from: Data(
            #"{"id":"p","kind":"pdf","title":"P","pdfContinuous":false}"#.utf8))
        XCTAssertEqual(single.pdfMode, 1)
    }

    func testReflowFieldsDecodeAndDefault() {
        let book = try! JSONDecoder().decode(ReaderStore.Book.self, from: Data(
            #"{"id":"p","kind":"pdf","title":"P","pdfMode":2,"reflowChapter":3,"reflowFraction":0.5}"#.utf8))
        XCTAssertEqual(book.pdfMode, 2)
        XCTAssertEqual(book.reflowChapter, 3)
        XCTAssertEqual(book.reflowFraction, 0.5)
        let plain = try! JSONDecoder().decode(ReaderStore.Book.self, from: Data(
            #"{"id":"p","kind":"pdf","title":"P"}"#.utf8))
        XCTAssertEqual(plain.pdfMode, 0, "missing mode (and no legacy bool) = continuous")
        XCTAssertEqual(plain.reflowChapter, 0)
        XCTAssertEqual(plain.reflowFraction, 0)
    }
}
