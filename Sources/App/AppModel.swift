import Foundation
import SwiftUI
import Combine

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

    // Notes
    case notes
    case noteEditor(String)

    // Clocks
    case clocks
    case alarm
    case timer
    case stopwatch

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
    let timer = TimerModel()
    let stopwatch = StopwatchModel()
    let settings = AppSettings.shared
    let alarms = AlarmStore.shared

    let controlBus = PassthroughSubject<ControlEvent, Never>()
    /// Events while the alarm/timer ringer is up go here instead, so the
    /// underlying screen can't react to them.
    let ringerBus = PassthroughSubject<ControlEvent, Never>()

    init() {
        // QA hook: launch with SIMCTL_CHILD_START_ROUTE=alarm etc. to open
        // a specific screen first.
        if let name = ProcessInfo.processInfo.environment["START_ROUTE"],
           let route = Self.route(named: name) {
            stack = [route]
        }
    }

    static func route(named name: String) -> Route? {
        switch name {
        case "music": return .music
        case "coverflow": return .coverFlow
        case "albums": return .musicAlbums
        case "songs": return .musicSongs
        case "playlists": return .musicPlaylists
        case "nowplaying": return .nowPlaying
        case "photos": return .photos
        case "camera": return .camera
        case "recorder": return .recorder
        case "recordings": return .recordings
        case "notes": return .notes
        case "clocks": return .clocks
        case "alarm": return .alarm
        case "timer": return .timer
        case "stopwatch": return .stopwatch
        case "settings": return .settings
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

    func startRinger(_ context: RingerContext) {
        ringer = context
    }
}

/// What is currently sounding the in-app alarm/timer overlay.
struct RingerContext: Equatable {
    enum Kind: Equatable { case alarm(id: UUID), timer }
    let kind: Kind
    var title: String
}
