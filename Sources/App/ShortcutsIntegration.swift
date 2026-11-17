import AppIntents
import Foundation

/// Voice memos addressable from Shortcuts: transcribe on device with
/// Parakeet, or read back a saved transcript.
///
/// Concept: AppIntents → docs/concepts/app-intents.md
struct RecordingEntity: AppEntity {
    /// Type name Shortcuts shows for this entity ("Voice Memo").
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Voice Memo")
    /// The query Shortcuts uses to list and resolve memos.
    static var defaultQuery = RecordingQuery()

    var id: String   // file name with extension, e.g. "Recording 2026-11-10 09-30-00.m4a"
    var name: String // display name without the extension

    /// Row title in the Shortcuts UI (the memo's display name).
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

/// Finds voice memos for Shortcuts: resolves previously chosen identifiers
/// and lists suggestions (newest first) when a user picks a memo.
struct RecordingQuery: EntityQuery {
    /// Resolves the memos matching identifiers chosen in an earlier run.
    ///
    /// - Parameter identifiers: File names (with extension) picked earlier.
    /// - Returns: Matching entities; unknown identifiers are dropped.
    func entities(for identifiers: [String]) async throws -> [RecordingEntity] {
        all().filter { identifiers.contains($0.id) }
    }

    /// All memos, newest first — the picker's suggestion list.
    func suggestedEntities() async throws -> [RecordingEntity] {
        all()
    }
    /// Preselected value when a shortcut runs without a chosen memo: the
    /// newest recording.
    func defaultResult() async throws -> RecordingEntity? {
        all().first
    }
}

/// Directory-reading helpers backing the query's public methods.
extension RecordingQuery {
    /// A recording file's creation date, falling back to `.distantPast`
    /// (sorts last) when the value is unavailable.
    ///
    /// - Parameter url: Recording file URL.
    /// - Returns: The file's creation date, or `.distantPast`.
    private func creationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }

    /// Every `.m4a` in Documents/Recordings as entities, newest first.
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
    /// Short user-visible name.
    static var title: LocalizedStringResource = "Transcribe Voice Memo"
    /// Longer explanation shown in the Shortcuts editor.
    static var description = IntentDescription(
        "Transcribes a voice memo on device with Parakeet and saves the text with the recording.")

    /// The memo to transcribe, resolved via `RecordingQuery`.
    @Parameter(title: "Voice Memo")
    var recording: RecordingEntity

    /// One-line parameter summary shown under the action in Shortcuts.
    static var parameterSummary: some ParameterSummary {
        Summary("Transcribe \(\.$recording)")
    }

    /// Ensures the transcription model is downloaded, transcribes the memo
    /// on device, and paragraph-formats the text; the result is returned to
    /// Shortcuts for chaining and also saved with the recording.
    ///
    /// - Returns: The transcript text plus a character-count dialog; a silent
    ///   recording returns empty text with a "nothing transcribed" dialog.
    /// - Throws: Errors from model download/loading or transcription.
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let mgr = TranscriptionManager.shared
        try await mgr.ensureModels()
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("Recordings/\(recording.id)")
        let text = TranscriptStore.formatParagraphs(
            await mgr.transcribeAndWait(file: recording.id, sourceURL: url))
        guard !text.isEmpty else {
            return .result(value: "", dialog: "Nothing transcribed — the recording may be silent.")
        }
        return .result(value: text, dialog: "Transcribed \(text.count) characters.")
    }
}

/// Reads back a saved transcript.
struct GetTranscriptionIntent: AppIntent {
    /// Short user-visible name.
    static var title: LocalizedStringResource = "Get Voice Memo Transcript"
    /// Longer explanation shown in the Shortcuts editor.
    static var description = IntentDescription("Returns the saved transcript of a voice memo.")

    /// The memo whose saved transcript to read.
    @Parameter(title: "Voice Memo")
    var recording: RecordingEntity

    /// One-line parameter summary shown under the action in Shortcuts.
    static var parameterSummary: some ParameterSummary {
        Summary("Get transcript of \(\.$recording)")
    }

    /// Reads the memo's persisted transcript and formats it into paragraphs.
    ///
    /// - Returns: The transcript text plus a character-count dialog; no saved
    ///   transcript yields an explanatory dialog with empty text.
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let raw = TranscriptStore.entry(for: recording.id)?.text ?? ""
        let text = TranscriptStore.formatParagraphs(raw)
        guard !text.isEmpty else {
            return .result(value: "", dialog: "No transcript saved for that memo yet.")
        }
        return .result(value: text, dialog: "\(text.count) characters")
    }
}

/// Read Later: adds a URL to the Reader's Articles list. Pairs with a
/// Shortcut that receives URLs from the share sheet, so any app's share
/// button can file an article into the iPod for distraction-free reading.
struct AddArticleIntent: AppIntent {
    /// Short user-visible name.
    static var title: LocalizedStringResource = "Add Article to Reader"
    /// Longer explanation shown in the Shortcuts editor.
    static var description = IntentDescription(
        "Saves a web article to the Reader's Articles list for offline reading.")

    /// The article URL to save, typed as a plain string so any URL value can
    /// be passed in from Shortcuts.
    @Parameter(title: "URL") var url: String

    /// Extracts and saves the article into the Reader's Articles list.
    ///
    /// - Returns: A dialog naming the saved article.
    /// - Throws: Rethrows extraction/saving failures (bad URL, unreadable page).
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let book = try await ReaderStore.shared.addArticle(from: url)
        return .result(dialog: "Saved \"\(book.title)\"")
    }
}
