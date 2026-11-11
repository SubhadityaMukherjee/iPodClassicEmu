import Foundation
import SwiftUI
import Combine
import os

enum WheelEventLog {
    static let logger = Logger(subsystem: "com.ipodclassic.app", category: "wheel")
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
    case prev
    case next
    /// Repeats every ~0.16s while prev/next is held.
    case prevHold
    case nextHold
    /// Released after a hold.
    case holdEnded
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

    // Photos
    case photos
    case photoDetail(Int)

    // Camera
    case camera

    // Voice Memos
    case recorder
    case recordings
    case recordingDetail(String)
    case transcript(String)

    // Notes
    case notes
    case noteEditor(String)

    // Clocks
    case clocks
    case alarm
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

    // Settings
    case settings
    case settingsClickwheel
    case settingsDisplay
    case settingsPlayback
    case settingsAbout
}

@Observable
final class AppModel {
    var stack: [Route] = [.home]

    /// Hold switch on the device body locks all wheel input.
    var holdActive = false
    /// Screen asleep (hold play/pause). Any wheel press wakes it.
    var screenAsleep = false
    /// Set when the alarm or timer fires while the app is open.
    var ringer: RingerContext?
    /// Screens like the camera claim prev/next/play for their own purposes;
    /// when set, media buttons go to the screen instead of the music player.
    var transportClaimedByScreen = false

    let music = MusicService()
    let player = PlayerModel()
    let photos = PhotoLibraryModel()
    let camera = CameraModel()
    let recorder = RecorderModel()
    let notes = NotesStore()
    let reader = ReaderStore.shared
    let timer = TimerModel()
    let stopwatch = StopwatchModel()
    let settings = AppSettings.shared
    let alarms = AlarmStore.shared

    let controlBus = PassthroughSubject<ControlEvent, Never>()
    /// Events while the alarm/timer ringer is up go here instead, so the
    /// underlying screen can't react to them.
    let ringerBus = PassthroughSubject<ControlEvent, Never>()

    init() {
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

        // QA hook: START_ROUTE opens a specific screen first (UI tests).
        if let name = ProcessInfo.processInfo.environment["START_ROUTE"],
           let route = Self.route(named: name) {
            stack = [route]
        } else if let name = ProcessInfo.processInfo.environment["START_ROUTE"],
                  name == "readerLast", let first = reader.books.first {
            stack = [.readerBook(first.id)]
        }

        // QA hook: ALARM_ENABLE arms (1) or disarms (0) the alarm from any
        // launch (bell/keep-alive screenshot checks).
        if let qaAlarm = ProcessInfo.processInfo.environment["ALARM_ENABLE"] {
            let store = AlarmStore.shared
            if qaAlarm == "1", !store.enabled {
                store.enabled = true
            } else if qaAlarm == "0", store.enabled {
                store.enabled = false
            }
            store.schedule()
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

    static func route(named name: String) -> Route? {
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
        case "transcript": return .transcript(QASeed.transcriptFileName)
        case "notes": return .notes
        case "noteEditor": return .noteEditor(QASeed.qaNoteName)
        case "clocks": return .clocks
        case "calendar": return .calendar
        case "extras": return .extras
        case "flashlight": return .flashlight
        case "reader": return .reader
        case "search": return .musicSearch
        case "alarm": return .alarm
        case "timer": return .timer
        case "stopwatch": return .stopwatch
        case "settings": return .settings
        case "clickwheel": return .settingsClickwheel
        case "display": return .settingsDisplay
        case "playback": return .settingsPlayback
        default: return nil
        }
    }

    private var lastInputAt = Date()

    // MARK: Navigation

    func push(_ route: Route) {
        guard stack.last != route else { return }
        withAnimation(.easeOut(duration: 0.22)) {
            stack.append(route)
        }
    }

    func pop() {
        guard stack.count > 1 else { return }
        withAnimation(.easeOut(duration: 0.22)) {
            stack.removeLast()
        }
    }

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

    var idleSeconds: TimeInterval { Date().timeIntervalSince(lastInputAt) }

    func markActivity() { lastInputAt = Date() }

    /// UI heartbeat so idle-dim thresholds re-evaluate every couple of
    /// seconds. Views must READ this (tracked) — writing plain @State that
    /// body never reads no longer invalidates a SwiftUI view.
    private(set) var clockTick = Date()

    func tickIdle() { clockTick = Date() }

    func startRinger(_ context: RingerContext) {
        ringer = context
        // Actual sound: .playback session ignores the silent switch.
        RingerManager.shared.startSound()
    }
}

/// What is currently sounding the in-app alarm/timer overlay.
struct RingerContext: Equatable {
    enum Kind: Equatable { case alarm(id: UUID), timer }
    let kind: Kind
    var title: String
}
