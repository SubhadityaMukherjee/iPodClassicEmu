import SwiftUI
import AVFoundation
import UIKit

/// Voice Memos main screen: record state, elapsed timer, and the control rows
/// (Record/Pause/Stop, All Recordings). Recording keeps running in background.
struct RecorderScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings
    @State private var selection = 0

    private var recorder: RecorderModel { model.recorder }

    private var rows: [String] {
        if recorder.isRecording {
            return recorder.isPaused ? ["Resume", "Stop & Save", "All Recordings"] : ["Pause", "Stop & Save", "All Recordings"]
        }
        return ["Record", "All Recordings"]
    }

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
            recorder.observeInterruptions()
        }
    }

    private var statusArea: some View {
        VStack(spacing: 6) {
            if recorder.isRecording {
                HStack(spacing: 6) {
                    Circle()
                        .fill(recorder.isPaused ? Color(red: 0.95, green: 0.75, blue: 0.1) : Color.red)
                        .frame(width: 10, height: 10)
                    Text(recorder.isPaused ? "PAUSED" : "RECORDING")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1)
                        .foregroundStyle(Theme.inkDim)
                }
            } else {
                Image(systemName: "mic.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.inkDim)
            }
            Text(TimeFormat.hms(recorder.elapsed))
                .font(.system(size: 30, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(recorder.isRecording ? Theme.ink : Theme.inkDim)
            if recorder.isPaused {
                Text("Recording continues in the background")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.inkDim)
            }
        }
    }

    private var controls: some View {
        MenuList(
            items: rows.map { MenuItem(id: $0, title: $0, showsChevron: false) },
            selection: selection
        )
        .padding(.horizontal, 24)
        .padding(.top, 8)
    }

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

    private func activateCurrent() {
        let row = rows[min(selection, rows.count - 1)]
        switch row {
        case "Record":
            recorder.start()
            selection = 0
        case "Pause":
            recorder.pause()
        case "Resume":
            recorder.resume()
        case "Stop & Save":
            recorder.stop()
            selection = 0
        case "All Recordings":
            model.push(.recordings)
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
    @State private var deleteCandidate: RecordingFile?
    @State private var deleteSelection = 0

    var body: some View {
        ZStack {
            MenuList(
                items: model.recorder.recordings.map { file in
                    MenuItem(id: file.id, title: file.name, detail: TimeFormat.duration(file.duration))
                },
                selection: selection, emptyText: "No Recordings"
            )
            if deleteCandidate != nil {
                ModalHost { deletePanel }
                    .zIndex(2)
            }
        }
        .onWheel { handle($0) }
        .onAppear { model.recorder.loadRecordings() }
    }

    private var deletePanel: some View {
        ModalPanel(title: "Delete Recording", onClose: { deleteCandidate = nil }) {
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
        if deleteCandidate != nil {
            switch event {
            case .tick(let d):
                _ = d
                deleteSelection = deleteSelection == 0 ? 1 : 0
                WheelFeedback.tick(dir: d)
            case .select:
                if deleteSelection == 0, let file = deleteCandidate {
                    model.recorder.delete(file)
                    deleteCandidate = nil
                    if selection >= model.recorder.recordings.count { selection = max(0, model.recorder.recordings.count - 1) }
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
                deleteCandidate = model.recorder.recordings[selection]
                deleteSelection = 1
            }
        case .menu:
            model.pop()
        default:
            break
        }
    }
}

/// One recording: playback with seek, share, delete.
struct RecordingDetailScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings
    let fileName: String

    @State private var selection = 0
    @State private var shareItem: URL?

    private var file: RecordingFile? {
        model.recorder.recordings.first { $0.id == fileName }
    }

    private var rows: [String] {
        ["Play / Pause", "Rewind 15s", "Share", "Delete"]
    }

    var body: some View {
        VStack(spacing: 4) {
            playbackHeader
                .padding(.top, 10)
            rowsList
                .padding(.horizontal, 18)
                .padding(.top, 6)
            Spacer(minLength: 0)
        }
        .onWheel { handle($0) }
        .sheet(item: Binding(
            get: { shareItem.map { ShareTarget(url: $0) } },
            set: { shareItem = $0?.url }
        )) { target in
            ActivityView(items: [target.url])
        }
    }

    private struct ShareTarget: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    private var playbackHeader: some View {
        VStack(spacing: 5) {
            Text(file?.name.replacingOccurrences(of: "Recording ", with: "") ?? "Recording")
                .font(.system(size: 13, weight: .bold))
                .lineLimit(1)
                .padding(.horizontal, 8)
            Text(TimeFormat.hms(model.recorder.playTime))
                .font(.system(size: 26, weight: .semibold, design: .monospaced))
                .monospacedDigit()
            Text("of \(TimeFormat.duration(file?.duration ?? 0))")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.inkDim)
        }
    }

    private var rowsList: some View {
        MenuList(
            items: rows.map { MenuItem(id: $0, title: $0, showsChevron: false) },
            selection: selection
        )
    }

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

    private func activateCurrent() {
        guard let file else { return }
        switch rows[min(selection, rows.count - 1)] {
        case "Play / Pause":
            model.recorder.playPauseCurrent(file)
        case "Rewind 15s":
            model.recorder.seekCurrent(-15)
        case "Share":
            shareItem = file.url
        case "Delete":
            model.recorder.delete(file)
            model.pop()
        default:
            break
        }
    }
}

/// UIActivityViewController wrapper for sharing recording files.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
