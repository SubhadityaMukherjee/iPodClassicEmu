import Foundation
import AVFoundation
import FluidAudio

/// Custom-dictionary boosting of a finished transcript: re-scoring the
/// decoded words against the CTC keyword-spotter evidence (FluidAudio's
/// `VocabularyBoostingSession`) so names the ASR misheard come out right.
///
/// The batch AsrManager has no built-in boosting, so this runs AFTER
/// `transcribe` returns: the transcript's global token timings are split
/// into time windows at word boundaries, each window's audio is re-read
/// from disk (16 kHz mono — memory stays window-sized even for hour-long
/// memos), the CTC pass proposes replacements, and they are spliced onto
/// the ORIGINAL text at exact character ranges — so punctuation, casing
/// and paragraph formatting outside a replaced span survive untouched.
/// Windows where matching fails fall back to the rescorer's rebuilt
/// text; the whole pass is best-effort and must never break transcription.
/// Concept: on-device ML → docs/concepts/on-device-ml.md
enum TranscriptBoost {

    /// Length of one rescoring window in audio seconds. Bounds both the
    /// decoded samples (~11 MB) and the CTC log-prob matrix (~18 MB) held
    /// at once, independent of recording length.
    static let windowSeconds = 180.0

    /// One whitespace-split word of the transcript, with its exact
    /// character range in the text it came from.
    struct WordSpan {
        /// The raw word as it appears in the text (punctuation included).
        let text: String
        /// The word's range in the source string (same string instance).
        let range: Range<String.Index>
    }

    /// One decoder word derived from token timings: the token index range
    /// it covers plus its global audio time span. Mirrors the SDK's
    /// `buildWordTimings` grouping (SentencePiece `▁` starts a word,
    /// blank/pad tokens skipped) so token indices and word boundaries
    /// always agree.
    struct TokenGroup {
        /// Half-open range into the token-timing array this word covers.
        let tokens: Range<Int>
        /// The word's text (boundary marker stripped, whitespace trimmed).
        let word: String
        /// Global audio start, seconds.
        let start: TimeInterval
        /// Global audio end, seconds.
        let end: TimeInterval
    }

    /// Comparison form of a word: lowercased, letters and numbers only.
    /// Punctuation and case never affect matching — "In video," equals
    /// "in video".
    static func normalized(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Splits `text` on whitespace, keeping each word's range.
    /// - Parameter text: the string the ranges refer to.
    /// - Returns: one span per word, in order.
    static func wordSpans(in text: String) -> [WordSpan] {
        var spans: [WordSpan] = []
        var wordStart: String.Index?
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if ch.isWhitespace {
                if let start = wordStart {
                    spans.append(WordSpan(text: String(text[start..<i]), range: start..<i))
                    wordStart = nil
                }
            } else if wordStart == nil {
                wordStart = i
            }
            i = text.index(after: i)
        }
        if let start = wordStart {
            spans.append(WordSpan(text: String(text[start..<text.endIndex]), range: start..<text.endIndex))
        }
        return spans
    }

    /// Groups token timings into decoder words, mirroring the SDK's
    /// `buildWordTimings` (▁/space starts a new word; blank and pad
    /// tokens carry no text and are skipped).
    /// - Parameter timings: the transcription's global token timings.
    /// - Returns: one group per word, in order.
    static func tokenGroups(from timings: [TokenTiming]) -> [TokenGroup] {
        var groups: [TokenGroup] = []
        var start = 0
        var lastConsumed = -1
        var word = ""
        var wordStartTime: TimeInterval = 0
        var wordEndTime: TimeInterval = 0
        func flush() {
            let trimmed = word.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, lastConsumed >= start else { return }
            groups.append(TokenGroup(tokens: start..<(lastConsumed + 1), word: trimmed,
                                     start: wordStartTime, end: wordEndTime))
        }
        for (idx, timing) in timings.enumerated() {
            let token = timing.token
            if token.isEmpty || token == "<blank>" || token == "<pad>" { continue }
            let boundary = token.hasPrefix("▁") || token.hasPrefix(" ")
            if boundary, !word.isEmpty {
                flush()
                word = ""
            }
            if boundary {
                var piece = token
                if piece.hasPrefix("▁") { piece.removeFirst() }
                word += piece
                wordStartTime = timing.startTime
                start = idx
            } else {
                word += token
            }
            wordEndTime = timing.endTime
            lastConsumed = idx
        }
        flush()
        return groups
    }

    /// Positional alignment between the transcript's whitespace words and
    /// the decoder's timing-derived words. Both come from the same token
    /// stream, so they correspond 1:1; anything else (edited text, a
    /// foreign transcript) refuses to align and boosting is skipped.
    /// - Parameters:
    ///   - text: the transcript text.
    ///   - timings: the token timings saved with it.
    /// - Returns: word spans (ranges into `text`) and token groups, or
    ///   nil when the two sequences don't correspond.
    static func align(text: String, timings: [TokenTiming])
        -> (spans: [WordSpan], groups: [TokenGroup])? {
        let spans = wordSpans(in: text)
        let groups = tokenGroups(from: timings)
        guard spans.count == groups.count, !spans.isEmpty else { return nil }
        for (span, group) in zip(spans, groups) {
            guard normalized(span.text) == normalized(group.word) else { return nil }
        }
        return (spans, groups)
    }

    /// One rescoring window: a contiguous word range, its original text
    /// substring, and the segment-local timings on the same clock as the
    /// window's audio.
    struct Window {
        /// The window's range in the ORIGINAL text (same string instance).
        let textRange: Range<String.Index>
        /// The original substring the rescorer sees.
        let text: String
        /// Timings re-based so time zero is the window's first sample.
        let timings: [TokenTiming]
        /// Global audio start of the window, seconds.
        let start: TimeInterval
        /// Audio length of the window, seconds.
        let duration: TimeInterval
    }

    /// Splits an aligned transcript into time-bounded windows at word
    /// boundaries: each window spans at most `windowSeconds` of audio (a
    /// single over-long word still forms its own window).
    /// - Parameters:
    ///   - spans: word spans from `align` (ranges into `text`).
    ///   - groups: token groups from `align`.
    ///   - timings: the full token-timing array the groups index into.
    ///   - text: the full transcript string.
    /// - Returns: consecutive windows covering every word exactly once.
    static func windows(spans: [WordSpan], groups: [TokenGroup],
                        timings: [TokenTiming], in text: String) -> [Window] {
        var out: [Window] = []
        var i = 0
        while i < spans.count {
            let windowStart = groups[i].start
            var j = i + 1
            while j < spans.count, groups[j].end - windowStart <= windowSeconds { j += 1 }
            let range = spans[i].range.lowerBound..<spans[j - 1].range.upperBound
            let localTimings = groups[i..<j].flatMap { group in
                group.tokens.map { idx -> TokenTiming in
                    let t = timings[idx]
                    return TokenTiming(
                        token: t.token, tokenId: t.tokenId,
                        startTime: max(0, t.startTime - windowStart),
                        endTime: max(0, t.endTime - windowStart),
                        confidence: t.confidence)
                }
            }
            out.append(Window(
                textRange: range,
                text: String(text[range]),
                timings: localTimings,
                start: windowStart,
                duration: max(groups[j - 1].end - windowStart, 0.01)))
            i = j
        }
        return out
    }

    /// Applies rescore replacements onto a window's ORIGINAL substring at
    /// exact character ranges, so surrounding punctuation and casing
    /// survive. Matches greedily left-to-right: each `originalWord`
    /// (normalized; possibly a multi-word span) must consume the next
    /// unmatched words of the window. Returns nil when anything doesn't
    /// line up — the caller then falls back to the rescorer's rebuilt
    /// text.
    /// - Parameters:
    ///   - replacements: the rescorer's decisions for this window.
    ///   - text: the window's original text (unchanged substring).
    /// - Returns: the window text with replacements written in, or nil.
    static func applying(_ replacements: [VocabularyRescorer.RescoringResult], to text: String) -> String? {
        let spans = wordSpans(in: text)
        guard !spans.isEmpty else { return nil }
        var edits: [(range: Range<String.Index>, replacement: String)] = []
        var consumed = 0
        for result in replacements where result.shouldReplace {
            let target = normalized(result.originalWord)
            let replacement = result.replacementWord ?? ""
            guard !target.isEmpty else { return nil }
            var matched: Range<Int>?
            // Scan forward from the consumed position: each candidate
            // start tries to build the target out of consecutive words.
            // The rescorer walks spans left-to-right, so the first
            // occurrence at or after `consumed` is its span.
            scan: for startPos in consumed..<spans.count {
                var acc = ""
                var end = startPos
                while end < spans.count {
                    acc += normalized(spans[end].text)
                    if acc == target {
                        matched = startPos..<end + 1
                        break scan
                    }
                    if acc.count > target.count { break }
                    end += 1
                }
            }
            guard let m = matched else { return nil }
            let range = spans[m.lowerBound].range.lowerBound..<spans[m.upperBound - 1].range.upperBound
            edits.append((range, replacement))
            consumed = m.upperBound
        }
        // Compose from slices — never mutate through stale String.Index.
        var out = ""
        var cursor = text.startIndex
        for edit in edits {
            out += text[cursor..<edit.range.lowerBound]
            out += replacementSegment(range: edit.range, in: text, replacement: edit.replacement)
            cursor = edit.range.upperBound
        }
        out += text[cursor...]
        return out
    }

    /// The replacement text with the span's edge punctuation re-attached:
    /// "in video," → "NVIDIA," (the comma survives, only the words swap).
    static func replacementSegment(range: Range<String.Index>, in text: String, replacement: String) -> String {
        func alnum(_ ch: Character) -> Bool { ch.isLetter || ch.isNumber }
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower < upper, !alnum(text[lower]) { lower = text.index(after: lower) }
        while upper > lower, !alnum(text[text.index(before: upper)]) { upper = text.index(before: upper) }
        return String(text[range.lowerBound..<lower]) + replacement + String(text[upper..<range.upperBound])
    }

    /// Full boosting pass: align, window, rescore each window against the
    /// dictionary, and splice replacements back into the original text.
    /// Returns the input unchanged when there is nothing to align, the
    /// audio can't be read, or no window changed.
    /// - Parameters:
    ///   - original: the raw decoder transcript.
    ///   - timings: its global token timings (nil/empty skips boosting).
    ///   - url: the recording file, read window-by-window.
    ///   - session: a boosting session built from the user's dictionary.
    /// - Returns: the boosted transcript (identical to `original` when
    ///   nothing was replaced).
    static func boosted(
        original: String,
        timings: [TokenTiming]?,
        url: URL,
        session: VocabularyBoostingSession
    ) async -> String {
        guard let timings, !timings.isEmpty, !original.isEmpty else { return original }
        guard let (spans, groups) = align(text: original, timings: timings) else { return original }
        let wins = windows(spans: spans, groups: groups, timings: timings, in: original)
        guard !wins.isEmpty else { return original }
        var edits: [(range: Range<String.Index>, replacement: String)] = []
        for window in wins {
            let samples = RecordingAudioReader.samples(from: url, start: window.start, duration: window.duration)
            guard !samples.isEmpty else { continue }
            guard let output = await session.rescore(
                text: window.text, tokenTimings: window.timings, audioSamples: samples),
                output.wasModified else { continue }
            if let applied = applying(output.replacements, to: window.text) {
                edits.append((window.textRange, applied))
            } else {
                // Matching failed — fall back to the rescorer's rebuilt
                // words for this window (loses punctuation inside it).
                edits.append((window.textRange, output.text))
            }
        }
        guard !edits.isEmpty else { return original }
        // Splice by composition: windows arrive in text order, so walking
        // forward while copying untouched slices keeps every index valid.
        var out = ""
        var cursor = original.startIndex
        for edit in edits {
            out += original[cursor..<edit.range.lowerBound]
            out += edit.replacement
            cursor = edit.range.upperBound
        }
        out += original[cursor...]
        return out
    }
}

/// Reads a time window of an audio file as 16 kHz mono Float samples —
/// the input the CTC keyword spotter (and the rescorer's clock) expect.
/// Seeks in the source file and reads only the window, so memory stays
/// window-sized no matter how long the recording is.
/// Concept: AVAudioFile & conversion → docs/concepts/avfoundation-playback.md
enum RecordingAudioReader {

    /// Reads `[start, start + duration)` of an audio file at 16 kHz mono.
    /// - Parameters:
    ///   - url: the audio file.
    ///   - start: window start in seconds.
    ///   - duration: window length in seconds.
    /// - Returns: mono samples; empty when the file can't be read
    ///   (boosting skips the window).
    static func samples(from url: URL, start: TimeInterval, duration: TimeInterval) -> [Float] {
        guard duration > 0 else { return [] }
        guard let file = try? AVAudioFile(forReading: url) else { return [] }
        let src = file.processingFormat
        guard let dst = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: src, to: dst) else { return [] }
        // Seek in the file's own clock; read a hair past the window so
        // the converter's resampler tail never starves.
        let seek = AVAudioFramePosition((start * src.sampleRate).rounded(.down))
        guard seek >= 0, seek < file.length else { return [] }
        file.framePosition = seek
        let span = min(AVAudioFrameCount(((duration + 0.1) * src.sampleRate).rounded(.up)),
                       AVAudioFrameCount(max(0, file.length - seek)))
        guard span > 0, let input = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: span) else { return [] }
        do {
            try file.read(into: input)
        } catch {
            return []
        }
        guard input.frameLength > 0 else { return [] }
        let outCapacity = AVAudioFrameCount((duration + 0.2) * 16_000) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: outCapacity) else { return [] }
        // The input closure hands the buffer over exactly once, then
        // reports no more data so the converter flushes; the loop only
        // retries in the rare case the first call produced nothing.
        var fedInput = false
        var attempts = 0
        while output.frameLength == 0, attempts < 3 {
            attempts += 1
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if fedInput {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                fedInput = true
                inputStatus.pointee = .haveData
                return input
            }
            if let error, status == .error { return [] }
            if output.frameLength == 0, fedInput { break }
        }
        guard let channel = output.floatChannelData?[0], output.frameLength > 0 else { return [] }
        // Trim the converter's tail (the read is padded 0.1 s so the
        // resampler never starves) — the contract is exactly
        // [start, start + duration).
        let wanted = Int(duration * 16_000)
        let count = min(Int(output.frameLength), wanted)
        return Array(UnsafeBufferPointer(start: channel, count: count))
    }
}
