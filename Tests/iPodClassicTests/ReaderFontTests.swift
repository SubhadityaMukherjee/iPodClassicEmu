import XCTest
@testable import iPodClassic

/// The reader's font-family setting: shared name/stack lists and the CSS
/// the EPUB controller injects for each persisted index (with clamping).
final class ReaderFontTests: XCTestCase {
    func testNamesAndStacksStayInSync() {
        XCTAssertEqual(ReaderStore.Book.fontFamilyNames.count,
                       ReaderStore.Book.fontFamilyStacks.count,
                       "font names and CSS stacks must be index-parallel")
        XCTAssertGreaterThan(ReaderStore.Book.fontFamilyNames.count, 2,
                             "adding fonts was the point — there should be more than Serif/Sans")
    }

    func testEachIndexInjectsItsStack() {
        for (idx, stack) in ReaderStore.Book.fontFamilyStacks.enumerated() {
            let book = ReaderStore.Book(id: "t", kind: .epub, title: "T", fontFamily: idx)
            let css = EpubController.cssJS(for: book)
            XCTAssertTrue(css.contains("font-family:\(stack)"),
                          "fontFamily=\(idx) must inject \(stack)")
        }
    }

    func testOutOfRangeIndicesClamp() {
        let high = EpubController.cssJS(for: ReaderStore.Book(id: "t", kind: .epub, title: "T", fontFamily: 99))
        XCTAssertTrue(high.contains(ReaderStore.Book.fontFamilyStacks.last!),
                      "fontFamily=99 must clamp to the last font")

        let low = EpubController.cssJS(for: ReaderStore.Book(id: "t", kind: .epub, title: "T", fontFamily: -3))
        XCTAssertTrue(low.contains(ReaderStore.Book.fontFamilyStacks.first!),
                      "fontFamily=-3 must clamp to the first font")
    }

    func testLegacyValuesStillDecode() {
        // Books persisted when only Serif(0)/Sans(1) existed decode unchanged.
        let json = """
        {"id":"t","kind":"epub","title":"T","fontSize":18,"fontFamily":1}
        """
        let book = try! JSONDecoder().decode(ReaderStore.Book.self, from: Data(json.utf8))
        XCTAssertEqual(book.fontFamily, 1)
    }

    func testCssCarriesSizeSpacingAndMargins() {
        // Guards the Swift→JS string interpolation (the double-backslash
        // escape bug once silently dropped every style here).
        let book = ReaderStore.Book(id: "t", kind: .epub, title: "T",
                                    fontSize: 20, fontFamily: 1, lineSpacing: 2, margin: 2)
        let css = EpubController.cssJS(for: book)
        XCTAssertTrue(css.contains("font-size:20px"), "body + inherit font-size must carry the px value")
        XCTAssertTrue(css.contains("line-height:1.75"), "widest spacing maps to 1.75")
        XCTAssertTrue(css.contains("column-gap:48px"), "margin index 2 = 24px side → 48px gap")
        XCTAssertTrue(css.contains("column-width:calc(100vw - 48px)"))
        XCTAssertTrue(css.contains("hyphens:auto"), "hyphenation must survive every change")
    }

    func testCssTightMarginsAndSpacing() {
        let book = ReaderStore.Book(id: "t", kind: .epub, title: "T",
                                    fontSize: 11, fontFamily: 0, lineSpacing: 0, margin: 0)
        let css = EpubController.cssJS(for: book)
        XCTAssertTrue(css.contains("font-size:11px"))
        XCTAssertTrue(css.contains("line-height:1.4"), "compact spacing maps to 1.4")
        XCTAssertTrue(css.contains("column-gap:20px"), "margin index 0 = 10px side → 20px gap")
    }
}
