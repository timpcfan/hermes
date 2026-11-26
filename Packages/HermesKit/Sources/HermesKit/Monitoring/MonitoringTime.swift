import Foundation

/// Server times are business times: epoch seconds rendered in the service's own UTC offset
/// (`timezone` in the snapshot), not the phone's. A person checking a Chinese link from another
/// country still sees the day the service counted.
public enum MonitoringTime {
    public static func timeZone(offset: String) -> TimeZone {
        let trimmed = offset.trimmingCharacters(in: .whitespaces)
        let sign: Int
        switch trimmed.first {
        case "+": sign = 1
        case "-": sign = -1
        default: return TimeZone(secondsFromGMT: 0) ?? .gmt
        }
        let digits = trimmed.dropFirst()
        let parts = digits.split(separator: ":")
        guard let hours = Int(parts.first ?? "0") else { return TimeZone(secondsFromGMT: 0) ?? .gmt }
        let minutes = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        return TimeZone(secondsFromGMT: sign * (hours * 3600 + minutes * 60)) ?? TimeZone(secondsFromGMT: 0) ?? .gmt
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
