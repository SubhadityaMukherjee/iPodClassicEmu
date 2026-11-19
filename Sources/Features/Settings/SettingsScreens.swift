import SwiftUI
import MusicKit
import AVFoundation

/// Settings root: Apple Music status, Clickwheel, Display, Playback, About.
struct SettingsScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings
    /// Menu row the wheel cursor is on; ticks move it through `items`.
    @State private var selection = 0

    /// "(Connected) / (Not Set) / (Denied)" status suffix for the Apple
    /// Music row, derived from the current MusicKit authorization state.
    private var appleMusicDetail: String {
        switch model.music.status {
        case .authorized: return "(Connected)"
        case .notDetermined: return "(Not Set)"
        default: return "(Denied)"
        }
    }

    /// Settings rows; the Apple Music row's subtitle shows live auth
    /// status, the rest push sub-pages (or re-run setup).
    private var items: [MenuItem] {
        [
            MenuItem(id: "music", title: "Apple Music", detail: appleMusicDetail, showsChevron: false),
            MenuItem(id: "clickwheel", title: "Clickwheel"),
            MenuItem(id: "display", title: "Display"),
            MenuItem(id: "playback", title: "Playback"),
            MenuItem(id: "readaloud", title: "Read Aloud"),
            MenuItem(id: "about", title: "About"),
            MenuItem(id: "redoSetup", title: "Run Setup Again", symbol: "arrow.counterclockwise", showsChevron: false),
        ]
    }

    /// Settings menu list; MusicKit status refreshes on appear.
    var body: some View {
        MenuList(items: items, selection: selection)
            .onWheel { handle($0) }
            .onAppear { model.music.refreshStatus() }
    }

    /// Wheel input: ticks move the selection, center activates the
    /// highlighted row, MENU pops.
    private func handle(_ event: ControlEvent) {
        switch event {
        case .tick(let d):
            moveListSelection(&selection, count: items.count, delta: d, settings: settings)
        case .select:
            activateCurrent()
        case .menu:
            model.pop()
        default:
            break
        }
    }

    /// Acts on the highlighted row: requests MusicKit access when not yet
    /// authorized (loading the library on success), pushes the sub-pages,
    /// or re-runs the first-launch setup wizard.
    private func activateCurrent() {
        switch items[min(selection, items.count - 1)].id {
        case "music":
            if model.music.status != .authorized {
                Task {
                    await model.music.requestAccess()
                    if model.music.isAuthorized {
                        await model.music.loadLibrary()
                    }
                }
            }
        case "clickwheel": model.push(.settingsClickwheel)
        case "display": model.push(.settingsDisplay)
        case "playback": model.push(.settingsPlayback)
        case "readaloud": model.push(.settingsReadAloud)
        case "about": model.push(.settingsAbout)
        case "redoSetup":
            // Re-run the first-launch wizard (permissions, voice models,
            // factory preferences). completeSetup() lands back on home.
            model.push(.setup)
        default: break
        }
    }
}

/// Generic settings page with value-cycling rows: the wheel moves between
/// rows; center on a row cycles its value (or pushes `route`).
struct ValueSettingsScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings
    /// Row the wheel cursor is on.
    @State private var selection = 0

    /// One settings row: a title plus a live value string, and either a
    /// cycle action (center cycles the value) or a route to push.
    ///
    /// Concept: value/cycle closures → docs/concepts/swift-closures.md
    struct Row {
        /// Stable row identity.
        let id: String
        /// Left-hand label.
        let title: String
        /// Called on every render to produce the current value text — a
        /// closure (not a snapshot `String`) so a cycled value shows its
        /// new text on the very next render without manual refresh.
        let value: () -> String
        /// Center-press action that advances the value; nil when the row
        /// is a link (`route`) instead.
        let cycle: (() -> Void)?
        /// Sub-page pushed on center press, for rows that are links.
        let route: Route?

        /// Creates a row; exactly one of `cycle` and `route` should be
        /// non-nil so center-press has one unambiguous meaning.
        /// - Parameter id: stable row identity.
        /// - Parameter title: left-hand label.
        /// - Parameter value: called each render for the current value text.
        /// - Parameter cycle: action advancing the value on center press.
        /// - Parameter route: page to push on center instead of cycling.
        init(id: String, title: String, value: @escaping () -> String, cycle: (() -> Void)? = nil, route: Route? = nil) {
            self.id = id
            self.title = title
            self.value = value
            self.cycle = cycle
            self.route = route
        }
    }

    /// Page title. Not rendered by this view itself — the LCD title bar
    /// comes from ScreenRouter's route mapping — it documents the page at
    /// the construction site.
    let title: String
    /// The page's rows, in display order.
    let rows: [Row]

    /// Value-cycling menu list; row ids embed the live value so cycled text refreshes.
    var body: some View {
        MenuList(
            // Key each row by its current value so a cycled value rebuilds
            // the row (MenuItem identity alone wouldn't refresh the text).
            items: rows.map { MenuItem(id: "\($0.id).\($0.value())", title: $0.title, detail: $0.value()) },
            selection: selection
        )
        .onWheel { handle($0) }
    }

    /// Wheel input. Ticks always move between rows — values change only
    /// on center (the classic iPod feel: the wheel never edits, it
    /// navigates); center cycles the row's value with a haptic or pushes
    /// its route; MENU pops.
    private func handle(_ event: ControlEvent) {
        let row = rows[min(selection, rows.count - 1)]
        switch event {
        case .tick(let d):
            // The wheel always moves between rows; values change on center.
            moveListSelection(&selection, count: rows.count, delta: d, settings: settings)
        case .select:
            if let route = row.route {
                model.push(route)
            } else if let cycle = row.cycle {
                cycle()
                WheelHaptics.shared.buttonPress(strength: 0.6)
            }
        case .menu:
            model.pop()
        default:
            break
        }
    }
}

/// Clickwheel settings page.
struct ClickwheelSettingsScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings

    /// Display strings for the four scrolling-haptics strengths.
    private static let scrollLabels = ["Off", "Light", "Medium", "Strong"]
    /// Display strings for the three button-haptics strengths.
    private static let buttonLabels = ["Light", "Medium", "Heavy"]

    /// Clickwheel rows (haptics toggles and tick flavors) on the generic
    /// value-cycling page.
    var body: some View {
        ValueSettingsScreen(
            title: "Clickwheel",
            rows: [
                .init(id: "haptics", title: "Haptics", value: { settings.hapticsEnabled ? "On" : "Off" }) {
                    settings.hapticsEnabled.toggle()
                },
                .init(id: "scroll", title: "Scrolling Haptics", value: { Self.scrollLabels[min(settings.scrollingHaptics, 3)] }) {
                    settings.scrollingHaptics = (settings.scrollingHaptics + 1) % 4
                },
                .init(id: "button", title: "Button Haptics", value: { Self.buttonLabels[min(settings.buttonHaptics, 2)] }) {
                    settings.buttonHaptics = (settings.buttonHaptics + 1) % 3
                },
                .init(id: "ticks", title: "Tick Sounds", value: { settings.tickSounds ? "On" : "Off" }) {
                    settings.tickSounds.toggle()
                },
                .init(id: "infinite", title: "Infinite Tick", value: { settings.infiniteTick ? "On" : "Off" }) {
                    settings.infiniteTick.toggle()
                },
                .init(id: "type", title: "Tick Type", value: { settings.softTick ? "Soft Tick" : "Classic Tick" }) {
                    settings.softTick.toggle()
                },
            ]
        )
    }
}

/// Display settings page.
struct DisplaySettingsScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings

    /// Display strings for the four scanline intensities.
    private static let scanLabels = ["Off", "Subtle", "Medium", "Strong"]
    /// (label, seconds) pairs for the idle-dim delay; the row finds its
    /// current label by matching the seconds value.
    private static let dimLabels: [(String, Int)] = [("Off", 0), ("15 sec", 15), ("30 sec", 30), ("1 min", 60), ("5 min", 300)]
    /// Shared font-size labels (small/medium/large).
    private static let fontLabels = AppSettings.fontLabels
    /// Theme names, indexed by the 0/1 theme setting.
    private static let themeLabels = Theme.themeNames

    /// Display rows (theme, CRT/scanlines, dim delay, font size) on the
    /// generic value-cycling page.
    var body: some View {
        ValueSettingsScreen(
            title: "Display",
            rows: [
                .init(id: "theme", title: "Theme", value: { Self.themeLabels[min(settings.theme, 1)] }) {
                    settings.theme = (settings.theme + 1) % 2
                },
                .init(id: "crt", title: "CRT Effect", value: { settings.crtEnabled ? "On" : "Off" }) {
                    settings.crtEnabled.toggle()
                },
                .init(id: "scan", title: "Scanlines", value: { Self.scanLabels[min(settings.scanlineIntensity, 3)] }) {
                    settings.scanlineIntensity = (settings.scanlineIntensity + 1) % 4
                },
                .init(id: "dim", title: "Dim After", value: { Self.dimLabels.first(where: { $0.1 == settings.dimAfterSeconds })?.0 ?? "Off" }) {
                    let idx = Self.dimLabels.firstIndex(where: { $0.1 == settings.dimAfterSeconds }) ?? 0
                    settings.dimAfterSeconds = Self.dimLabels[(idx + 1) % Self.dimLabels.count].1
                },
                .init(id: "fontsize", title: "Font Size", value: { Self.fontLabels[min(settings.fontScale, 2)] }) {
                    settings.fontScale = (settings.fontScale + 1) % 3
                },
            ]
        )
    }
}

/// Playback settings page.
struct PlaybackSettingsScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings

    /// Display strings for the Off/All/One repeat modes.
    private static let repeatLabels = ["Off", "All", "One"]

    /// Playback rows (shuffle, repeat, volume step) on the generic
    /// value-cycling page.
    var body: some View {
        ValueSettingsScreen(
            title: "Playback",
            rows: [
                .init(id: "shuffle", title: "Shuffle", value: { settings.shuffle ? "On" : "Off" }) {
                    settings.shuffle.toggle()
                },
                .init(id: "repeat", title: "Repeat", value: { Self.repeatLabels[min(settings.repeatMode, 2)] }) {
                    settings.repeatMode = (settings.repeatMode + 1) % 3
                },
                .init(id: "volstep", title: "Volume Step", value: { "\(Int(settings.volumeStep * 100))%" }) {
                    settings.volumeStep = min(0.15, settings.volumeStep + 0.01)
                    if settings.volumeStep >= 0.15 { settings.volumeStep = 0.02 }
                },
            ]
        )
    }
}

/// About page.
struct AboutScreen: View {
    @Environment(AppModel.self) private var model

    /// Centered app icon, name, version, and tagline.
    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "circle.circle.fill")
                .font(Theme.font(40))
                .foregroundStyle(Theme.inkDim)
            Text("iPodClassic")
                .font(Theme.barTitle(19))
            Text("Version \(Self.version)")
                .font(Theme.font(12.5, .medium))
                .foregroundStyle(Theme.inkDim)
            Text("Music, photos, camera, memos,\nnotes and clocks — with a real\nclick wheel and haptics.")
                .font(Theme.font(11.5, .medium))
                .foregroundStyle(Theme.inkDim)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .onWheel { handle($0) }
    }

    /// MENU pops; nothing else responds — there is nothing to select here.
    private func handle(_ event: ControlEvent) {
        switch event {
        case .menu:
            model.pop()
        default:
            break
        }
    }

    /// Marketing version from the bundle's Info dictionary ("0.1.0" when
    /// missing, e.g. in some test contexts).
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }
}

/// Read Aloud voice-model management: choose the TTS engine (Pocket 18m /
/// Pocket 100M / Paradee 8M — all English, all sentence-chunked), download
/// its voice model on demand, and free disk by deleting it. Only the
/// SELECTED engine downloads. (Supertonic was removed 2026-11-19 — its
/// 70-char chunk cap cut sentences mid-word with ~1 s pauses; Kokoro is
/// process-killing on iOS 27.)
struct ReadAloudSettingsScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings
    /// Menu row the wheel cursor is on.
    @State private var selection = 0
    /// Short confirmation line under the list ("Download started",
    /// "Deleted"…); empty string hides it.
    @State private var toast = ""
    /// Voices panel open (audition + pick the engine's default voice).
    @State private var voicesOpen = false
    /// Voices panel cursor.
    @State private var voiceSel = 0
    /// Sample player for the voices panel (one at a time).
    @State private var samplePlayer: AVAudioPlayer?
    /// Voice currently being synthesized/played in the panel ("").
    @State private var sampling = ""

    /// The shared read-aloud engine/voice-model store this page manages.
    private var store: ReadAloudVoiceStore { .shared }

    /// Voice presets of the selected engine (the panel lists these).
    private var voices: [String] { store.engine.voices }

    /// The engine's effective voice (stored choice, else the first).
    private var currentVoice: String {
        let stored = ReadAloudVoiceStore.storedVoice(store.engine)
        return voices.first { $0 == stored } ?? voices[0]
    }

    /// Rows: Engine (cycles the three engines), Voice Model (live
    /// download progress or cached state for the SELECTED engine),
    /// Voices (pick + audition the engine's default voice), and, once a
    /// download exists, a Delete Model row to free its disk.
    private var items: [MenuItem] {
        var rows: [MenuItem] = []
        let engine = store.engine
        rows.append(MenuItem(
            id: "engine", title: "Engine",
            detail: engine.title, showsChevron: false))
        let cached = ReadAloudVoiceStore.hasCachedModel(engine)
        let detail: String
        switch store.state {
        case .downloading(let progress):
            detail = progress.map { String(format: "Downloading… %d%%", Int($0 * 100)) } ?? "Downloading…"
        case .loading: detail = "Loading…"
        case .failed(let message):
            // Keep the row one line: show the start of the error so a
            // dead download is visible instead of masquerading as
            // "Not downloaded" (the 2026-11-19 pocket mystery).
            detail = String(message.prefix(40))
        default:
            detail = cached ? "Downloaded ✓" : "Not downloaded"
        }
        rows.append(MenuItem(id: "model", title: "Voice Model", detail: detail, showsChevron: false))
        if cached {
            rows.append(MenuItem(id: "voices", title: "Voices", detail: currentVoice, showsChevron: true))
            rows.append(MenuItem(id: "delete", title: "Delete Model", detail: "Free Space", showsChevron: false))
        }
        return rows
    }

    /// Paper-backed settings list with a transient toast line beneath;
    /// the Voices audition panel overlays everything when open.
    var body: some View {
        ZStack {
            PaperBackground()
            VStack(spacing: 0) {
                MenuList(items: items, selection: selection)
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
                if !toast.isEmpty {
                    Text(toast)
                        .font(Theme.font(11, .semibold))
                        .foregroundStyle(Theme.inkDim)
                        .padding(.top, 8)
                }
                Spacer()
            }
            if voicesOpen {
                voicesPanel
            }
        }
        .onWheel { handle($0) }
    }

    /// Voice audition panel: every preset of the selected engine in a
    /// windowed MenuList (21 Pocket voices exceed the LCD — the list
    /// steps row-by-row with the wheel like every other menu); center
    /// picks a voice AND plays a short sample through it, ✓ marks the
    /// effective default, MENU closes.
    private var voicesPanel: some View {
        ModalPanel(title: "Voices — \(store.engine.title)", onClose: { voicesOpen = false }) {
            VStack(spacing: 0) {
                MenuList(items: voiceItems, selection: voiceSel, compact: true)
                    .frame(height: min(Double(voices.count) * 34.0, 214))
                    .padding(.horizontal, 6)
                Text("Center previews & sets")
                    .font(Theme.font(10, .semibold))
                    .foregroundStyle(Theme.inkDim)
                    .padding(.top, 6)
                    .padding(.bottom, 4)
            }
        }
    }

    /// MenuList rows for the engine's voices: ✓ = effective default,
    /// ▶ = sample currently synthesizing/playing.
    private var voiceItems: [MenuItem] {
        voices.map { name in
            MenuItem(
                id: name, title: name,
                detail: sampling == name ? "▶" : (name == currentVoice ? "✓" : ""),
                showsChevron: false)
        }
    }

    /// Wheel input: ticks move the selection, center activates the row,
    /// MENU pops, MENU-hold pops straight to the home screen. While the
    /// Voices panel is open, input routes to the panel instead.
    private func handle(_ event: ControlEvent) {
        switch event {
        case .tick(let d):
            if voicesOpen {
                moveListSelection(&voiceSel, count: voices.count, delta: d, settings: settings)
            } else {
                moveListSelection(&selection, count: items.count, delta: d, settings: settings)
            }
        case .select:
            if voicesOpen {
                pickVoice(voices[min(voiceSel, voices.count - 1)])
            } else {
                activate(items[min(selection, items.count - 1)].id)
            }
        case .menu:
            if voicesOpen {
                samplePlayer?.stop()
                samplePlayer = nil
                sampling = ""
                voicesOpen = false
            } else {
                model.pop()
            }
        case .menuHold:
            model.popToRoot()
        default:
            break
        }
    }

    /// Makes `name` the engine's default voice and plays a short sample
    /// through it (downloads/loads the engine first if needed).
    private func pickVoice(_ name: String) {
        ReadAloudVoiceStore.setStoredVoice(name, for: store.engine)
        samplePlayer?.stop()
        samplePlayer = nil
        sampling = name
        Task {
            do {
                let text = "This is how I sound when I read your books."
                let (samples, rate) = try await store.synthesize(
                    text: text, language: "en", voiceName: name)
                let buffer = AudiobookModel.makeBuffer(samples, sampleRate: rate)
                guard let wav = AudiobookAudioEngine.wavData(from: buffer) else { return }
                let player = try AVAudioPlayer(data: wav)
                player.volume = 1
                samplePlayer = player
                player.play()
            } catch {
                toast = String(error.localizedDescription.prefix(40))
            }
            if sampling == name { sampling = "" }
        }
    }

    /// Row actions: cycle the engine (the new engine downloads on next
    /// use); start the voice-model download (a no-op toast when already
    /// cached); or delete the cached model — deletion also resets the
    /// store's state so the row labels update.
    private func activate(_ id: String) {
        switch id {
        case "engine":
            let all = ReadAloudVoiceStore.Engine.allCases
            let next = all[(all.firstIndex(of: store.engine)! + 1) % all.count]
            store.engine = next
        case "model":
            if ReadAloudVoiceStore.hasCachedModel(store.engine) {
                toast = "Already downloaded"
            } else {
                toast = "Download started"
                Task { try? await store.prepare() }
            }
        case "voices":
            voicesOpen = true
            voiceSel = max(0, voices.firstIndex(of: currentVoice) ?? 0)
        case "delete":
            store.deleteDownloadedModel()
            toast = "Deleted"
        default:
            break
        }
    }
}
