import SwiftUI

/// Notes list: New Note row plus existing notes; hold center for options
/// (Share / Delete — delete goes to the Trash, recoverable from the
/// Trash row at the bottom).
struct NotesListScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings
    @State private var selection = 0
    /// Current toast message; an empty string means no toast is showing.
    @State private var toast = ""

    /// The menu list, with toast and hold-panel layered over it while
    /// either is active.
    ///
    /// Concept: SwiftUI body → docs/concepts/swiftui-views-and-state.md
    var body: some View {
        ZStack {
            MenuList(
                items: listItems,
                selection: selection,
                emptyText: "No Notes",
                style: .twoLine
            )
            if !toast.isEmpty {
                ToastCapsule(text: toast)
                    .zIndex(2)
            }
            if holdItem != nil {
                ModalHost { holdPanel }
                    .zIndex(3)
            }
        }
        .onWheel { handle($0) }
        .onAppear {
            model.notes.loadNotes()
            model.notes.loadTrash()
        }
        .sheet(isPresented: Binding(get: { shareText != nil }, set: { if !$0 { shareText = nil } })) {
            if let text = shareText {
                ActivityView(items: [text])
            }
        }
    }

    /// Rows shown in the menu list: a fixed "New Note" row, one row per
    /// note (preview subtitle, friendly date), and — only while the
    /// trash holds something — a "Trash" row with a count. The sentinel
    /// ids "__new__"/"__trash__" mark the action rows apart from note
    /// filenames, which are themselves row ids.
    private var listItems: [MenuItem] {
        var items = [MenuItem(id: "__new__", title: "New Note", symbol: "plus.square", showsChevron: false)]
        items.append(contentsOf: model.notes.notes.map { note in
            MenuItem(id: note.id, title: note.name, subtitle: note.preview.isEmpty ? nil : note.preview, detail: TimeFormat.friendly(note.date), showsChevron: true)
        })
        if !model.notes.trash.isEmpty {
            items.append(MenuItem(id: "__trash__", title: "Trash", detail: "\(model.notes.trash.count)", symbol: "trash", showsChevron: false))
        }
        return items
    }

    /// Wheel/button routing for the notes list.
    ///
    /// Two modes. While the hold panel is open, ticks move its three-row
    /// selection and center runs the highlighted action; MENU closes it.
    /// Otherwise: ticks move the list selection, center activates the
    /// selected row (create + open the editor, open the Trash, or open
    /// the note), hold-center opens Note Options for real notes, and
    /// MENU pops the screen. Panel deletes skip a confirm step — they
    /// land in the recoverable Trash, and the toast says so.
    private func handle(_ event: ControlEvent) {
        if holdItem != nil {
            switch event {
            case .tick(let d):
                holdSelection = min(2, max(0, holdSelection + (d > 0 ? 1 : -1)))
                WheelFeedback.tick(dir: d)
            case .select:
                switch holdSelection {
                case 0: shareText = "\(holdItem ?? "")\n\n\(model.notes.read(holdItem ?? ""))"; holdItem = nil
                case 1:
                    // Straight to the trash — recoverable, so no extra
                    // confirm level here.
                    if let name = holdItem {
                        model.notes.trash(name)
                        if selection >= listItems.count { selection = max(0, listItems.count - 1) }
                        showToast("Moved to Trash")
                    }
                    holdItem = nil
                default: holdItem = nil
                }
            case .menu, .menuHold:
                holdItem = nil
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
            } else if item.id == "__trash__" {
                model.push(.noteTrash)
            } else {
                model.push(.noteEditor(item.id))
            }
        case .centerHold:
            let item = listItems[min(selection, listItems.count - 1)]
            if item.id != "__new__" && item.id != "__trash__" {
                holdItem = item.id
                holdSelection = 0
            }
        case .menu:
            model.pop()
        default:
            break
        }
    }

    /// Shows `text` in a toast capsule, fading back out ~1.4 s later.
    private func showToast(_ text: String) {
        withAnimation(.easeOut(duration: 0.2)) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation(.easeIn(duration: 0.3)) { toast = "" }
        }
    }

    /// Filename of the note whose Note Options panel is open; nil = closed.
    @State private var holdItem: String?
    /// Selected row (0–2) inside the open hold panel.
    @State private var holdSelection = 0
    /// When non-nil, the share sheet presents this text (note name + body).
    @State private var shareText: String?

    /// Note Options panel: Share / Delete / Cancel. Wheel selection and
    /// touch taps drive the same rows, so the panel works both ways.
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
                        if let name = holdItem {
                            model.notes.trash(name)
                            if selection >= listItems.count { selection = max(0, listItems.count - 1) }
                            showToast("Moved to Trash")
                        }
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
    @EnvironmentObject private var settings: AppSettings
    /// The note this editor edits: filename without extension.
    let fileName: String

    /// The note's text, bound to the TextEditor; changes after the
    /// initial load trigger the debounced save.
    ///
    /// Concept: @State → docs/concepts/swift-property-wrappers.md
    @State private var text = ""
    /// Set once the onAppear load has populated `text`; the autosave
    /// `onChange` ignores changes until then, so the initial load (and
    /// QA seeding) can't be mistaken for user edits.
    @State private var loaded = false
    /// Cached backing UITextView of the SwiftUI TextEditor. SwiftUI may
    /// recreate that view (keyboard/background transitions), leaving
    /// this reference detached — always go through `resolveTextView()`,
    /// which re-validates it.
    @State private var textView: UITextView?
    /// View planted inside the editor's hierarchy by `TextViewProbe`;
    /// the re-walk root when the cached text view has gone stale.
    @State private var probeAnchor: UIView?
    /// Whether the keyboard is up. Set from UIKit's will-show/will-hide
    /// notifications and cleared directly when a hold panel takes over
    /// the screen; gates the Done capsule and center-tap dismiss.
    ///
    /// Concept: NotificationCenter publisher → docs/concepts/combine.md
    @State private var keyboardVisible = false
    /// Last wheel-driven scroll offset; only the NOTES_QA readout shows
    /// it, letting UI tests assert the wheel really scrolled.
    @State private var lastScrollY: CGFloat = 0
    /// Hold-center options panel (font size / share).
    @State private var optionsOpen = false
    /// Selected row (0–2) in the Note Options panel.
    @State private var optionsSelection = 0
    /// Live font-size adjust mode inside the panel: the wheel edits the
    /// size with an instant preview; center saves, MENU cancels.
    @State private var sizingMode = false
    /// The wheel-edited size while sizing mode is on (clamped 11–24),
    /// previewed live in the editor.
    @State private var sizingDraft = 14
    /// Size captured when sizing mode opened; MENU (cancel) restores it.
    @State private var sizingBefore = 14

    /// Points the note scrolls per wheel tick (roughly one text line).
    private let scrollStep: CGFloat = 26

    /// True only for the QA note under NOTES_QA=1 — gates the seeded
    /// 60-line text and the y= readout that UI tests assert against.
    private var qaEnabled: Bool {
        fileName == QASeed.qaNoteName
            && ProcessInfo.processInfo.environment["NOTES_QA"] == "1"
    }

    /// The text editor on the paper LCD background, with the
    /// keyboard-gated Done capsule, QA readout, options panel and share
    /// sheet layered on top.
    var body: some View {
        TextEditor(text: $text)
            .font(Theme.font(CGFloat(sizingMode ? sizingDraft : settings.noteFontSize)))
            .foregroundStyle(Theme.ink)
            .scrollContentBackground(.hidden)
            .background(PaperBackground())
            // Comfortable text margins, matching the reader's content
            // padding instead of hugging the LCD edges.
            .padding(.leading, 12)
            .padding(.trailing, 12)
            .padding(.top, 6)
            .onAppear {
                // Grey scroll indicator — the default renders white on
                // the paper background.
                UITextView.appearance().indicatorStyle = .black
            }
            // Dark keyboard; explicit ink color keeps the text black.
            .environment(\.colorScheme, .dark)
            .onWheel { handle($0) }
            .background(
                // Anchor into the TextEditor's backing hierarchy so the
                // wheel can scroll it and Done can drop the keyboard.
                TextViewProbe { probeAnchor = $0 }
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
            .overlay {
                if optionsOpen {
                    ModalHost { editorOptionsPanel }
                        .zIndex(2)
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
                // QA hook (NOTES_PANEL=1): open the note options panel
                // (screenshots of the hold menu).
                if ProcessInfo.processInfo.environment["NOTES_PANEL"] == "1" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        optionsSelection = 0
                        withAnimation(.easeOut(duration: 0.18)) { optionsOpen = true }
                    }
                }
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

    /// Bottom capsule shown while the keyboard is up; tapping it ends
    /// editing, same as pressing center on the wheel.
    private var doneButton: some View {
        Button {
            resolveTextView()?.resignFirstResponder()
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

    /// Wheel/button routing for the editor, innermost mode first:
    ///
    /// - Font Size adjust: the wheel nudges the size live (11–24),
    ///   center commits it to `settings.noteFontSize` (persisted in
    ///   UserDefaults as notes.fontSize), MENU reverts to the captured
    ///   pre-adjust value.
    /// - Note Options panel: the wheel picks Font Size / Share / Cancel,
    ///   center activates the row, MENU closes.
    /// - Plain editor: the wheel scrolls the text (`scrollBy`), center
    ///   or Done drops the keyboard, MENU writes and pops (menuHold
    ///   pops to root), hold-center dismisses the keyboard and opens
    ///   the options panel.
    ///
    /// The wheel never edits text — typing is touch-only, keeping the
    /// click wheel a navigation control like a real iPod.
    ///
    /// Concept: UserDefaults → docs/concepts/userdefaults.md
    private func handle(_ event: ControlEvent) {
        // Typing happens by touch; the wheel scrolls, center/Done dismiss
        // the keyboard, MENU steps out of the editor. Hold center opens
        // the note options panel (font size / share).
        switch event {
        case .tick(let d):
            WheelFeedback.tick(dir: d)
            if sizingMode {
                sizingDraft = min(24, max(11, sizingDraft + (d > 0 ? 1 : -1)))
            } else if optionsOpen {
                moveListSelection(&optionsSelection, count: 3, delta: d, settings: settings)
            } else {
                scrollBy(d > 0 ? scrollStep : -scrollStep)
            }
        case .select:
            if sizingMode {
                settings.noteFontSize = sizingDraft
                closeOptions()
            } else if optionsOpen {
                switch optionsSelection {
                case 0:
                    sizingMode = true
                    sizingBefore = settings.noteFontSize
                    sizingDraft = settings.noteFontSize
                case 1:
                    shareText = "\(fileName)\n\n\(text)"
                    closeOptions()
                default:
                    closeOptions()
                }
            } else if keyboardVisible {
                resolveTextView()?.resignFirstResponder()
            }
        case .menu:
            if sizingMode {
                sizingDraft = sizingBefore
                closeOptions()
            } else if optionsOpen {
                closeOptions()
            } else {
                model.notes.write(fileName, text)
                model.pop()
            }
        case .menuHold:
            if sizingMode {
                sizingDraft = sizingBefore
                closeOptions()
            } else if optionsOpen {
                closeOptions()
            } else {
                model.notes.write(fileName, text)
                model.popToRoot()
            }
        case .centerHold:
            // Hold center: note options (was share-only).
            guard !optionsOpen else { break }
            WheelHaptics.shared.ensureRunning()
            WheelHaptics.shared.buttonPress(strength: 0.9)
            keyboardVisible = false
            resolveTextView()?.resignFirstResponder()
            optionsSelection = 0
            withAnimation(.easeOut(duration: 0.18)) { optionsOpen = true }
        default:
            break
        }
    }

    /// Exits sizing mode and closes the panel — the single exit path so
    /// every close (center, MENU, the X) also leaves Font Size adjusting.
    private func closeOptions() {
        sizingMode = false
        withAnimation(.easeOut(duration: 0.18)) { optionsOpen = false }
    }

    /// The hold-center panel, retitled "Font Size — Wheel to Adjust"
    /// while sizing mode is live; the Font Size row's detail tracks the
    /// draft value, so the panel itself doubles as the size preview.
    private var editorOptionsPanel: some View {
        ModalPanel(title: sizingMode ? "Font Size — Wheel to Adjust" : "Note Options",
                   onClose: {
                       if sizingMode { sizingDraft = sizingBefore }
                       closeOptions()
                   }) {
            VStack(spacing: 0) {
                MenuRow(item: MenuItem(id: "o.size", title: "Font Size",
                                       detail: "\(sizingMode ? sizingDraft : settings.noteFontSize)",
                                       showsChevron: false),
                        selected: optionsSelection == 0)
                    .frame(height: 30.5)
                MenuRow(item: MenuItem(id: "o.share", title: "Share", showsChevron: false),
                        selected: optionsSelection == 1)
                    .frame(height: 30.5)
                MenuRow(item: MenuItem(id: "o.cancel", title: "Cancel", showsChevron: false),
                        selected: optionsSelection == 2)
                    .frame(height: 30.5)
            }
            .padding(.top, 2)
        }
    }

    /// The editor's live backing text view. The probe captures it once,
    /// but SwiftUI can RECREATE the UITextView (keyboard transitions,
    /// backgrounding) leaving the captured reference detached — wheel
    /// scrolls then die silently. Re-walk from the anchor whenever the
    /// cached view is no longer in a window.
    private func resolveTextView() -> UITextView? {
        if let tv = textView, tv.window != nil { return tv }
        guard let anchor = probeAnchor else { return nil }
        var parent = anchor.superview
        while let p = parent {
            if let tv = p.firstSubview(ofType: UITextView.self) {
                textView = tv
                return tv
            }
            parent = p.superview
        }
        return nil
    }

    /// Scroll the backing text view by `delta` points, clamped to the
    /// document (adjusted insets cover the keyboard's automatic inset).
    private func scrollBy(_ delta: CGFloat) {
        guard let tv = resolveTextView() else { return }
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

    /// When non-nil, the share sheet presents this text (name + body).
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

/// Invisible anchor into the TextEditor's backing hierarchy: a screen can
/// re-walk from it to find the CURRENT backing UITextView whenever the
/// cached one detaches (SwiftUI can recreate the text view on keyboard
/// transitions or backgrounding, which silently kills wheel scrolling).
/// Shared by the notes editor and the transcript screen.
struct TextViewProbe: UIViewRepresentable {
    /// Called one run-loop tick after the anchor view is mounted, with
    /// the view to keep as a re-walk root.
    ///
    /// Concept: closure → docs/concepts/swift-closures.md
    let onAnchor: (UIView) -> Void

    /// Creates a plain, non-interactive view so the probe never steals
    /// touches from the text editor it sits inside.
    ///
    /// The callback is deferred via DispatchQueue.main.async because
    /// makeUIView runs before SwiftUI has mounted the returned view into
    /// the hierarchy — by the next tick the view has a superview, which
    /// `resolveTextView()`'s upward walk depends on.
    ///
    /// Concept: UIViewRepresentable lifecycle → docs/concepts/uiviewrepresentable.md
    /// Concept: DispatchQueue.main.async → docs/concepts/dispatch-queues.md
    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.isUserInteractionEnabled = false
        DispatchQueue.main.async {
            onAnchor(v)
        }
        return v
    }

    /// No-op: the probe is a one-shot anchor, not a live two-way bridge,
    /// so there is no SwiftUI state to push into the UIView.
    func updateUIView(_ v: UIView, context: Context) {}
}

/// Deleted notes: restore to the notes list, or remove for good.
/// Center restores the selected note; hold center offers Delete Forever.
struct NoteTrashScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings
    @State private var selection = 0
    /// Trashed note (filename) whose Delete Forever panel is open; nil = closed.
    @State private var holdItem: String?
    /// Panel row: 0 = Delete Forever, 1 = Cancel.
    @State private var holdSelection = 0

    /// The trashed-notes list, with the Delete Forever panel layered
    /// over it while active.
    var body: some View {
        ZStack {
            MenuList(
                items: trashItems,
                selection: selection,
                emptyText: "Trash Empty",
                style: .twoLine
            )
            if holdItem != nil {
                ModalHost { panel }
                    .zIndex(2)
            }
        }
        .onWheel { handle($0) }
        .onAppear { model.notes.loadTrash() }
    }

    /// Rows for trashed notes — same shape as the notes list, but with
    /// no action rows; center restores directly.
    private var trashItems: [MenuItem] {
        model.notes.trash.map { note in
            MenuItem(id: note.id, title: note.name, subtitle: note.preview.isEmpty ? nil : note.preview, detail: TimeFormat.friendly(note.date), showsChevron: false)
        }
    }

    /// Delete Forever / Cancel panel for the held note.
    private var panel: some View {
        ModalPanel(title: "Trashed Note", onClose: { holdItem = nil }) {
            VStack(spacing: 0) {
                MenuRow(item: MenuItem(id: "t.forever", title: "Delete Forever", showsChevron: false), selected: holdSelection == 0)
                    .frame(height: 30.5)
                    .onTapGesture {
                        if let name = holdItem {
                            model.notes.deleteForever(name)
                            if selection >= trashItems.count { selection = max(0, trashItems.count - 1) }
                        }
                        holdItem = nil
                    }
                MenuRow(item: MenuItem(id: "t.cancel", title: "Cancel", showsChevron: false), selected: holdSelection == 1)
                    .frame(height: 30.5)
                    .onTapGesture { holdItem = nil }
            }
            .padding(.top, 2)
        }
    }

    /// Wheel/button routing: center restores the selected note (with a
    /// light confirm haptic), hold-center opens Delete Forever. The
    /// empty-trash guards are load-bearing — this screen stays up after
    /// the last note is restored, and subscripting an empty array would
    /// trap. While the panel is open, any tick simply toggles between
    /// its two rows.
    private func handle(_ event: ControlEvent) {
        if holdItem != nil {
            switch event {
            case .tick(let d):
                holdSelection = holdSelection == 0 ? 1 : 0
                WheelFeedback.tick(dir: d)
            case .select:
                if holdSelection == 0, let name = holdItem {
                    model.notes.deleteForever(name)
                    if selection >= trashItems.count { selection = max(0, trashItems.count - 1) }
                }
                holdItem = nil
            case .menu, .menuHold:
                holdItem = nil
            default:
                break
            }
            return
        }
        switch event {
        case .tick(let d):
            moveListSelection(&selection, count: trashItems.count, delta: d, settings: settings)
        case .select:
            // Empty trash: nothing to restore. (The subscript must stay
            // behind this guard — trashItems[0] on an empty array traps,
            // and this screen stays up after the last item is restored.)
            guard !trashItems.isEmpty else { break }
            let item = trashItems[min(selection, trashItems.count - 1)]
            model.notes.restore(item.id)
            WheelHaptics.shared.ensureRunning()
            WheelHaptics.shared.buttonPress(strength: 0.7)
            if selection >= trashItems.count { selection = max(0, trashItems.count - 1) }
        case .centerHold:
            guard !trashItems.isEmpty else { break }
            let item = trashItems[min(selection, trashItems.count - 1)]
            holdItem = item.id
            holdSelection = 0
        case .menu:
            model.pop()
        default:
            break
        }
    }
}
