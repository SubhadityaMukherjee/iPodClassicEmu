import Foundation

enum TimeFormat {
    /// "14:04" style clock for the title bar, following the user's locale.
    static func clock(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    /// "1:23" elapsed / remaining playback time.
    static func mss(_ t: TimeInterval) -> String {
        let total = Int(t.rounded())
        let s = total % 60, m = (total / 60) % 60, h = total / 3600
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    /// "00:05:00" timer digits.
    static func hms(_ t: TimeInterval) -> String {
        let total = Int(t.rounded())
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }

    /// Stopwatch "02:15.34".
    static func stopwatch(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        let cs = Int((t - t.rounded(.down)) * 100)
        return String(format: "%02d:%02d.%02d", m, s, cs)
    }

    static func duration(_ t: TimeInterval) -> String {
        let total = Int(t.rounded())
        if total >= 3600 { return hms(TimeInterval(total)) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// File-ish timestamp for recordings: "2026-11-04 14-05".
    static func recordingStamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH-mm"
        return f.string(from: date)
    }

    /// Friendly recording name: "Nov 4, 2026 14:05".
    static func friendly(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}
