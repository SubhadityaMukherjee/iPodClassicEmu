import SwiftUI

/// Notes list: New Note row plus existing notes; hold center to delete.
struct NotesListScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings
    @State private var selection = 0
    @State private var deleteCandidate: String?
    @State private var deleteSelection = 0

    var body: some View {
        ZStack {
            MenuList(
                items: listItems,
                selection: selection,
                emptyText: "No Notes",
                style: .twoLine
            )
            if deleteCandidate != nil {
                ModalHost { deletePanel }
                    .zIndex(2)
            }
            if holdItem != nil {
                ModalHost { holdPanel }
                    .zIndex(3)
            }
        }
        .onWheel { handle($0) }
        .onAppear { model.notes.loadNotes() }
        .sheet(isPresented: Binding(get: { shareText != nil }, set: { if !$0 { shareText = nil } })) {
            if let text = shareText {
                ActivityView(items: [text])
            }
        }
    }

    private var listItems: [MenuItem] {
        var items = [MenuItem(id: "__new__", title: "New Note", symbol: "plus.square", showsChevron: false)]
        items.append(contentsOf: model.notes.notes.map { note in
            MenuItem(id: note.id, title: note.name, subtitle: note.preview.isEmpty ? nil : note.preview, detail: TimeFormat.friendly(note.date), showsChevron: true)
        })
        return items
    }

    private var deletePanel: some View {
        ModalPanel(title: "Delete Note", onClose: { deleteCandidate = nil }) {
            VStack(spacing: 0) {
                MenuRow(item: MenuItem(id: "del.yes", title: "Delete", showsChevron: false), selected: deleteSelection == 0)
                    .frame(height: 30.5)
                MenuRow(item: MenuItem(id: "del.no", title: "Cancel", showsChevron: false), selected: deleteSelection == 1)
                    .frame(height: 30.5)
            }
            .padding(.top, 2)
        }
    }

    private func handle(_ event: ControlEvent) {
        if holdItem != nil {
            switch event {
            case .tick(let d):
                holdSelection = min(2, max(0, holdSelection + (d > 0 ? 1 : -1)))
                WheelFeedback.tick(dir: d)
            case .select:
                switch holdSelection {
                case 0: shareText = "\(holdItem ?? "")\n\n\(model.notes.read(holdItem ?? ""))"; holdItem = nil
                case 1: deleteCandidate = holdItem; deleteSelection = 1; holdItem = nil
                default: holdItem = nil
                }
            case .menu, .menuHold:
                holdItem = nil
            default:
                break
            }
            return
        }
        if deleteCandidate != nil {
            switch event {
            case .tick(let d):
                deleteSelection = deleteSelection == 0 ? 1 : 0
                WheelFeedback.tick(dir: d)
            case .select:
                if deleteSelection == 0, let name = deleteCandidate {
                    model.notes.delete(name)
                    withAnimation(.easeOut(duration: 0.18)) { deleteCandidate = nil }
                    if selection >= listItems.count { selection = max(0, listItems.count - 1) }
                } else {
                    withAnimation(.easeOut(duration: 0.18)) { deleteCandidate = nil }
                }
            case .menu:
                withAnimation(.easeOut(duration: 0.18)) { deleteCandidate = nil }
            default:
                break
            }
            return
        }
        switch event {
        case .tick(let d):
            moveListSelection(&selection, count: listItems.count, delta: d, settings: settings)
        case .select:
            let item = listItems[min(selection, listItems.count - 1)]
            if item.id == "__new__" {
                let name = model.notes.create()
                model.push(.noteEditor(name))
            } else {
                model.push(.noteEditor(item.id))
            }
        case .centerHold:
            let item = listItems[min(selection, listItems.count - 1)]
            if item.id != "__new__" {
                holdItem = item.id
                holdSelection = 0
            }
        case .menu:
            model.pop()
        default:
            break
        }
    }

    @State private var holdItem: String?
    @State private var holdSelection = 0
    @State private var shareText: String?

    private var holdPanel: some View {
        ModalPanel(title: "Note Options", onClose: { holdItem = nil }) {
            VStack(spacing: 0) {
                MenuRow(item: MenuItem(id: "h.share", title: "Share", showsChevron: false), selected: holdSelection == 0)
                    .frame(height: 30.5)
                    .onTapGesture {
                        if let name = holdItem {
                            shareText = "\(name)\n\n\(model.notes.read(name))"
                        }
                        holdItem = nil
                    }
                MenuRow(item: MenuItem(id: "h.delete", title: "Delete", showsChevron: false), selected: holdSelection == 1)
                    .frame(height: 30.5)
                    .onTapGesture {
                        deleteCandidate = holdItem
                        deleteSelection = 1
                        holdItem = nil
                    }
                MenuRow(item: MenuItem(id: "h.cancel", title: "Cancel", showsChevron: false), selected: holdSelection == 2)
                    .frame(height: 30.5)
                    .onTapGesture {
                        holdItem = nil
                    }
            }
            .padding(.top, 2)
        }
    }
}

/// Plain text editor over one note; touch typing with keyboard, autosave.
/// The wheel scrolls the note; Done (below) or center dismisses the keyboard.
struct NoteEditorScreen: View {
    @Environment(AppModel.self) private var model
    let fileName: String

    @State private var text = ""
    @State private var loaded = false
    @State private var textView: UITextView?
    @State private var keyboardVisible = false
    @State private var lastScrollY: CGFloat = 0

    private let scrollStep: CGFloat = 26

    private var qaEnabled: Bool {
        fileName == QASeed.qaNoteName
            && ProcessInfo.processInfo.environment["NOTES_QA"] == "1"
    }

    var body: some View {
        TextEditor(text: $text)
            .font(Theme.font(14))
            .foregroundStyle(Theme.ink)
            .scrollContentBackground(.hidden)
            .background(PaperBackground())
            .padding(.horizontal, 4)
            .onAppear {
                // Grey scroll indicator — the default renders white on
                // the paper background.
                UITextView.appearance().indicatorStyle = .black
            }
            // Dark keyboard; explicit ink color keeps the text black.
            .environment(\.colorScheme, .dark)
            .onWheel { handle($0) }
            .background(
                // Anchor that hands us the TextEditor's backing UITextView
                // so the wheel can scroll it and Done can drop the keyboard.
                TextViewProbe { textView = $0 }
            )
            .overlay(alignment: .bottom) {
                if keyboardVisible {
                    doneButton
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .overlay(alignment: .bottomLeading) {
                // QA readout (NOTES_QA=1): the backing text view's scroll
                // offset, so UI tests can assert the wheel really scrolls.
                if qaEnabled {
                    Text("y=\(Int(lastScrollY))")
                        .font(Theme.font(9, .bold))
                        .foregroundStyle(Theme.inkDim)
                        .monospacedDigit()
                        .padding(4)
                }
            }
            .onChange(of: text) { _, newValue in
                if loaded {
                    model.notes.saveDebounced(fileName, newValue)
                }
            }
            .onAppear {
                text = model.notes.read(fileName)
                // QA hook (NOTES_QA=1): fill the QA note with scrollable
                // numbered text for wheel-scroll tests and screenshots.
                if text.isEmpty, qaEnabled {
                    text = (1...60).map { "Line \($0): the click wheel scrolls this note." }
                        .joined(separator: "\n")
                }
                loaded = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.keyboardWillShowNotification)) { _ in
                withAnimation(.easeOut(duration: 0.18)) { keyboardVisible = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.keyboardWillHideNotification)) { _ in
                withAnimation(.easeIn(duration: 0.18)) { keyboardVisible = false }
            }
            .onDisappear {
                model.notes.write(fileName, text)
                model.notes.loadNotes()
            }
            .sheet(isPresented: Binding(get: { shareText != nil }, set: { if !$0 { shareText = nil } })) {
                if let text = shareText {
                    ActivityView(items: [text])
                }
            }
    }

    private var doneButton: some View {
        Button {
            textView?.resignFirstResponder()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.down")
                Text("Done")
            }
            .font(Theme.font(12.5, .bold))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color(white: 0.85)))
            .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 8)
    }

    private func handle(_ event: ControlEvent) {
        // Typing happens by touch; the wheel scrolls, center/Done dismiss
        // the keyboard, MENU steps out of the editor.
        switch event {
        case .tick(let d):
            WheelFeedback.tick(dir: d)
            scrollBy(d > 0 ? scrollStep : -scrollStep)
        case .select:
            if keyboardVisible {
                textView?.resignFirstResponder()
            }
        case .menu:
            model.notes.write(fileName, text)
            model.pop()
        case .menuHold:
            model.notes.write(fileName, text)
            model.popToRoot()
        case .centerHold:
            // Hold center: share the note as plain text.
            WheelHaptics.shared.ensureRunning()
            WheelHaptics.shared.buttonPress(strength: 0.9)
            shareText = "\(fileName)\n\n\(text)"
        default:
            break
        }
    }

    /// Scroll the backing text view by `delta` points, clamped to the
    /// document (adjusted insets cover the keyboard's automatic inset).
    private func scrollBy(_ delta: CGFloat) {
        guard let tv = textView else { return }
        let target = clampedScrollOffset(
            current: tv.contentOffset.y,
            delta: delta,
            contentHeight: tv.contentSize.height,
            viewportHeight: tv.bounds.height,
            topInset: tv.adjustedContentInset.top,
            bottomInset: tv.adjustedContentInset.bottom
        )
        tv.setContentOffset(CGPoint(x: 0, y: target), animated: false)
        lastScrollY = target
    }

    @State private var shareText: String?
}

/// Wheel-scroll target for the notes editor: `current + delta` clamped to
/// the document range. A short document (content shorter than the viewport)
/// never moves. (Unit-tested: NotesScrollTests.)
func clampedScrollOffset(current: CGFloat, delta: CGFloat, contentHeight: CGFloat,
                         viewportHeight: CGFloat, topInset: CGFloat, bottomInset: CGFloat) -> CGFloat {
    let lowest = -topInset
    let highest = max(lowest, contentHeight - viewportHeight + bottomInset)
    return min(max(current + delta, lowest), highest)
}

/// Invisible anchor that locates the TextEditor's backing UITextView: it
/// walks up from its own layer to the first ancestor that owns one — the
/// editor's text view, since no other TextEditor exists in the app.
private struct TextViewProbe: UIViewRepresentable {
    let onFound: (UITextView) -> Void

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.isUserInteractionEnabled = false
        DispatchQueue.main.async {
            var parent = v.superview
            while let p = parent {
                if let tv = p.firstSubview(ofType: UITextView.self) {
                    onFound(tv)
                    return
                }
                parent = p.superview
            }
        }
        return v
    }

    func updateUIView(_ v: UIView, context: Context) {}
}
