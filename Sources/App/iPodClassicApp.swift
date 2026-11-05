import SwiftUI
import UIKit
import UserNotifications

@main
struct iPodClassicApp: App {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // QA hook: RESET_DEFAULTS must run BEFORE AppModel (and the
        // settings/alarms singletons it holds) are created, or they would
        // read the stale persisted values.
        if ProcessInfo.processInfo.environment["RESET_DEFAULTS"] == "1",
           let bundle = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundle)
        }
        _model = State(initialValue: AppModel())

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
                        if model.alarms.enabled { model.alarms.startKeepAlive() }
                    case .active:
                        model.alarms.stopKeepAlive()
                    default:
                        break
                    }
                }
        }
    }
}
