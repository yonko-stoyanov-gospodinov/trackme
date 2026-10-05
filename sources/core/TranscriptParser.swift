import Foundation

/// Reads the fields this app needs out of one transcript line.
/// The transcript format is internal to Claude Code, so every field is treated as optional.
enum TranscriptParser {

    static func int(_ value: Any?) -> Int {
        if let i = value as? Int { return max(0, i) }
        if let d = value as? Double { return d > 0 ? Int(d) : 0 }
        if let n = value as? NSNumber { return max(0, n.intValue) }
        return 0
    }

    static func double(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }

    // MARK: Timestamps

    /// Parses "2026-10-01T10:00:00.123Z" (the form Claude Code writes) without a date formatter,
    /// and falls back to ISO8601DateFormatter for anything else.
    static func parseTimestamp(_ string: String) -> Double? {
        if let fast = fastTimestamp(Array(string.utf8)) { return fast }
        if let d = isoFractional.date(from: string) { return d.timeIntervalSince1970 }
        if let d = isoPlain.date(from: string) { return d.timeIntervalSince1970 }
        return nil
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func fastTimestamp(_ b: [UInt8]) -> Double? {
        if b.count < 20 { return nil }
        func digits(_ from: Int, _ count: Int) -> Int? {
            var value = 0
            for i in from..<(from + count) {
                let c = Int(b[i]) - 48
                if c < 0 || c > 9 { return nil }
                value = value * 10 + c
            }
            return value
        }
        guard b[4] == 45, b[7] == 45, b[10] == 84 || b[10] == 116, b[13] == 58, b[16] == 58 else { return nil }
        guard let year = digits(0, 4), let month = digits(5, 2), let day = digits(8, 2),
              let hour = digits(11, 2), let minute = digits(14, 2), let second = digits(17, 2) else { return nil }
        if month < 1 || month > 12 || day < 1 || day > 31 || hour > 23 || minute > 59 || second > 60 { return nil }

        var index = 19
        var fraction = 0.0
        if b[index] == 46 {
            index += 1
            var scale = 0.1
            while index < b.count {
                let c = Int(b[index]) - 48
                if c < 0 || c > 9 { break }
                fraction += Double(c) * scale
                scale /= 10
                index += 1
            }
        }
        if index >= b.count { return nil }

        var offsetSeconds = 0
        let zone = b[index]
        if zone == 90 || zone == 122 {
            if index + 1 != b.count { return nil }
        } else if zone == 43 || zone == 45 {
            // +hh:mm or -hh:mm
            if index + 6 != b.count || b[index + 3] != 58 { return nil }
            guard let zh = digits(index + 1, 2), let zm = digits(index + 4, 2) else { return nil }
            offsetSeconds = (zh * 3600 + zm * 60) * (zone == 43 ? 1 : -1)
        } else {
            return nil
        }

        let days = daysFromCivil(year: year, month: month, day: day)
        let seconds = days * 86400 + hour * 3600 + minute * 60 + second - offsetSeconds
        return Double(seconds) + fraction
    }

    /// Days since 1970-01-01 for a proleptic Gregorian date.
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    // MARK: Usage

    /// Returns the usage recorded on an assistant line, or nil when the line carries none.
    static func usageEntry(from object: [String: Any], sessionKey: String, fileIsSidechain: Bool) -> UsageEntry? {
        guard let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else { return nil }
        let model = (message["model"] as? String) ?? "unknown"
        if model == "<synthetic>" { return nil }
        guard let stamp = object["timestamp"] as? String, let time = parseTimestamp(stamp) else { return nil }

        var tokens = TokenCounts()
        tokens.input = int(usage["input_tokens"])
        tokens.output = int(usage["output_tokens"])
        tokens.cacheRead = int(usage["cache_read_input_tokens"])
        let cacheCreation = int(usage["cache_creation_input_tokens"])
        if let split = usage["cache_creation"] as? [String: Any] {
            tokens.cacheWrite5m = int(split["ephemeral_5m_input_tokens"])
            tokens.cacheWrite1h = int(split["ephemeral_1h_input_tokens"])
            if tokens.cacheWrite == 0 { tokens.cacheWrite5m = cacheCreation }
        } else {
            tokens.cacheWrite5m = cacheCreation
        }
        if let tools = usage["server_tool_use"] as? [String: Any] {
            tokens.webSearches = int(tools["web_search_requests"])
        }
        if tokens.total == 0 && tokens.webSearches == 0 { return nil }

        var key: String?
        if let messageId = message["id"] as? String, !messageId.isEmpty {
            if let requestId = object["requestId"] as? String, !requestId.isEmpty {
                key = messageId + "|" + requestId
            } else {
                key = messageId + "||" + sessionKey + "|" + stamp
            }
        }

        return UsageEntry(
            timestamp: time,
            model: model,
            tokens: tokens,
            fast: (usage["speed"] as? String) == "fast",
            recordedCost: double(object["costUSD"]),
            isSidechain: fileIsSidechain || (object["isSidechain"] as? Bool) == true,
            dedupKey: key
        )
    }

    // MARK: Titles and prompts

    /// The first thing the person typed, cleaned up for use as a session label.
    static func promptText(from object: [String: Any]) -> String? {
        guard (object["type"] as? String) == "user" else { return nil }
        if (object["isMeta"] as? Bool) == true { return nil }
        guard let message = object["message"] as? [String: Any] else { return nil }
        var text: String?
        if let s = message["content"] as? String {
            text = s
        } else if let blocks = message["content"] as? [[String: Any]] {
            for block in blocks {
                if (block["type"] as? String) == "text", let s = block["text"] as? String {
                    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty && !trimmed.hasPrefix("<") {
                        text = s
                        break
                    }
                }
            }
        }
        guard let raw = text else { return nil }
        let collapsed = raw.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }).joined(separator: " ")
        // Slash commands, command output and injected reminders start with a tag.
        if collapsed.isEmpty || collapsed.hasPrefix("<") || collapsed.hasPrefix("Caveat:") { return nil }
        if collapsed.count > 140 { return String(collapsed.prefix(140)) + "…" }
        return collapsed
    }

    /// Session title lines. Returns the title and how much to trust it (higher wins).
    static func title(from object: [String: Any]) -> (text: String, rank: Int)? {
        if let s = object["customTitle"] as? String, !s.isEmpty { return (s, 3) }
        if let s = object["aiTitle"] as? String, !s.isEmpty { return (s, 2) }
        if (object["type"] as? String) == "summary", let s = object["summary"] as? String, !s.isEmpty { return (s, 1) }
        return nil
    }
}
