import Foundation

/// Server times are business times: epoch seconds rendered in the service's own UTC offset
/// (`timezone` in the snapshot), not the phone's. A person checking a Chinese link from another
/// country still sees the day the service counted.
public enum MonitoringTime {
    public static func timeZone(offset: String) -> TimeZone {
        guard let seconds = offsetSeconds(offset) else { return .gmt }
        return TimeZone(secondsFromGMT: seconds) ?? .gmt
    }

    /// Strict wire offsets, bounded before arithmetic (the maximum civil offset is 14 hours).
    static func offsetSeconds(_ offset: String) -> Int? {
        let bytes = Array(offset.utf8)
        guard bytes.count == 6, bytes[0] == 43 || bytes[0] == 45, bytes[3] == 58,
              [1, 2, 4, 5].allSatisfy({ (48...57).contains(bytes[$0]) }) else { return nil }
        let hours = Int(bytes[1] - 48) * 10 + Int(bytes[2] - 48)
        let minutes = Int(bytes[4] - 48) * 10 + Int(bytes[5] - 48)
        guard hours <= 14, minutes < 60, hours < 14 || minutes == 0 else { return nil }
        return (bytes[0] == 45 ? -1 : 1) * (hours * 3600 + minutes * 60)
    }

    /// `HH:mm:ss` in the service's offset.
    public static func clock(_ epoch: Double, timezone: String) -> String {
        formatter("HH:mm:ss", timezone: timezone).string(from: Date(timeIntervalSince1970: epoch))
    }

    /// `HH:mm` in the service's offset.
    public static func hourMinute(_ epoch: Double, timezone: String) -> String {
        formatter("HH:mm", timezone: timezone).string(from: Date(timeIntervalSince1970: epoch))
    }

    /// The day and clock, `yyyy-MM-dd HH:mm:ss`, in the service's offset.
    public static func dayClock(_ epoch: Double, timezone: String) -> String {
        formatter("yyyy-MM-dd HH:mm:ss", timezone: timezone).string(from: Date(timeIntervalSince1970: epoch))
    }

    /// An ISO 8601 time as epoch seconds, with or without fractional seconds and an offset.
    public static func epoch(fromISO text: String) -> Double? {
        let candidates = [text, truncatedFraction(text)]
        let formatter = ISO8601DateFormatter()
        for candidate in candidates where !candidate.isEmpty {
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: candidate) { return date.timeIntervalSince1970 }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: candidate) { return date.timeIntervalSince1970 }
        }
        return nil
    }

    /// ISO 8601 keeps at most milliseconds for the parser; the service writes microseconds.
    private static func truncatedFraction(_ text: String) -> String {
        guard let dot = text.firstIndex(of: ".") else { return text }
        var end = text.index(after: dot)
        var digits = 0
        while end < text.endIndex, text[end].isNumber {
            digits += 1
            end = text.index(after: end)
        }
        guard digits > 3 else { return text }
        let cut = text.index(dot, offsetBy: 4)
        return String(text[..<cut]) + String(text[end...])
    }

    private static func formatter(_ format: String, timezone: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone(offset: timezone)
        formatter.dateFormat = format
        return formatter
    }
}
