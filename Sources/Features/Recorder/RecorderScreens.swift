import SwiftUI
import AVFoundation
import UIKit

/// Voice Memos main screen: record state, elapsed timer, and the control rows
/// (Record/Pause/Stop, All Recordings). Recording keeps running in background.
struct RecorderScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings
    /// Highlighted row index; the wheel moves it, center activates it.
    /// Mutating this @State is what re-renders the row list.
    /// Concept: SwiftUI views & state → docs/concepts/swiftui-views-and-state.md
    @State private var selection = 0

    /// Shortcut to the app-wide recorder model.
    private var recorder: RecorderModel { model.recorder }

    /// Menu rows adapt to recorder state: idle → Record, recording → Pause,
    /// paused → Resume (Stop & Save and All Recordings are always present).
    /// Idle also lists Recently Deleted (with its count).
    private var rows: [MenuItem] {
        if recorder.isRecording {
            let mid = recorder.isPaused ? "Resume" : "Pause"
            return [
                MenuItem(id: mid, title: mid, showsChevron: false),
                MenuItem(id: "stop", title: "Stop & Save", showsChevron: false),
                MenuItem(id: "all", title: "All Recordings", showsChevron: false),
            ]
        }
        var rows = [
            MenuItem(id: "record", title: "Record", showsChevron: false),
            MenuItem(id: "all", title: "All Recordings", showsChevron: false),
        ]
        let trashed = recorder.trash.count
        rows.append(MenuItem(id: "trash", title: "Recently Deleted",
                             detail: trashed > 0 ? "\(trashed)" : nil, showsChevron: false))
        return rows
    }

    /// Recording status readout above the state-dependent control rows.
    var body: some View {
        VStack(spacing: 4) {
            statusArea
                .padding(.top, 10)
            controls
            Spacer(minLength: 0)
        }
        .onWheel { handle($0) }
        .onAppear {
            recorder.loadRecordings()
            recorder.loadTrash()
            recorder.observeInterruptions()
        }
    }

    /// Red/amber recording dot + label, the monospaced elapsed clock, and
    /// the paused-in-background hint (mic icon when idle).
    private var statusArea: some View {
        VStack(spacing: 6) {
            if recorder.isRecording {
                HStack(spacing: 6) {
                    Circle()
                        .fill(recorder.isPaused ? Color(red: 0.95, green: 0.75, blue: 0.1) : Color.red)
                        .frame(width: 10, height: 10)
                    Text(recorder.isPaused ? "PAUSED" : "RECORDING")
                        .font(Theme.font(11, .bold))
                        .tracking(1)
                        .foregroundStyle(Theme.inkDim)
                }
            } else {
                Image(systemName: "mic.fill")
                    .font(Theme.font(22))
                    .foregroundStyle(Theme.inkDim)
            }
            Text(TimeFormat.hms(recorder.elapsed))
                .font(.system(size: 30, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(recorder.isRecording ? Theme.ink : Theme.inkDim)
            if recorder.isPaused {
                Text("Recording continues in the background")
                    .font(Theme.font(10.5, .medium))
                    .foregroundStyle(Theme.inkDim)
            }
        }
    }

    /// The record-control MenuList; `selection` is shared with `handle(_:)`.
    private var controls: some View {
        MenuList(
            items: rows,
            selection: selection
        )
        .padding(.horizontal, 24)
        .padding(.top, 8)
    }

    /// Wheel/button router: ticks move the row selection, center activates
    /// it, and MENU pauses an in-progress recording before popping back.
    private func handle(_ event: ControlEvent) {
        switch event {
        case .tick(let d):
            moveListSelection(&selection, count: rows.count, delta: d, settings: settings)
        case .select:
            activateCurrent()
        case .menu:
            if recorder.isRecording { recorder.pause() }
            model.pop()
        default:
            break
        }
    }

    /// Runs the highlighted row's action (Record / Pause / Resume /
    /// Stop & Save / All Recordings / Recently Deleted).
    private func activateCurrent() {
        let row = rows[min(selection, rows.count - 1)]
        switch row.id {
        case "record":
            recorder.start()
            selection = 0
        case "Pause":
            recorder.pause()
        case "Resume":
            recorder.resume()
        case "stop":
            recorder.stop()
            selection = 0
        case "all":
            model.push(.recordings)
        case "trash":
            model.push(.recordingsTrash)
        default:
            break
        }
    }
}

/// All recordings list.
struct RecordingsListScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings
    @State private var selection = 0
    /// Recording awaiting the delete-confirm panel.
    @State private var deleteCandidate: RecordingFile?
    /// Delete-panel row: 0 = Delete, 1 = Cancel (hold-menu entry preselects
    /// Cancel so a stray center-press can't destroy a memo).
    @State private var deleteSelection = 0
    /// Recording queued to transcribe once the model finishes downloading.
    @State private var pendingTranscribe: RecordingFile?
    /// Whether the speech-model download panel is showing.
    @State private var downloadOpen = false

    /// Shortcut to the shared transcription manager.
    private var transcription: TranscriptionManager { TranscriptionManager.shared }

    /// Transcript state marker shown next to the duration.
    private func detail(for file: RecordingFile) -> String {
        let duration = TimeFormat.duration(file.duration)
        if transcription.transcribing.contains(file.id) { return "\(duration) · transcribing…" }
        guard let entry = TranscriptStore.entry(for: file.id) else { return duration }
        switch entry.state {
        case "done": return "\(duration) ✓"
        case "failed": return "\(duration) · failed"
        default: return "\(duration) · partial"
        }
    }

    /// The recordings MenuList with modal panels layered above it (delete
    /// confirm, hold options, model download).
    var body: some View {
        ZStack {
            MenuList(
                items: model.recorder.recordings.map { file in
                    MenuItem(id: file.id, title: file.name, detail: detail(for: file))
                },
                selection: selection, emptyText: "No Recordings"
            )
            if deleteCandidate != nil {
                ModalHost { deletePanel }
                    .zIndex(2)
            }
            if holdItem != nil {
                ModalHost { holdPanel }
                    .zIndex(3)
            }
            if downloadOpen {
                ModalHost { downloadPanel }
                    .zIndex(4)
            }
        }
        .onWheel { handle($0) }
        .onAppear {
            RecorderModel.seedQAIfRequested()
            model.recorder.loadRecordings()
            // A transcription finished while another screen was on top.
            if !transcription.transcribing.isEmpty { model.recorder.loadRecordings() }
        }
        .onChange(of: transcription.downloadState) { old, new in
            // Download finished — continue with the queued recording.
            if case .ready = new, old != .ready, let file = pendingTranscribe {
                downloadOpen = false
                pendingTranscribe = nil
                transcription.transcribe(file: file.id, sourceURL: file.url)
            }
        }
        .sheet(isPresented: Binding(get: { shareItem != nil }, set: { if !$0 { shareItem = nil } })) {
            if let url = shareItem {
                ActivityView(items: [url])
            }
        }
        .sheet(isPresented: Binding(get: { shareText != nil }, set: { if !$0 { shareText = nil } })) {
            if let text = shareText {
                ActivityView(items: [text])
            }
        }
    }

    /// Two-row Delete/Cancel confirm; wheel ticks toggle between the rows
    /// and the rows also take taps (touch parity with the other panels).
    private var deletePanel: some View {
        ModalPanel(title: "Delete Recording", onClose: { deleteCandidate = nil }) {
            VStack(spacing: 0) {
                MenuRow(item: MenuItem(id: "del.yes", title: "Delete", showsChevron: false), selected: deleteSelection == 0)
                    .frame(height: 30.5)
                    .onTapGesture { confirmDelete() }
                MenuRow(item: MenuItem(id: "del.no", title: "Cancel", showsChevron: false), selected: deleteSelection == 1)
                    .frame(height: 30.5)
                    .onTapGesture { deleteCandidate = nil }
            }
            .padding(.top, 2)
        }
    }

    /// Confirms the open delete panel: trashes the candidate and clamps
    /// the list selection. Shared by the wheel's center press and the
    /// panel row's tap.
    private func confirmDelete() {
        if let file = deleteCandidate {
            model.recorder.trash(file)
            if selection >= model.recorder.recordings.count { selection = max(0, model.recorder.recordings.count - 1) }
        }
        deleteCandidate = nil
    }

    /// Input router for the list and its panels. Open panels take
    /// precedence (download → hold → delete → the list itself); within a
    /// panel, ticks move its selection, center confirms, MENU dismisses.
    private func handle(_ event: ControlEvent) {
        if downloadOpen {
            switch event {
            case .select, .playPause:
                switch transcription.downloadState {
                case .ready:
                    downloadOpen = false
                    if let file = pendingTranscribe {
                        transcription.transcribe(file: file.id, sourceURL: file.url)
                        pendingTranscribe = nil
                    }
                case .failed, .notStarted:
                    Task { try? await transcription.ensureModels() }
                default:
                    break
                }
            case .menu, .menuHold:
                downloadOpen = false
                pendingTranscribe = nil
            default:
                break
            }
            return
        }
        if holdItem != nil {
            let rows = holdRows
            switch event {
            case .tick(let d):
                holdSelection = min(rows.count - 1, max(0, holdSelection + (d > 0 ? 1 : -1)))
                WheelFeedback.tick(dir: d)
            case .select:
                if rows.indices.contains(holdSelection) {
                    holdAction(rows[holdSelection])
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
                _ = d
                deleteSelection = deleteSelection == 0 ? 1 : 0
                WheelFeedback.tick(dir: d)
            case .select:
                if deleteSelection == 0 {
                    confirmDelete()
                } else {
                    deleteCandidate = nil
                }
            case .menu:
                deleteCandidate = nil
            default:
                break
            }
            return
        }
        switch event {
        case .tick(let d):
            moveListSelection(&selection, count: model.recorder.recordings.count, delta: d, settings: settings)
        case .select:
            if model.recorder.recordings.indices.contains(selection) {
                model.push(.recordingDetail(model.recorder.recordings[selection].id))
            }
        case .centerHold:
            if model.recorder.recordings.indices.contains(selection) {
                holdItem = model.recorder.recordings[selection]
                holdSelection = 0
            }
        case .menu:
            model.pop()
        default:
            break
        }
    }

    /// Recording whose options (hold) panel is open.
    @State private var holdItem: RecordingFile?
    /// Highlighted row in the options panel.
    @State private var holdSelection = 0
    /// Audio file queued for the share sheet (non-nil presents it).
    @State private var shareItem: URL?
    /// Transcript text queued for the share sheet (non-nil presents it).
    @State private var shareText: String?

    /// Hold-menu rows depend on the recording's transcript state:
    /// transcription / view / retry / share text, then share audio /
    /// delete / cancel.
    private var holdRows: [String] {
        guard let file = holdItem else { return [] }
        var rows: [String] = []
        let entry = TranscriptStore.entry(for: file.id)
        if transcription.transcribing.contains(file.id) {
            rows.append("Cancel Transcribing")
        } else if transcription.downloadState != .ready {
            rows.append("Transcribe")
        } else if entry == nil || entry?.state == "failed" {
            rows.append(entry?.state == "failed" ? "Retry Transcription" : "Transcribe")
        }
        if let entry, entry.text.isEmpty == false {
            rows.append("View Transcript")
            rows.append("Share Text")
        }
        rows.append("Share")
        rows.append("Delete")
        rows.append("Cancel")
        return rows
    }

    /// Runs one options-panel row: transcribe/retry/cancel, view or share
    /// the transcript, share the audio, or delete (via the confirm panel).
    /// - Parameter row: the selected row title.
    private func holdAction(_ row: String) {
        guard let file = holdItem else { return }
        switch row {
        case "Transcribe", "Retry Transcription":
            holdItem = nil
            beginTranscription(file)
        case "Cancel Transcribing":
            transcription.cancel(file: file.id)
            holdItem = nil
        case "View Transcript":
            holdItem = nil
            model.push(.transcript(file.id))
        case "Share Text":
            shareTranscript(file)
            holdItem = nil
        case "Share":
            shareItem = file.url
            holdItem = nil
        case "Delete":
            deleteCandidate = file
            deleteSelection = 1
            holdItem = nil
        default:
            holdItem = nil
        }
    }

    /// Starts transcription, running the one-time model download first if
    /// needed (the panel tracks progress and auto-continues when ready).
    private func beginTranscription(_ file: RecordingFile) {
        if transcription.downloadState == .ready, transcription.transcribing.isEmpty {
            transcription.transcribe(file: file.id, sourceURL: file.url)
        } else {
            pendingTranscribe = file
            downloadOpen = true
            Task { try? await transcription.ensureModels() }
        }
    }

    /// Shares the transcript as CLEAN TEXT — the paragraph-formatted string
    /// goes straight into the share sheet, not a .txt file.
    /// - Parameter file: the recording whose transcript is shared.
    private func shareTranscript(_ file: RecordingFile) {
        guard let entry = TranscriptStore.entry(for: file.id), !entry.text.isEmpty else { return }
        shareText = TranscriptStore.formatParagraphs(entry.text)
    }

    /// Recording Options panel; rows come from `holdRows`, and taps mirror
    /// the wheel selection for touch users.
    private var holdPanel: some View {
        ModalPanel(title: "Recording Options", onClose: { holdItem = nil }) {
            VStack(spacing: 0) {
                ForEach(Array(holdRows.enumerated()), id: \.element) { idx, row in
                    MenuRow(item: MenuItem(id: "h.\(row)", title: row, showsChevron: false),
                            selected: holdSelection == idx)
                        .frame(height: 30.5)
                        .onTapGesture {
                            holdSelection = idx
                            holdAction(row)
                        }
                }
            }
            .padding(.top, 2)
        }
    }

    /// One-time Parakeet v3 model download (~600 MB), shown while it runs.
    private var downloadPanel: some View {
        ModalPanel(title: "Speech Model", onClose: {
            downloadOpen = false
            pendingTranscribe = nil
        }) {
            VStack(spacing: 0) {
                switch transcription.downloadState {
                case .ready:
                    MenuRow(item: MenuItem(id: "dl.go", title: "Model Ready", showsChevron: false), selected: true)
                        .frame(height: 30.5)
                case .downloading:
                    MenuRow(item: MenuItem(id: "dl.p", title: "Downloading…",
                                           detail: "~600 MB, one time", showsChevron: false), selected: true)
                        .frame(height: 30.5)
                case .failed(let message):
                    MenuRow(item: MenuItem(id: "dl.retry", title: "Retry Download",
                                           detail: message, showsChevron: false), selected: true)
                        .frame(height: 30.5)
                case .notStarted:
                    MenuRow(item: MenuItem(id: "dl.start", title: "Download (~600 MB)",
                                           detail: "one time", showsChevron: false), selected: true)
                        .frame(height: 30.5)
                }
                MenuRow(item: MenuItem(id: "dl.cancel", title: "Cancel", showsChevron: false), selected: false)
                    .frame(height: 30.5)
                    .onTapGesture {
                        downloadOpen = false
                        pendingTranscribe = nil
                    }
            }
            .padding(.top, 2)
        }
    }
}

/// One recording: playback with seek, share, delete.
struct RecordingDetailScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings
    /// Identifies the memo (its file name); set when the route is pushed.
    let fileName: String

    /// Highlighted row index in the action list.
    @State private var selection = 0
    /// Audio file queued for the share sheet (non-nil presents it).
    @State private var shareItem: URL?

    /// Looks the memo's metadata up fresh each render, so deletions and
    /// list reloads elsewhere are reflected here immediately.
    private var file: RecordingFile? {
        model.recorder.recordings.first { $0.id == fileName }
    }

    /// Shortcut to the shared transcription manager.
    private var transcription: TranscriptionManager { TranscriptionManager.shared }

    /// Action rows; the transcript row adapts to state: Transcribing… while
    /// a run is active, View Transcript once text exists, else Transcribe.
    private var rows: [String] {
        var rows = ["Play / Pause", "Rewind 15s"]
        if transcription.transcribing.contains(fileName) {
            rows.append("Transcribing…")
        } else if let entry = TranscriptStore.entry(for: fileName), entry.text.isEmpty == false {
            rows.append("View Transcript")
        } else {
            rows.append("Transcribe")
        }
        rows.append("Share")
        rows.append("Delete")
        return rows
    }

    /// Playback header above the action rows, with the download toast overlay.
    var body: some View {
        VStack(spacing: 4) {
            playbackHeader
                .padding(.top, 10)
            rowsList
                .padding(.horizontal, 18)
                .padding(.top, 6)
            Spacer(minLength: 0)
        }
        .overlay(showToast ? toastView : nil)
        .onWheel { handle($0) }
        .onAppear {
            // Recents: the last recording opened.
            model.recents.record(recording: .init(id: fileName, title: TranscriptStore.displayTitle(for: fileName)))
        }
        .sheet(item: Binding(
            get: { shareItem.map { ShareTarget(url: $0) } },
            set: { shareItem = $0?.url }
        )) { target in
            ActivityView(items: [target.url])
        }
    }

    /// Identifiable URL wrapper — `.sheet(item:)` only presents
    /// Identifiable values, and a plain URL isn't one.
    private struct ShareTarget: Identifiable {
        /// The URL to share.
        let url: URL
        /// Sheet identity (the URL string itself).
        var id: String { url.absoluteString }
    }

    /// Memo title (minus the "Recording " prefix), monospaced playhead,
    /// and total duration.
    private var playbackHeader: some View {
        VStack(spacing: 5) {
            Text(file?.name.replacingOccurrences(of: "Recording ", with: "") ?? "Recording")
                .font(Theme.font(13, .bold))
                .lineLimit(1)
                .padding(.horizontal, 8)
            Text(TimeFormat.hms(model.recorder.playTime))
                .font(.system(size: 26, weight: .semibold, design: .monospaced))
                .monospacedDigit()
            Text("of \(TimeFormat.duration(file?.duration ?? 0))")
                .font(Theme.font(11, .medium))
                .foregroundStyle(Theme.inkDim)
        }
    }

    /// The action MenuList bound to `selection`.
    private var rowsList: some View {
        MenuList(
            items: rows.map { MenuItem(id: $0, title: $0, showsChevron: false) },
            selection: selection
        )
    }

    /// Wheel/button router: ticks move the selection, center activates, and
    /// MENU stops playback before popping so audio never leaks past the screen.
    private func handle(_ event: ControlEvent) {
        switch event {
        case .tick(let d):
            moveListSelection(&selection, count: rows.count, delta: d, settings: settings)
        case .select:
            activateCurrent()
        case .menu:
            model.recorder.stopPlayback()
            model.pop()
        default:
            break
        }
    }

    /// Center-press dispatch. The transcript row reuses one path: view the
    /// transcript if text exists, transcribe if the engine is ready, else
    /// show the toast and kick off the model download.
    private func activateCurrent() {
        guard let file else { return }
        switch rows[min(selection, rows.count - 1)] {
        case "Play / Pause":
            model.recorder.playPauseCurrent(file)
        case "Rewind 15s":
            model.recorder.seekCurrent(-15)
        case "Transcribing…":
            break
        case "Transcribe", "View Transcript":
            if let entry = TranscriptStore.entry(for: file.id), entry.text.isEmpty == false,
               !transcription.transcribing.contains(fileName) {
                model.push(.transcript(file.id))
            } else if transcription.downloadState == .ready, transcription.transcribing.isEmpty {
                transcription.transcribe(file: file.id, sourceURL: file.url)
            } else {
                showToast = true
                Task { try? await transcription.ensureModels() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { showToast = false }
            }
        case "Share":
            shareItem = file.url
        case "Delete":
            model.recorder.trash(file)
            model.pop()
        default:
            break
        }
    }

    /// Brief "downloading speech model…" note on the detail screen.
    @State private var showToast = false
    /// Non-interactive capsule note; `allowsHitTesting(false)` lets wheel
    /// and touch input pass through while it shows.
    private var toastView: some View {
        VStack {
            Spacer()
            Text("Downloading speech model…")
                .font(Theme.font(11, .bold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.black.opacity(0.75)))
                .foregroundStyle(Color.white)
                .padding(.bottom, 24)
        }
        .allowsHitTesting(false)
    }
}

/// UIActivityViewController wrapper for sharing recording files.
struct ActivityView: UIViewControllerRepresentable {
    /// Files, URLs, or text strings to hand to the system share sheet.
    let items: [Any]

    /// Creates the share sheet once, seeded with the fixed `items`.
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    /// Required update callback, intentionally empty: `items` are fixed at
    /// creation, so SwiftUI re-renders have nothing to push into the VC.
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// A recording's transcript: read-only text the wheel scrolls, Share
/// exports it as clean .txt. MENU pops back.
struct TranscriptScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings
    /// The recording whose transcript this screen shows.
    let fileName: String

    /// Cached backing UITextView the wheel scrolls; SwiftUI may recreate
    /// the view (keyboard/background transitions), detaching the cached one.
    @State private var textView: UITextView?
    /// Anchor planted behind the screen by `TextViewProbe`; the view tree
    /// is walked from here to re-find a recreated text view.
    @State private var probeAnchor: UIView?
    /// Transcript text queued for the share sheet (non-nil presents it).
    @State private var shareText: String?
    /// Whether the Transcript Options hold panel is open.
    @State private var holdOpen = false
    /// Highlighted row in the options panel (0 = Share).
    @State private var holdSelection = 0

    /// This memo's persisted transcript, read fresh from the sidecar each
    /// render so progress appears live.
    private var entry: TranscriptEntry? { TranscriptStore.entry(for: fileName) }

    /// Formatted for reading: sentences grouped into paragraphs. Re-applied
    /// at display so transcripts stored before formatting show it too.
    private var formattedText: String {
        TranscriptStore.formatParagraphs(entry?.text ?? "")
    }

    /// Read-only formatted transcript (or the Transcribing…/failed
    /// placeholder) with the options panel overlay.
    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                if let entry, entry.text.isEmpty == false {
                    TextEditor(text: .constant(formattedText))
                        .font(Theme.font(12))
                        .scrollContentBackground(.hidden)
                        .background(PaperBackground())
                        .disabled(true)
                } else {
                    Spacer()
                    Text(entry?.state == "failed" ? "Transcription failed" : "Transcribing…")
                        .font(Theme.font(13, .medium))
                        .foregroundStyle(Theme.inkDim)
                    Spacer()
                }
            }
            if holdOpen {
                ModalHost { holdPanel }
                    .zIndex(2)
            }
        }
        .onWheel { handle($0) }
        .background(
            TextViewProbe { probeAnchor = $0 }
        )
        .sheet(isPresented: Binding(get: { shareText != nil }, set: { if !$0 { shareText = nil } })) {
            if let text = shareText {
                ActivityView(items: [text])
            }
        }
    }

    /// Transcript Options: Share / Cancel (Share preselected, like the
    /// list hold menus).
    private var holdPanel: some View {
        ModalPanel(title: "Transcript Options", onClose: { closeHold() }) {
            MenuList(items: [
                MenuItem(id: "share", title: "Share", showsChevron: false),
                MenuItem(id: "cancel", title: "Cancel", showsChevron: false),
            ], selection: holdSelection, compact: true)
                .padding(.top, 2)
        }
    }

    /// Dismisses the options panel with the standard quick fade.
    private func closeHold() {
        withAnimation(.easeIn(duration: 0.15)) { holdOpen = false }
    }

    /// Clean-text export: the plain transcript, shared as text.
    private func shareAsText() {
        guard let entry else { return }
        shareText = TranscriptStore.formatParagraphs(entry.text)
    }

    /// Wheel scrolls the backing text view, clamped to the document.
    private func handle(_ event: ControlEvent) {
        switch event {
        case .tick(let d):
            if holdOpen {
                moveListSelection(&holdSelection, count: 2, delta: d, settings: settings)
                WheelFeedback.tick(dir: d)
            } else {
                guard let tv = resolveTextView() else { return }
                let step: CGFloat = d > 0 ? 42 : -42
                let bottom = max(0, tv.contentSize.height - tv.bounds.height + tv.adjustedContentInset.bottom)
                let target = min(max(tv.contentOffset.y + step, -tv.adjustedContentInset.top), bottom)
                tv.setContentOffset(CGPoint(x: tv.contentOffset.x, y: target), animated: false)
            }
        case .select:
            if holdOpen {
                switch holdSelection {
                case 0:
                    closeHold()
                    shareAsText()
                default:
                    closeHold()
                }
            }
        case .centerHold:
            guard entry?.text.isEmpty == false else { break }
            WheelHaptics.shared.ensureRunning()
            WheelHaptics.shared.buttonPress(strength: 0.85)
            holdSelection = 0 // Share preselected, like the list hold menus
            withAnimation(.easeOut(duration: 0.18)) { holdOpen = true }
        case .menu:
            if holdOpen {
                closeHold()
            } else {
                model.pop()
            }
        default:
            break
        }
    }

    /// The backing UITextView, re-resolved if SwiftUI recreated it.
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
}

/// Deleted recordings: restore to the recordings list, or remove for
/// good. Center restores the selected memo (transcript comes back with
/// it — sidecar entries survive trashing); hold center offers Delete
/// Forever. Duration detail carries the transcript marker so it's clear
/// what a restore will bring back.
struct RecordingsTrashScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings
    /// Highlighted row index; the wheel moves it, center restores.
    @State private var selection = 0
    /// Trashed recording whose Delete Forever panel is open; nil = closed.
    @State private var holdItem: RecordingFile?
    /// Panel row: 0 = Delete Forever, 1 = Cancel.
    @State private var holdSelection = 0

    /// Shortcut to the shared transcription manager (transcript markers).
    private var transcription: TranscriptionManager { TranscriptionManager.shared }

    /// The trashed-recordings list, with the Delete Forever panel layered
    /// over it while active.
    var body: some View {
        ZStack {
            MenuList(
                items: trashItems,
                selection: selection,
                emptyText: "Trash Empty"
            )
            if holdItem != nil {
                ModalHost { panel }
                    .zIndex(2)
            }
        }
        .onWheel { handle($0) }
        .onAppear {
            RecorderModel.seedQAIfRequested()
            model.recorder.loadTrash()
        }
    }

    /// Duration + transcript marker per trashed memo — the same marker
    /// vocabulary as the recordings list (✓ done, · partial, · failed).
    private func detail(for file: RecordingFile) -> String {
        let duration = TimeFormat.duration(file.duration)
        guard let entry = TranscriptStore.entry(for: file.id) else { return duration }
        switch entry.state {
        case "done": return "\(duration) ✓"
        case "failed": return "\(duration) · failed"
        default: return "\(duration) · partial"
        }
    }

    /// Rows for trashed memos — no action rows; center restores directly.
    private var trashItems: [MenuItem] {
        model.recorder.trash.map { file in
            MenuItem(id: file.id, title: file.name, detail: detail(for: file), showsChevron: false)
        }
    }

    /// Delete Forever / Cancel panel for the held memo.
    private var panel: some View {
        ModalPanel(title: "Trashed Recording", onClose: { holdItem = nil }) {
            VStack(spacing: 0) {
                MenuRow(item: MenuItem(id: "t.forever", title: "Delete Forever", showsChevron: false), selected: holdSelection == 0)
                    .frame(height: 30.5)
                    .onTapGesture {
                        if let file = holdItem {
                            model.recorder.deleteForever(file)
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

    /// Wheel/button routing: center restores the selected memo, hold
    /// center opens Delete Forever. The empty-trash guards are
    /// load-bearing — this screen stays up after the last memo is
    /// restored, and subscripting an empty array would trap. While the
    /// panel is open, any tick simply toggles between its two rows.
    private func handle(_ event: ControlEvent) {
        if holdItem != nil {
            switch event {
            case .tick(let d):
                holdSelection = holdSelection == 0 ? 1 : 0
                WheelFeedback.tick(dir: d)
            case .select:
                if holdSelection == 0, let file = holdItem {
                    model.recorder.deleteForever(file)
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
            moveListSelection(&selection, count: model.recorder.trash.count, delta: d, settings: settings)
        case .select:
            if model.recorder.trash.indices.contains(selection) {
                model.recorder.restore(model.recorder.trash[selection])
                if selection >= model.recorder.trash.count { selection = max(0, model.recorder.trash.count - 1) }
            }
        case .centerHold:
            if model.recorder.trash.indices.contains(selection) {
                WheelHaptics.shared.ensureRunning()
                WheelHaptics.shared.buttonPress(strength: 0.85)
                holdItem = model.recorder.trash[selection]
                holdSelection = 0
            }
        case .menu:
            model.pop()
        default:
            break
        }
    }
}

