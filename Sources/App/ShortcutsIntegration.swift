import AppIntents
import Foundation

/// Voice memos addressable from Shortcuts: transcribe on device with
/// Parakeet, or read back a saved transcript.
struct RecordingEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Voice Memo")
    static var defaultQuery = RecordingQuery()

    var id: String   // file name with extension, e.g. "Recording 2026-11-10 09-30-00.m4a"
    var name: String // display name without the extension

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct RecordingQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [RecordingEntity] {
        all().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [RecordingEntity] {
        all()
    }
    func defaultResult() async throws -> RecordingEntity? {
        all().first
    }
}

extension RecordingQuery {
    private func creationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }

    private func all() -> [RecordingEntity] {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Recordings", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return files
            .filter { $0.pathExtension == "m4a" }
            .sorted { creationDate($0) > creationDate($1) }
            .map { RecordingEntity(id: $0.lastPathComponent,
                                   name: $0.deletingPathExtension().lastPathComponent) }
    }
}

/// Transcribes a memo with Parakeet and returns the text (also saved to
/// the memo's persistent transcript).
struct TranscribeRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Transcribe Voice Memo"
    static var description = IntentDescription(
        "Transcribes a voice memo on device with Parakeet and saves the text with the recording.")

    @Parameter(title: "Voice Memo")
    var recording: RecordingEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Transcribe \(\.$recording)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let mgr = TranscriptionManager.shared
        try await mgr.ensureModels()
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("Recordings/\(recording.id)")
        let text = await mgr.transcribeAndWait(file: recording.id, sourceURL: url)
        guard !text.isEmpty else {
            return .result(value: "", dialog: "Nothing transcribed — the recording may be silent.")
        }
        return .result(value: text, dialog: "Transcribed \(text.count) characters.")
    }
}

/// Reads back a saved transcript.
struct GetTranscriptionIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Voice Memo Transcript"
    static var description = IntentDescription("Returns the saved transcript of a voice memo.")

    @Parameter(title: "Voice Memo")
    var recording: RecordingEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Get transcript of \(\.$recording)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = TranscriptStore.entry(for: recording.id)?.text ?? ""
        guard !text.isEmpty else {
            return .result(value: "", dialog: "No transcript saved for that memo yet.")
        }
        return .result(value: text, dialog: "\(text.count) characters")
    }
}
