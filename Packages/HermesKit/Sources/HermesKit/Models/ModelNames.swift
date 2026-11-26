import Foundation

/// Human names for model ids: `anthropic/claude-sonnet-4.6` → "Claude Sonnet 4.6".
public enum ModelNames {
    public static func display(_ id: String) -> String {
        let last = id.split(separator: "/").last.map(String.init) ?? id
        let words = last.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { word -> String in
            let lower = word.lowercased()
            if ["gpt", "glm", "ai"].contains(lower) { return lower.uppercased() }
            if word.first?.isNumber == true { return String(word) }
            return word.prefix(1).uppercased() + word.dropFirst()
        }
        return words.joined(separator: " ")
    }
}

/// The names the reasoning ladder shows: "Off", "Minimal", "Low", "Medium", "High", "Extra High",
/// "Max". One place, so the chip, the picker and `/reasoning` say them the same.
public enum ReasoningNames {
    public static func title(for level: ReasoningEffort) -> String {
        switch level {
        case .off: String(localized: "Off")
        case .minimal: String(localized: "Minimal")
        case .low: String(localized: "Low")
        case .medium: String(localized: "Medium")
        case .high: String(localized: "High")
        case .xhigh: String(localized: "Extra High")
        case .max: String(localized: "Max")
        }
    }
}
