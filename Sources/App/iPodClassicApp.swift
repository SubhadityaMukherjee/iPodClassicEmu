import SwiftUI
import UserNotifications

@main
struct iPodClassicApp: App {
    @State private var model = AppModel()

    init() {
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
