import SwiftUI
import UserNotifications

@main
struct iPodClassicApp: App {
    @State private var model: AppModel

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
        }
    }
}
