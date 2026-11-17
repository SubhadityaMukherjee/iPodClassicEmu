import Foundation

/// One saved highlight: the chapter it was made in plus the highlighted
/// text (text-anchored, so it survives font-size/reflow changes).
struct BookHighlight: Codable, Identifiable, Equatable {
    let id: String
    /// Chapter index at capture time: EPUB spine index, reflow chapter
    /// index, or PDF page index.
    let chapter: Int
    let text: String
}

/// Highlights live WITH the book (epub folder / pdf sibling file) so they
/// stay in sync when books are copied around or deleted.
enum HighlightStore {
    /// Where a book's highlights live: inside the EPUB's folder, or as a
    /// JSON sibling of the PDF file — so they travel and die with the book.
    ///
    /// - Returns: the highlights.json path for the given book/kind.
    ///
    /// Concept: filemanager-and-sandbox → docs/concepts/filemanager-and-sandbox.md
    static func url(bookID: String, kind: ReaderStore.Book.Kind) -> URL {
        let root = ReaderStore.booksRoot
        switch kind {
        case .epub: return root.appendingPathComponent(bookID).appendingPathComponent("highlights.json")
        case .pdf: return root.appendingPathComponent(bookID).appendingPathExtension("pdf.highlights.json")
        }
    }

    /// Reads a book's saved highlights.
    ///
    /// - Returns: the stored list, or [] when nothing is saved yet or
    ///   the JSON is unreadable.
    static func load(bookID: String, kind: ReaderStore.Book.Kind) -> [BookHighlight] {
        guard let data = try? Data(contentsOf: url(bookID: bookID, kind: kind)),
              let items = try? JSONDecoder().decode([BookHighlight].self, from: data) else { return [] }
        return items
    }

    /// Writes the full list atomically — a crash mid-write can't corrupt
    /// the previous copy.
    static func save(_ highlights: [BookHighlight], bookID: String, kind: ReaderStore.Book.Kind) {
        guard let data = try? JSONEncoder().encode(highlights) else { return }
        try? data.write(to: url(bookID: bookID, kind: kind), options: .atomic)
    }
}

/// JavaScript building blocks for EPUB highlighting in the reader web
/// view. Interpolations here are plain Swift interpolation — the output is
/// JavaScript source passed to evaluateJavaScript (see memory: escaped
/// `\\(` ships literal text and silently breaks).
enum HighlightJS {
    /// Reports the selection text to the "selection" message handler as it
    /// changes (empty too, so the UI can dismiss its action bar).
    static let selectionWatch = """
    (function(){
      var last = null;
      function tick() {
        var sel = window.getSelection ? String(window.getSelection()) : '';
        if (sel !== last) {
          last = sel;
          if (window.webkit && window.webkit.messageHandlers.selection) {
            window.webkit.messageHandlers.selection.postMessage(sel);
          }
        }
      }
      document.addEventListener('selectionchange', function(){ setTimeout(tick, 120); });
    })()
    """

    /// Wraps the current selection in persistent <mark class="ipod-hl">
    /// elements and returns the selected text.
    static let wrapSelection = """
    (function(){
      var sel = window.getSelection();
      if (!sel.rangeCount || sel.isCollapsed) return '';
      var text = sel.toString();
      for (var i = 0; i < sel.rangeCount; i++) {
        var r = sel.getRangeAt(i);
        var mark = document.createElement('mark');
        mark.className = 'ipod-hl';
        mark.appendChild(r.extractContents());
        r.insertNode(mark);
      }
      sel.removeAllRanges();
      return text;
    })()
    """

    /// Collapses the selection without changing the DOM.
    static let clearSelection = "window.getSelection().removeAllRanges()"

    /// Re-wraps saved highlight texts after a chapter load. The document
    /// offset map is rebuilt after every wrap — earlier wraps mutate the
    /// DOM, so stale indexes would duplicate or misplace text.
    static func restore(texts: [String]) -> String {
        let payload = String(data: (try? JSONEncoder().encode(texts)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
        return """
        (function(texts){
          function buildMap() {
            var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
            var nodes = [], full = '';
            while (walker.nextNode()) {
              var n = walker.currentNode;
              if (!n.nodeValue || !n.nodeValue.trim()) continue;
              if (n.parentElement && n.parentElement.closest('mark.ipod-hl')) continue;
              nodes.push(n);
              full += n.nodeValue;
            }
            return {nodes: nodes, full: full};
          }
          texts.forEach(function(t) {
            var state = buildMap();
            var start = state.full.indexOf(t);
            if (start < 0) return;
            var end = start + t.length, cursor = 0;
            for (var i = 0; i < state.nodes.length; i++) {
              var node = state.nodes[i];
              var nodeStart = cursor, nodeEnd = cursor + node.nodeValue.length;
              cursor = nodeEnd;
              if (nodeEnd <= start || nodeStart >= end) continue;
              var range = document.createRange();
              range.setStart(node, Math.max(0, start - nodeStart));
              range.setEnd(node, Math.min(node.nodeValue.length, end - nodeStart));
              var mark = document.createElement('mark');
              mark.className = 'ipod-hl';
              mark.appendChild(range.extractContents());
              range.insertNode(mark);
            }
          });
        })(\(payload))
        """
    }
}
