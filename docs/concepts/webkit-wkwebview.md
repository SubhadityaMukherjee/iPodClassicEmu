# WKWebView — rendering books, and why it must be treated carefully

The reader renders EPUB/article/reflow content in a **`WKWebView`** —
an embedded WebKit browser view. That's the right tool: HTML/CSS is the
native format of EPUB, and re-flowing typography (fonts, justification,
columns) is exactly what a browser engine is world-class at. SwiftUI
has no equivalent.

## The bridge

`WKWebView` is UIKit — it enters SwiftUI through
`UIViewRepresentable` ([uiviewrepresentable.md](uiviewrepresentable.md)).
The reader loads generated HTML (chapter content + injected CSS for the
font/spacing settings) and talks to the page with **JavaScript**:

```swift
webView.evaluateJavaScript("window.innerWidth") { result, error in … }
```

`evaluateJavaScript` is asynchronous with a completion closure — results
arrive later, on the main thread. The reader's geometry probes
(`EpubController.chapterSegments`: sentences → rects → page index) are
static JS evaluated against the *settled* page.

## The three WebKit behaviors that shaped this code

### 1. Pagination is asynchronous
CSS multi-column layout doesn't paginate instantly: `scrollWidth`
**overshoots, then tightens** as WebKit finishes layout. Any code that
measures once and trusts the number is measuring garbage.

### 2. `about:blank` races
A freshly created web view sits on `about:blank`; evaluating JS before
the real page commits runs against the *wrong document* (or throws).

**Together these killed the "hidden measurer":** an offscreen WKWebView
that pre-measured every chapter's page count reported **1 page for
everything** — the races + async tightening made its numbers fiction.
The standing rule (do not re-add it): page counts are **estimated** from
stripped text length at current typography (a 0.44 em glyph prior), and
chapters the user actually visits get **exact** counts from
`readerPosition`, recalibrating the whole book. Approximate that
self-corrects beats precise that lies.

### 3. The viewport injection
Books without `<meta viewport>` lay out at 980 px — the reader injects
`width=device-width` so the LCD width drives the layout and columns
size honestly.

## Swift↔JS string escaping (the trap that shipped once)

Inside a Swift string, `\\(x)` emits the literal text `\(x)` —
interpolation does **not** happen. In JS source strings built in Swift,
interpolate with a **single** backslash `\(x)`. A double-backslacked
CSS injection once shipped invalid reader CSS silently. House rule:
verify generated JS with a standalone `swift` script before shipping.

## Where to look

- `Sources/Features/Reader/ReaderScreens.swift` — web view hosting,
  pagination, position probes, settings CSS injection.
- `Sources/Features/Reader/ReaderStore.swift` — position persistence.

## Related

[uiviewrepresentable.md](uiviewrepresentable.md) — the hosting bridge;
[epub-and-zip.md](epub-and-zip.md) — where the HTML comes from.
