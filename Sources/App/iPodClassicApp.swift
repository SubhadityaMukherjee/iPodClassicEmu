import SwiftUI
import UIKit
import UserNotifications
import AVFoundation

/// App entry point (`@main`). `init` runs the one-time bootstrap — audio
/// session, QA reset hooks, caches, terminate observer — and `body` hosts
/// the full-device UI and reacts to scene lifecycle.
///
/// Concept: swiftui-views-and-state → docs/concepts/swiftui-views-and-state.md
@main
struct iPodClassicApp: App {
    /// Root model, built once in `init` and owned for the app's whole
    /// lifetime. `@State` at App level is SwiftUI's owner-storage: the
    /// value exists before the first `body` evaluation and is never
    /// recreated across re-renders.
    ///
    /// Concept: swift-property-wrappers → docs/concepts/swift-property-wrappers.md
    @State private var model: AppModel
    /// System lifecycle signal (.active/.inactive/.background), observed
    /// to save state on background and heal alarms on foreground.
    @Environment(\.scenePhase) private var scenePhase

    /// One-shot bootstrap, ordered deliberately: the audio session must be
    /// active before any model reads volume, and RESET_DEFAULTS must clear
    /// storage before the model singletons are built (they would otherwise
    /// capture the stale values). Also sizes the shared URLCache for
    /// artwork, registers a terminate-time session save, and enables
    /// battery monitoring for the status-bar icon.
    ///
    /// Concept: AVAudioSession
    init() {
        // ApplicationMusicPlayer runs in-process and needs an active
        // .playback audio session or playback dies when the app
        // backgrounds. Configure once, before any model reads volume.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)

        // QA hook: RESET_DEFAULTS must run BEFORE AppModel (and the
        // settings/alarms singletons it holds) are created, or they would
        // read the stale persisted values.
        if ProcessInfo.processInfo.environment["RESET_DEFAULTS"] == "1",
           let bundle = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundle)
        }
        // QA hook: DIM_AFTER forces the idle-dim threshold in seconds
        // (screenshots / UI tests; the sim ignores injected defaults).
        if let s = ProcessInfo.processInfo.environment["DIM_AFTER"], let v = Int(s) {
            AppSettings.shared.dimAfterSeconds = v
        }
        _model = State(initialValue: AppModel())

        // Force-quit / crash insurance: scenePhase .background doesn't run
        // when the app is swiped away or killed, so persist the session on
        // terminate too. saveSession is idempotent.
        let sessionPlayer = model.player
        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { _ in sessionPlayer.saveSession() }

        // Apple's artwork CDN serves long-lived cache headers, but the
        // default shared URLCache is tiny — album grids re-downloaded
        // covers on every scroll round-trip and relaunch. Give it room
        // (decoded bitmaps stay bounded by ArtworkLoader's NSCache).
        URLCache.shared = URLCache(
            memoryCapacity: 16 * 1024 * 1024,
            diskCapacity: 96 * 1024 * 1024,
            diskPath: "artwork-urlcache"
        )

        AlarmNotifications.configureDelegate()
        AppModelRouter.shared.model = self.model
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    /// The single window: the full-device iPod UI plus scene-phase
    /// handling — persist the playback session and start the alarm
    /// keep-alive on background; stop keep-alive, reconcile alarms, mark
    /// activity, and refresh the music library on foreground.
    var body: some Scene {
        WindowGroup {
            DeviceView()
                .environment(model)
                .environmentObject(model.settings)
                .environmentObject(model.alarms)
                .preferredColorScheme(.dark)
                .persistentSystemOverlays(.hidden)
                .statusBarHidden()
                .onChange(of: scenePhase) { _, phase in
                    // While backgrounded with an armed alarm, keep the
                    // process alive so the in-app ringer can fire (full
                    // volume, silent-switch-proof). Killed-app fallback is
                    // the system notification.
                    switch phase {
                    case .background:
                        // Persist what's playing so a relaunch restores it
                        // (queue, current track, position).
                        model.player.saveSession()
                        if model.alarms.enabled { model.alarms.startKeepAlive() }
                    case .active:
                        model.alarms.stopKeepAlive()
                        // Heal the alarm on every foreground: if a fire/
                        // dismiss cycle died mid-way (force-quit, crash,
                        // reboot), the notification requests are gone while
                        // the alarm still reads "on" — reconcile re-arms.
                        // Unconditional: with the alarm OFF it cancels any
                        // ghost requests installed earlier this session
                        // (gating on `enabled` would leave those alive
                        // until the next launch).
                        model.alarms.reconcile()
                        // Returning to the foreground is activity. The
                        // process stays alive in the background (playback
                        // audio session), so idleSeconds keeps growing
                        // while away — without this the screen would come
                        // back already dimmed.
                        model.markActivity()
                        // Library may have changed while we were gone.
                        Task { await model.music.refreshIfStale() }
                    default:
                        break
                    }
                }
        }
    }
}
