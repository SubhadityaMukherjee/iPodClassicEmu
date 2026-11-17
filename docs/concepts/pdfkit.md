# PDFKit — page views, outlines, and annotations

PDFKit (`PDFDocument`, `PDFPage`, `PDFOutline`, `PDFAnnotation`) is
Apple's PDF engine. This SDK's API has sharp edges the reader code
navigates — the docstrings call them out, this page is the map.

## The API shape (and this SDK's quirks)

```swift
let doc = PDFDocument(url: url)
doc.pageCount                 // NO `.pages` property in this SDK!
doc.page(at: i)               // pages by index, optional
doc.index(for: page)          // reverse lookup

let outline = doc.outlineRoot // chapter tree: numberOfChildren + child(at:)
                              // (no .child/.siblings properties)
```

Iterating an outline is manual recursion
(`for i in 0..<outline.numberOfChildren { outline.child(at: i) }`) —
`PDFBookView.flattenOutline` does it once and caches a flat list of
`(title, pageIndex)` entries.

Text extraction: `page.string` gives the page's text — the reflow
pipeline (`PDFReflow`) and the audiobook's PDF page speech both start
there. Reflow splits by top-level outline spans (no outline = one whole
chunk) and joins paragraphs by sentence-terminal lines, de-hyphenating
across breaks; image-only PDFs have no extractable text and revert to
the page view with a toast instead of garbage.

## View modes (why three)

- **One Page** — PDFKit's own page view, zoomable; native feel for
  image PDFs and fixed layouts.
- **Continuous** — the classic scroll.
- **Reflowed** — text extracted into the EPUB pipeline
  ([epub-and-zip.md](epub-and-zip.md)) so font size/spacing settings
  apply; keeps its OWN position fields (`reflowChapter`/
  `reflowFraction`) so switching modes never moves the page-view
  position. Position fields per mode, always.

## Highlights are real PDF annotations

For PDFs, a highlight isn't app state — it's a native `PDFAnnotation`
(.highlight) **written into the PDF file itself**, so the marks survive
export to any other PDF reader. EPUB/reflow highlights instead anchor
to quoted text in the per-book store (`ReaderHighlights`), using the
DOM path for reflow. Two mechanisms, one UI.

## Where to look

- `Sources/Features/Reader/ReaderScreens.swift` — PDF book view, view
  modes, outline flattening.
- `Sources/Features/Reader/PDFReflow.swift` — text extraction.
- `Sources/Features/Reader/ReaderHighlights.swift` — annotation vs
  text-anchor strategies.

## Related

[webkit-wkwebview.md](webkit-wkwebview.md) — where reflowed text
renders; [epub-and-zip.md](epub-and-zip.md) — the pipeline reflow
feeds.
