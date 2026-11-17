import AppIntents
import UIKit

/// App Shortcut so the Action Button (or Spotlight/Shortcuts) can jump
/// straight into the camera, like the stock Camera shortcut.
///
/// Concept: AppIntents → docs/concepts/app-intents.md
struct OpenCameraIntent: AppIntent {
    /// Short user-visible name in Spotlight and the Shortcuts list.
    static let title: LocalizedStringResource = "Open Camera"
    /// Longer explanation shown in the Shortcuts editor.
    static let description = IntentDescription("Opens iPodClassic straight to the camera.")
    /// Opens (or foregrounds) the app when run — a camera shortcut is no
    /// good if it leaves the app in the background.
    static let openAppWhenRun = true

    /// Routes the live AppModel to its camera shortcut, which pushes the
    /// camera route onto the navigation stack.
    ///
    /// - Returns: A plain success result (the app opening is the effect).
    @MainActor
    func perform() async throws -> some IntentResult {
        AppModelRouter.shared.model?.openCameraShortcut()
        return .result()
    }
}

/// Registers the app's App Shortcuts — the camera, transcription, and
/// add-article actions appear in Spotlight, the Action Button, and Siri
/// without the user building anything in Shortcuts.
///
/// Concept: AppIntents → docs/concepts/app-intents.md
struct iPodClassicShortcuts: AppShortcutsProvider {
    /// The app's shortcut list (camera, transcribe memo, get transcript,
    /// add article) with their spoken/Spotlight phrases.
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
        AppShortcut(
            intent: TranscribeRecordingIntent(),
            phrases: ["Transcribe voice memo in \(.applicationName)"],
            shortTitle: "Transcribe Voice Memo",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: GetTranscriptionIntent(),
            phrases: ["Get transcript in \(.applicationName)"],
            shortTitle: "Get Voice Memo Transcript",
            systemImageName: "doc.text"
        )
        AppShortcut(
            intent: AddArticleIntent(),
            phrases: ["Add article to \(.applicationName)"],
            shortTitle: "Add Article",
            systemImageName: "newspaper"
        )
    }
}
