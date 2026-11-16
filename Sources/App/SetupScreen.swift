import SwiftUI
import AVFoundation
import MusicKit
import Photos
import UserNotifications

/// One-time first-run wizard: collects the app's permissions, offers the
/// on-device model downloads (transcription ~600 MB, Read Aloud voice
/// ~3 GB), and applies the factory preferences. Shown automatically on
/// first launch (and again any time via Settings → Run Setup Again);
/// RESET_DEFAULTS skips it, SHOW_SETUP=1 forces it (QA screenshots /
/// UI tests).
struct SetupScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings

    private enum Step { case welcome, permissions, voiceModel, readingVoice, preferences, done }
    @State private var step: Step = .welcome
    @State private var modelChoice = 0 // 0 = download now, 1 = not now
    @State private var ttsChoice = 0   // reading voice: 0 = download now, 1 = not now
    @State private var ttsDownloadStarted = false

    // nil = not asked yet
    @State private var music: Bool?
    @State private var photos: Bool?
    @State private var camera: Bool?
    @State private var mic: Bool?
    @State private var notifications: Bool?
    @State private var requesting = false
    @State private var downloadStarted = false

    private let transcription = TranscriptionManager.shared

    var body: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 8)
            switch step {
            case .welcome: welcomePage
            case .permissions: permissionsPage
            case .voiceModel: voiceModelPage
            case .readingVoice: readingVoicePage
            case .preferences: preferencesPage
            case .done: donePage
            }
            Spacer()
            footer
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 8)
        .onWheel { handle($0) }
        .task {
            // QA hook: jump straight to a setup page (screenshots).
            if let page = ProcessInfo.processInfo.environment["SETUP_PAGE"] {
                switch page {
                case "voiceModel": step = .voiceModel
                case "readingVoice": step = .readingVoice
                default: break
                }
            }
        }
    }

    // MARK: Pages

    private var welcomePage: some View {
        VStack(spacing: 14) {
            Image(systemName: "music.note")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.ink)
            Text("Welcome")
                .font(Theme.font(22, .semibold))
                .foregroundStyle(Theme.ink)
            Text("A few things to set up before\nyou start.")
                .font(Theme.font(13, .regular))
                .foregroundStyle(Theme.inkDim)
                .multilineTextAlignment(.center)
        }
    }

    private func permissionRow(_ name: String, _ granted: Bool?) -> some View {
        HStack {
            Text(name).font(Theme.font(15, .medium)).foregroundStyle(Theme.ink)
            Spacer()
            Text(statusGlyph(granted))
                .font(Theme.font(15, .semibold))
                .foregroundStyle(granted == true ? Theme.ink : Theme.inkDim)
        }
        .padding(.vertical, 5)
    }

    private var permissionsPage: some View {
        VStack(spacing: 6) {
            Text("Permissions")
                .font(Theme.font(17, .semibold))
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            permissionRow("Music Library", music)
            permissionRow("Photos", photos)
            permissionRow("Camera", camera)
            permissionRow("Microphone", mic)
            permissionRow("Notifications", notifications)
            Text(requesting ? "Asking…" : "Center: allow all · MENU: later")
                .font(Theme.font(11, .regular))
                .foregroundStyle(Theme.inkDim)
        }
    }

    private var voiceModelPage: some View {
        VStack(spacing: 10) {
            Text("Voice Model")
                .font(Theme.font(17, .semibold))
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            if TranscriptionManager.hasCachedModels() {
                statusLine("Transcription model ready ✓")
                Text("Center: continue")
                    .font(Theme.font(11, .regular))
                    .foregroundStyle(Theme.inkDim)
            } else if downloadStarted {
                statusLine(modelStatusText ?? "Downloading…")
                Text("Downloads in the background · Center: continue")
                    .font(Theme.font(11, .regular))
                    .foregroundStyle(Theme.inkDim)
            } else {
                choiceRow("Download Now (~600 MB)", selected: modelChoice == 0)
                choiceRow("Not Now", selected: modelChoice == 1)
                Text("For transcribing voice memos · Wheel: choose · Center: select")
                    .font(Theme.font(11, .regular))
                    .foregroundStyle(Theme.inkDim)
            }
        }
    }

    /// Read Aloud voice (selected engine, default Qwen3 ~700 MB): same
    /// shape as the transcription-model page. Downloads run in the
    /// background — the wizard can continue and the reader starts it on
    /// first use if skipped. Breeze (~3 GB, experimental) is opt-in from
    /// Settings → Read Aloud — setup never downloads both.
    private var readingVoicePage: some View {
        VStack(spacing: 10) {
            Text("Reading Voice")
                .font(Theme.font(17, .semibold))
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            if ReadAloudVoiceStore.hasCachedModel(ReadAloudVoiceStore.shared.engine) {
                statusLine("Read Aloud voice ready ✓")
                Text("Center: continue")
                    .font(Theme.font(11, .regular))
                    .foregroundStyle(Theme.inkDim)
            } else if ttsDownloadStarted {
                statusLine(ttsStatusText ?? "Downloading…")
                Text("Downloads in the background · Center: continue")
                    .font(Theme.font(11, .regular))
                    .foregroundStyle(Theme.inkDim)
            } else {
                choiceRow(ReadAloudVoiceStore.shared.engine.downloadLabel, selected: ttsChoice == 0)
                choiceRow("Not Now", selected: ttsChoice == 1)
                Text("For Read Aloud in the Reader · Wheel: choose · Center: select")
                    .font(Theme.font(11, .regular))
                    .foregroundStyle(Theme.inkDim)
            }
        }
    }

    private var ttsStatusText: String? {
        switch ReadAloudVoiceStore.shared.state {
        case .notStarted: return nil
        case .downloading(let progress):
            return progress.map { String(format: "Downloading… %d%%", Int($0 * 100)) } ?? "Downloading…"
        case .loading: return "Loading voice model…"
        case .ready: return "Read Aloud voice ready ✓"
        case .failed(let message): return "Failed: \(message)"
        }
    }

    private var preferencesPage: some View {
        VStack(spacing: 6) {
            Text("Preferences Set")
                .font(Theme.font(17, .semibold))
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            statusLine("Font Size: Small")
            statusLine("Haptics: Heavy")
            statusLine("Tick Sounds: Off")
            statusLine("Scanlines: Medium")
            Text("Change any of these later in Settings · Center: done")
                .font(Theme.font(11, .regular))
                .foregroundStyle(Theme.inkDim)
        }
        .task {
            // The requested factory defaults — applied on this screen so
            // an existing install also picks them up.
            settings.fontScale = 0
            settings.hapticsEnabled = true
            settings.scrollingHaptics = 3 // strong
            settings.buttonHaptics = 2 // heavy
            settings.tickSounds = false
            settings.scanlineIntensity = 2
        }
    }

    private var donePage: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.ink)
            Text("All Set!")
                .font(Theme.font(22, .semibold))
                .foregroundStyle(Theme.ink)
            Text("Center: start")
                .font(Theme.font(12, .regular))
                .foregroundStyle(Theme.inkDim)
        }
    }

    private var footer: some View {
        Text("Setup · \(stepName)")
            .font(Theme.font(10, .medium))
            .foregroundStyle(Theme.inkDim)
    }

    private var stepName: String {
        switch step {
        case .welcome: return "Welcome"
        case .permissions: return "Permissions"
        case .voiceModel: return "Voice Model"
        case .readingVoice: return "Reading Voice"
        case .preferences: return "Preferences"
        case .done: return "Done"
        }
    }

    // MARK: Rows

    private func choiceRow(_ text: String, selected: Bool) -> some View {
        Text(text)
            .font(Theme.font(15, .semibold))
            .foregroundStyle(selected ? Color.white : Theme.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 4).fill(selected ? AnyShapeStyle(SelectionGradient()) : AnyShapeStyle(Color.clear)))
    }

    private func statusLine(_ text: String) -> some View {
        Text(text)
            .font(Theme.font(15, .medium))
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
    }

    private func statusGlyph(_ granted: Bool?) -> String {
        switch granted {
        case .some(true): return "✓"
        case .some(false): return "✗"
        case nil: return "—"
        }
    }

    private var modelStatusText: String? {
        switch transcription.downloadState {
        case .notStarted: return nil
        case .downloading(_, let progress):
            return progress.map { "Downloading… \(Int($0 * 100))%" } ?? "Downloading…"
        case .ready: return "Voice model ready ✓"
        case .failed(let message): return "Failed: \(message)"
        }
    }

    // MARK: Input

    private func handle(_ event: ControlEvent) {
        switch step {
        case .welcome:
            if case .select = event { advance() }
        case .permissions:
            switch event {
            case .select:
                if requesting { break }
                if allAsked { advance() } else {
                    WheelHaptics.shared.ensureRunning()
                    WheelHaptics.shared.buttonPress(strength: 0.8)
                    Task { await requestAll() }
                }
            case .menu:
                advance() // skip — permissions can be granted later in-app
            default:
                break
            }
        case .voiceModel:
            switch event {
            case .tick(let d):
                if !downloadStarted, !TranscriptionManager.hasCachedModels() {
                    moveListSelection(&modelChoice, count: 2, delta: d, settings: settings)
                    WheelFeedback.tick(dir: d)
                }
            case .select:
                if downloadStarted || TranscriptionManager.hasCachedModels() {
                    advance()
                } else if modelChoice == 0 {
                    downloadStarted = true
                    Task { try? await transcription.ensureModels() }
                } else {
                    advance() // not now
                }
            case .menu:
                advance()
            default:
                break
            }
        case .readingVoice:
            switch event {
            case .tick(let d):
                if !ttsDownloadStarted, !ReadAloudVoiceStore.hasCachedModel(ReadAloudVoiceStore.shared.engine) {
                    moveListSelection(&ttsChoice, count: 2, delta: d, settings: settings)
                    WheelFeedback.tick(dir: d)
                }
            case .select:
                if ttsDownloadStarted || ReadAloudVoiceStore.hasCachedModel(ReadAloudVoiceStore.shared.engine) {
                    advance()
                } else if ttsChoice == 0 {
                    ttsDownloadStarted = true
                    Task { try? await ReadAloudVoiceStore.shared.prepare() }
                } else {
                    advance() // not now
                }
            case .menu:
                advance()
            default:
                break
            }
        case .preferences:
            if case .select = event { advance() }
            if case .menu = event { advance() }
        case .done:
            if case .select = event { model.completeSetup() }
        }
    }

    private var allAsked: Bool {
        music != nil && photos != nil && camera != nil && mic != nil && notifications != nil
    }

    private func advance() {
        switch step {
        case .welcome: step = .permissions
        case .permissions: step = .voiceModel
        case .voiceModel: step = .readingVoice
        case .readingVoice: step = .preferences
        case .preferences: step = .done
        case .done: model.completeSetup()
        }
    }

    // MARK: Permission requests

    private func requestAll() async {
        requesting = true
        music = await requestMusic()
        photos = await requestPhotos()
        camera = await requestCamera()
        mic = await requestMic()
        notifications = await requestNotifications()
        requesting = false
    }

    private func requestMusic() async -> Bool {
        if MusicAuthorization.currentStatus == .authorized { return true }
        let status = await MusicAuthorization.request()
        return status == .authorized
    }

    private func requestPhotos() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .authorized || status == .limited { return true }
        let new = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return new == .authorized || new == .limited
    }

    private func requestCamera() async -> Bool {
        if AVCaptureDevice.authorizationStatus(for: .video) == .authorized { return true }
        return await AVCaptureDevice.requestAccess(for: .video)
    }

    private func requestMic() async -> Bool {
        if AVAudioApplication.shared.recordPermission == .granted { return true }
        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func requestNotifications() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let current = await center.notificationSettings()
        switch current.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        default: break
        }
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }
}
