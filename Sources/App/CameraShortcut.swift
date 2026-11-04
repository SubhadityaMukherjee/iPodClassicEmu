import AppIntents
import UIKit

/// App Shortcut so the Action Button (or Spotlight/Shortcuts) can jump
/// straight into the camera, like the stock Camera shortcut.
struct OpenCameraIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Camera"
    static let description = IntentDescription("Opens iPodClassic straight to the camera.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModelRouter.shared.model?.openCameraShortcut()
        return .result()
    }
}

struct iPodClassicShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenCameraIntent(),
            phrases: [
                "Open \(.applicationName) camera",
                "Start \(.applicationName) camera",
                "\(.applicationName) camera",
            ],
            shortTitle: "Open Camera",
            systemImageName: "camera.fill"
        )
    }
}
