import Foundation

/// Text formatting shared by the menu bar title and the popover.
enum Format {
    static func money(_ value: Double) -> String {
        if value > 0 && value < 0.005 { return "<$0.01" }
        if value >= 1000 { return "$" + grouped(Int(value.rounded())) }
        return "$" + String(format: "%.2f", value)
    }

    static func grouped(_ value: Int) -> String {
        let digits = String(abs(value))
        var out = ""
        for (i, ch) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return (value < 0 ? "-" : "") + out
    }

    static func tokens(_ value: Int) -> String {
        let v = Double(value)
        if value >= 1_000_000_000 { return trimmed(v / 1_000_000_000) + "B" }
        if value >= 1_000_000 { return trimmed(v / 1_000_000) + "M" }
        if value >= 1_000 { return trimmed(v / 1_000) + "K" }
        return String(value)
    }

    private static func trimmed(_ value: Double) -> String {
        if value >= 100 { return String(format: "%.0f", value) }
        let s = String(format: "%.1f", value)
        return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(max(total, 0))s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d \(hours % 24)h"
    }

    static func percent(_ fraction: Double) -> String {
        return String(format: "%.0f%%", fraction * 100)
    }
}
