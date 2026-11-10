import SwiftUI
import UIKit
import UserNotifications
import AVFoundation

@main
struct iPodClassicApp: App {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

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
