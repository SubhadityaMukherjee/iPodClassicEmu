# EPUB & ZIP — containers, spines, and hand-rolled extraction

An EPUB **is a ZIP** containing XHTML chapters, an OPF manifest (what
exists), a spine (what order to read), and optionally a TOC (nav or
ncx). "Opening an EPUB" = unzip + parse three small XML files + render
the HTML — no heavyweight format underneath.

```
book.epub (ZIP)
├─ mimetype
├─ META-INF/container.xml      → points at the OPF
├─ OEBPS/content.opf           → manifest + spine (reading order)
├─ OEBPS/toc.ncx / nav.xhtml   → chapter titles/links
└─ OEBPS/chapter1.xhtml …
```

## Why extraction is hand-rolled (`EpubContainer`)

The project unzips with Apple's `Compression` framework (raw deflate —
no third-party dependency, no libzip licensing) and parses OPF/spine/
TOC with targeted string/XML parsing rather than a full XML DOM — the
files are small and regular, and chapter titles resolve in a fallback
chain: toc.ncx/EPUB3 nav text → chapter `<title>` → first `<h1>`.

ZIP mechanics worth knowing (all handled, all tested in
`EpubContainerTests`):

- Entries are either **stored** (raw bytes) or **deflate**-compressed —
  both must decode.
- Local file headers can disagree with the central directory
  (data-descriptor streams); trust the central directory.
- **Path traversal**: entry names like `../../evil` must be rejected —
  a hostile ZIP must never write outside the extraction directory (the
  traversal guard is unit-tested).

## The reader pipeline on top

- Chapters are extracted to `Documents/Books/<id>/` once at import;
  reading is then pure file serving
  ([filemanager-and-sandbox.md](filemanager-and-sandbox.md)).
- **Articles are mini-EPUBs**: `ArticleExtractor` strips boilerplate
  (script/style/nav/header/footer/aside, `<article>`/`<main>` scoping),
  collects paragraphs, entity-decodes (incl. numeric refs like
  `&#8212;`), and writes a one-chapter EPUB that flows through this
  exact pipeline — articles and books share everything downstream.
- **PDF reflow** also lands here: text PDFs are split into `<i>.html`
  chapters from outline spans and become EPUB-ish content.

## Where to look

- `Sources/Features/Reader/EpubContainer.swift` — ZIP + OPF/spine/TOC.
- `Sources/Features/Reader/ArticleExtractor.swift` — HTML → clean
  mini-EPUB.
- `Tests/iPodClassicTests/` — stored/deflate decoding + traversal guard.

## Related

[webkit-wkwebview.md](webkit-wkwebview.md) — rendering the chapters;
[swift-error-handling.md](swift-error-handling.md) — typed failures
(`missingFile`) surfacing precise import errors.
