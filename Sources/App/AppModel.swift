import Foundation
import SwiftUI
import Combine
import os

/// Unified-log tap (os category "wheel") for input and scheduling
/// diagnostics — a single stream that can be filtered in Console or
/// `log stream` while debugging.
enum WheelEventLog {
    /// The shared logger everything here writes through.
    static let logger = Logger(subsystem: "com.ipodclassic.app", category: "wheel")
    /// Logs one diagnostic line as a public notice (not privacy-redacted).
    static func log(_ message: String) { logger.notice("\(message, privacy: .public)") }
}

/// A single click-wheel input. The wheel view produces these; the active
/// screen on the navigation stack consumes them.
enum ControlEvent: Equatable {
    /// One detent of scroll. `+1` = clockwise (down/next), `-1` = counter-clockwise.
    case tick(Int)
    /// Center button tap.
    case select
    /// Long-press on center button.
    case centerHold
    /// MENU tap.
    case menu
    /// Long-press on MENU (go home).
    case menuHold
    /// Previous-track press.
    case prev
    /// Next-track press.
    case next
    /// Repeats every ~0.16s while prev/next is held.
    case prevHold
    case nextHold
    /// Released after a hold.
    case holdEnded
    /// Play/pause press.
    case playPause
    /// Long-press on play/pause (sleep the device).
    case playHold
}

/// Navigation routes. The stack is rendered bottom-up inside the LCD screen;
/// only the top route receives wheel input.
enum Route: Hashable {
    case home

    // Music
    case music
    case musicArtists
    case musicAlbums
    case musicSongs
    case musicGenres
    case musicPlaylists
    case musicRecent
    case coverFlow
    case artistDetail(String)
    case artistSearch(String)
    case albumDetail(String)
    case playlistDetail(String)
    case genreAlbums(String)
    case nowPlaying
    case readerBooks
    case readerArticles

    // Photos
    case photos
    case photoDetail(Int)

    // Camera
    case camera

    // Voice Memos
    case recorder
    case recordings
    case recordingsTrash
    case recordingsDictionary
    case recordingDetail(String)
    case transcript(String)

    // Notes
    case notes
    case noteEditor(String)
    case noteTrash

    // Clocks
    case clocks
    case timer
    case stopwatch

    // Extras
    case extras
    case flashlight
    case reader
    case readerBook(String)

    // Search
    case musicSearch

    // Calendar
    case calendar

    // Binaural
    case binaural

    // Settings
    case settings
    case settingsClickwheel
    case settingsDisplay
    case settingsPlayback
    case settingsReadAloud
    case settingsAbout

    // First-run
    case tour
    case setup
}

/// Root object of the app: owns the navigation stack, routes all
/// click-wheel input, and holds one model per feature. Injected with
/// `.environment(model)` and read in views via `@Environment(AppModel.self)`.
///
/// @Observable (macro-based tracking) rather than ObservableObject:
/// invalidation is per-property, so writing `clockTick` re-renders only
/// the views that actually read it. @MainActor because everything here
/// is UI state touched on the main thread.
///
/// Concept: swiftui-views-and-state → docs/concepts/swiftui-views-and-state.md
/// Concept: swift-actors-and-isolation → docs/concepts/swift-actors-and-isolation.md
@Observable
@MainActor
final class AppModel {
    /// Navigation stack of screens rendered inside the LCD; the last
    /// element is the visible screen. Starts at `.home`.
    var stack: [Route] = [.home]

    /// Hold switch on the device body locks all wheel input.
    var holdActive = false
    /// Screen asleep (hold play/pause). Any wheel press wakes it.
    var screenAsleep = false
    /// Set when the timer fires while the app is open.
    var ringer: RingerContext?
    /// Screens like the camera claim prev/next/play for their own purposes;
    /// when set, media buttons go to the screen instead of the music player.
    var transportClaimedByScreen = false

    /// Apple Music library fetch and cache (MusicKit).
    let music = MusicService()
    /// Music playback: transport, queue bookkeeping, volume (ApplicationMusicPlayer).
    let player = PlayerModel()
    /// Photo library grid and thumbnails (PhotoKit).
    let photos = PhotoLibraryModel()
    /// Camera capture session (AVCaptureSession driven on a serial queue).
    let camera = CameraModel()
    /// Voice-memo recording and playback (.m4a files in Documents/Recordings).
    let recorder = RecorderModel()
    /// Text notes store (.txt files in Documents/Notes).
    let notes = NotesStore()
    /// Book/article registry; referenced via its own singleton because the
    /// reader UI and the article intents must share one library.
    let reader = ReaderStore.shared
    /// Countdown timer.
    let timer = TimerModel()
    /// Stopwatch with laps.
    let stopwatch = StopwatchModel()
    /// Last-touched-item memory feeding the home Recents rows.
    let recents = RecentActivity.shared
    /// Binaural-beat synthesizer (Extras).
    let binaural = BinauralModel()
    /// User preferences (UserDefaults-backed; injected as an environment object).
    let settings = AppSettings.shared
    /// Read Aloud: on-device neural TTS for books.
    let audiobook = AudiobookModel()

    /// Every wheel event not handled globally is broadcast here, and only
    /// the top screen subscribes (via `.onReceive`) — that subscription
    /// rule is what makes "the top route owns wheel input" work. Combine
    /// fits because the consumer changes as screens push and pop, and
    /// onReceive subscribes/unsubscribes automatically with the view.
    ///
    /// Concept: combine → docs/concepts/combine.md
    let controlBus = PassthroughSubject<ControlEvent, Never>()
    /// Events while the timer ringer is up go here instead, so the
    /// underlying screen can't react to them.
    let ringerBus = PassthroughSubject<ControlEvent, Never>()

    /// Creates the model and decides the launch state, in order: QA hooks
    /// (READER_IMPORT, QA_DICT, QA_TRANSCRIBE, QA_TTS, START_ROUTE,
    /// ALARM_ENABLE), first-run routing (tour → setup → home;
    /// RESET_DEFAULTS skips the one-time screens), then either AUTOPLAY's
    /// shuffle play or the paused restore of the last playback session.
    init() {
        // QA hook: QA_DICT=<comma-separated words> preloads the custom
        // dictionary so QA_TRANSCRIBE exercises the boosting pass without
        // keyboard entry on the device.
        if let words = ProcessInfo.processInfo.environment["QA_DICT"] {
            for word in words.split(separator: ",").map({ String($0).trimmingCharacters(in: .whitespaces) })
            where !word.isEmpty {
                TranscriptionManager.shared.addDictionaryTerm(word)
            }
        }
        // QA hook: READER_IMPORT imports a book from Documents before the
        // first frame (simulator checks against real EPUBs).
        if let name = ProcessInfo.processInfo.environment["READER_IMPORT"] {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            _ = try? reader.addBook(from: docs.appendingPathComponent(name))
        }

        // QA hook: QA_TRANSCRIBE downloads the Parakeet model if needed and
        // transcribes a recording from Documents/Recordings end-to-end.
        if let name = ProcessInfo.processInfo.environment["QA_TRANSCRIBE"] {
            Task { @MainActor in
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let statusURL = docs.appendingPathComponent("qa_status.txt")
                /// Appends one stage line to Documents/qa_status.txt so device QA
                /// runs can report progress even when the debugger isn't attached.
                func setStatus(_ s: String) {
                    try? s.write(to: statusURL, atomically: true, encoding: .utf8)
                }
                let mgr = TranscriptionManager.shared
                do {
                    setStatus("loading-models")
                    try await mgr.ensureModels()
                    setStatus("models-ready")
                    let url = docs.appendingPathComponent("Recordings/\(name)")
                    setStatus("transcribing")
                    let text = await mgr.transcribeAndWait(file: url.lastPathComponent, sourceURL: url)
                    setStatus("done: \(text.count) chars")
                    Logger(subsystem: "com.ipodclassic.app", category: "transcribe").notice("QA \(text.prefix(400), privacy: .public)")
                } catch {
                    setStatus("FAILED: \(error)")
                    Logger(subsystem: "com.ipodclassic.app", category: "transcribe").notice("QA setup failed: \(String(describing: error), privacy: .public)")
                }
            }
        }

        // QA hook: QA_TTS runs the TTS pipeline end-to-end (model
        // download, load, synthesize) and writes stages to qa_status.txt.
        if let text = ProcessInfo.processInfo.environment["QA_TTS"] {
            Task { @MainActor in
                await audiobook.qaHook(text: text)
            }
        }

        // First launch: run the feature tour, then the one-time setup
        // wizard (permissions, voice model, defaults). RESET_DEFAULTS
        // (UI tests) skips both so existing tests stay on home;
        // SHOW_TOUR=1 / SHOW_SETUP=1 force them for QA.
        let resetDefaults = ProcessInfo.processInfo.environment["RESET_DEFAULTS"] == "1"
        let showSetup = ProcessInfo.processInfo.environment["SHOW_SETUP"] == "1"
        let showTour = ProcessInfo.processInfo.environment["SHOW_TOUR"] == "1"
        if showSetup {
            stack = [.setup]
        } else if showTour || (!resetDefaults && !UserDefaults.standard.bool(forKey: "tour.done")) {
            stack = [.tour]
        } else if !resetDefaults && !UserDefaults.standard.bool(forKey: "setup.done") {
            stack = [.setup]
        }

        // QA hook: START_ROUTE opens a specific screen first (UI tests).
        if let name = ProcessInfo.processInfo.environment["START_ROUTE"],
           let route = Self.route(named: name) {
            stack = [route]
        } else if let name = ProcessInfo.processInfo.environment["START_ROUTE"],
                  name == "readerLast", let first = reader.books.first {
            stack = [.readerBook(first.id)]
        }

        // QA hook: AUTOPLAY shuffle-plays the real library at launch
        // (device screenshots — ApplicationMusicPlayer is a simulator
        // no-op, so this only bites on hardware).
        if ProcessInfo.processInfo.environment["AUTOPLAY"] == "1" {
            Task { @MainActor in
                await music.refreshIfStale()
                let songs = music.songs
                guard !songs.isEmpty else { return }
                player.shufflePlay(songs)
                if stack.last != .nowPlaying {
                    stack.append(.nowPlaying)
                }
            }
        } else {
            // Restore the last session: what played, where in it, and in
            // what order — armed PAUSED, the user resumes with play/pause.
            // QA hooks that build their own playback state skip this.
            if ProcessInfo.processInfo.environment["FAKE_LIBRARY"] != "1" {
                Task { @MainActor in
                    music.refreshStatus()
                    guard music.isAuthorized,
                          let saved = PlaybackSessionStore.load(),
                          !saved.songIDs.isEmpty else { return }
                    let songs = await music.songs(withIDs: saved.songIDs)
                    player.restore(songs, index: saved.index, time: saved.playbackTime)
                }
            }
        }
    }

    /// Pure name-to-route lookup backing the START_ROUTE QA hook.
    /// `nonisolated` opts out of the class's main-actor isolation — safe
    /// for this pure lookup because it touches no mutable state.
    ///
    /// - Parameter name: lowercase route name from the launch environment.
    /// - Returns: the matching route, or nil for an unknown name.
    nonisolated static func route(named name: String) -> Route? {
        switch name {
        case "home": return .home
        case "music": return .music
        case "coverflow": return .coverFlow
        case "albums": return .musicAlbums
        case "songs": return .musicSongs
        case "playlists": return .musicPlaylists
        case "nowplaying": return .nowPlaying
        case "artistSearch": return .artistSearch("qa.artist.0")
        case "photos": return .photos
        case "camera": return .camera
        case "recorder": return .recorder
        case "recordings": return .recordings
        case "recordingsTrash": return .recordingsTrash
        case "recordingsDictionary": return .recordingsDictionary
        case "transcript": return .transcript(QASeed.transcriptFileName)
        case "notes": return .notes
        case "noteEditor": return .noteEditor(QASeed.qaNoteName)
        case "noteTrash": return .noteTrash
        case "clocks": return .clocks
        case "calendar": return .calendar
        case "binaural": return .binaural
        case "extras": return .extras
        case "flashlight": return .flashlight
        case "reader": return .reader
        case "readerBooks": return .readerBooks
        case "readerArticles": return .readerArticles
        case "search": return .musicSearch
        case "timer": return .timer
        case "stopwatch": return .stopwatch
        case "settings": return .settings
        case "clickwheel": return .settingsClickwheel
        case "display": return .settingsDisplay
        case "playback": return .settingsPlayback
        case "setup": return .setup
        case "tour": return .tour
        default: return nil
        }
    }

    /// Timestamp of the most recent wheel input; anchors the idle-dim timer.
    private var lastInputAt = Date()

    /// Finishes first-run setup: marks it done and lands on home.
    func completeSetup() {
        UserDefaults.standard.set(true, forKey: "setup.done")
        stack = [.home]
    }

    /// Finishes the feature tour: marks it done and moves on to setup
    /// (or straight home when setup already ran).
    func completeTour() {
        UserDefaults.standard.set(true, forKey: "tour.done")
        stack = UserDefaults.standard.bool(forKey: "setup.done") ? [.home] : [.setup]
    }

    /// Pushes a route with the classic slide animation; pushing the route
    /// already on top is a no-op.
    func push(_ route: Route) {
        guard stack.last != route else { return }
        withAnimation(.easeOut(duration: 0.22)) {
            stack.append(route)
        }
    }

    /// Pops one screen with animation; never pops past home.
    func pop() {
        guard stack.count > 1 else { return }
        withAnimation(.easeOut(duration: 0.22)) {
            stack.removeLast()
        }
    }

    /// Pops the whole stack back to home (MENU long-press).
    func popToRoot() {
        guard stack.count > 1 else { return }
        withAnimation(.easeOut(duration: 0.22)) {
            stack = [.home]
        }
    }

    /// App Shortcut / Action Button entry: wake, reset to home, open camera.
    @MainActor
    func openCameraShortcut() {
        screenAsleep = false
        withAnimation(.easeOut(duration: 0.22)) {
            stack = [.home, .camera]
        }
    }

    // MARK: Input

    /// Entry point for every click-wheel event. Handles the hold switch,
    /// sleep, idle-dimming, and routing to the active screen.
    func handle(_ event: ControlEvent) {
        lastInputAt = Date()

        if screenAsleep {
            // Any press wakes the device; the press itself is swallowed.
            if event != .tick(1) && event != .tick(-1) {
                withAnimation(.easeIn(duration: 0.15)) { screenAsleep = false }
            }
            return
        }
        if holdActive { return }

        // While the ringer overlay is up, it owns all input.
        if ringer != nil {
            ringerBus.send(event)
            return
        }

        // Global transport handling (classic iPod behavior) unless a screen
        // claimed the media buttons (camera).
        if !transportClaimedByScreen {
            switch event {
            case .playPause:
                if binaural.isPlaying { binaural.stop() }
                player.togglePlayPause()
                return
            case .next:
                player.next()
                return
            case .prev:
                player.previous()
                return
            case .nextHold:
                player.scrub(to: player.playbackTime + 10)
                return
            case .prevHold:
                player.scrub(to: player.playbackTime - 10)
                return
            case .playHold:
                withAnimation(.easeIn(duration: 0.2)) { screenAsleep = true }
                return
            case .menuHold:
                popToRoot()
                return
            default:
                break
            }
        }

        controlBus.send(event)
    }

    /// Seconds since the last input event; the LCD dims once this passes
    /// the configured threshold.
    var idleSeconds: TimeInterval { Date().timeIntervalSince(lastInputAt) }

    /// Resets the idle countdown without routing a wheel event (body
    /// taps, returning to the foreground).
    func markActivity() { lastInputAt = Date() }

    /// UI heartbeat so idle-dim thresholds re-evaluate every couple of
    /// seconds. Views must READ this (tracked) — writing plain @State that
    /// body never reads no longer invalidates a SwiftUI view.
    private(set) var clockTick = Date()

    /// Updates the heartbeat timestamp; views that read `clockTick`
    /// re-render and re-check their time-based logic.
    func tickIdle() { clockTick = Date() }

    /// Raises the alarm/timer ringer overlay and starts its sound. While
    /// `ringer` is set, `handle` diverts every event to `ringerBus` so
    /// the screen underneath cannot react.
    ///
    /// - Parameter context: what is ringing (alarm vs timer) and its title.
    func startRinger(_ context: RingerContext) {
        ringer = context
        // Media-audio tone loop — plays through the hardware mute switch
        // (the notification's sound is the redundant, switch-muteable
        // path; see RingerManager).
        RingerManager.shared.startSound()
    }
}

/// What is currently sounding the in-app timer overlay.
struct RingerContext: Equatable {
    /// What is sounding (kept as an enum for future kinds).
    enum Kind: Equatable { case timer }
    /// Which subsystem fired.
    let kind: Kind
    /// Headline shown on the ringer overlay.
    var title: String
}
