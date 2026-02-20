import Foundation

// MARK: - Usage Level (UI-agnostic color threshold)

/// Semantic usage level, mapped to colors in the view layer.
/// Keeps the library free of SwiftUI dependency.
public enum UsageLevel: Sendable, Equatable {
    case green   // 0–50%
    case yellow  // 50–80%
    case orange  // 80–90%
    case red     // 90%+
}

/// Returns the usage level for a percentage.
/// Green 0–50%, yellow 50–80%, orange 80–90%, red 90%+.
public func usageLevel(for percentage: Double) -> UsageLevel {
    switch percentage {
    case 90...: return .red
    case 80..<90: return .orange
    case 50..<80: return .yellow
    default: return .green
    }
}

// MARK: - Time Formatting

/// Format seconds-until-reset as a human-readable string.
/// - ≤ 0  → "now"
/// - < 90 min → "N min"
/// - < 24 hrs → "Nh Mm"
/// - ≥ 24 hrs → "Nd Nh"
public func formatResetTime(seconds: Int) -> String {
    if seconds <= 0 { return "now" }

    let minutes = seconds / 60
    let hours = seconds / 3600
    let days = seconds / 86400

    if minutes < 90 {
        return "\(max(1, minutes)) min"
    } else if hours < 24 {
        let remainingMinutes = (seconds % 3600) / 60
        return "\(hours)h \(remainingMinutes)m"
    } else {
        let remainingHours = (seconds % 86400) / 3600
        return "\(days)d \(remainingHours)h"
    }
}

/// Format a future reset Date relative to now.
public func formatResetTime(from date: Date, now: Date = Date()) -> String {
    let seconds = Int(date.timeIntervalSince(now))
    return formatResetTime(seconds: seconds)
}

/// Format a past Date as a human-readable "time ago" string.
/// Returns the full phrase: "just now", "3 min ago", "2h 14m ago".
public func formatTimeAgo(from date: Date, now: Date = Date()) -> String {
    let seconds = Int(now.timeIntervalSince(date))
    if seconds < 60 { return "just now" }
    return "\(formatResetTime(seconds: seconds)) ago"
}

// MARK: - Menu Bar Label

/// Compute the menu bar label string from usage state.
/// - Normal: "37%"
/// - Orange zone (≥80%): "85%!"
/// - Red zone (≥90%): "95%!!"
/// - No data: "--%"
/// - Error with no data: "!!"
public func formatMenuBarLabel(
    utilization: Double?,
    hasError: Bool,
    hasData: Bool
) -> String {
    if let utilization, hasData {
        let pct = Int(utilization)
        let suffix: String
        if utilization >= 90 {
            suffix = "!!"
        } else if utilization >= 80 {
            suffix = "!"
        } else {
            suffix = ""
        }
        return "\(pct)%\(suffix)"
    }
    if hasError { return "!!" }
    return "--%"
}

// MARK: - Credits Formatting

/// Convert a cents value (Double) to a display dollar string.
/// Examples: 1250.0 → "$12.50", 0.0 → "$0.00"
public func formatCredits(_ cents: Double) -> String {
    String(format: "$%.2f", cents / 100.0)
}
