import Foundation

/// Token counts for one API response, or a sum of many.
struct TokenCounts: Equatable {
    var input = 0
    var output = 0
    var cacheWrite5m = 0
    var cacheWrite1h = 0
    var cacheRead = 0
    var webSearches = 0

    var cacheWrite: Int { return cacheWrite5m + cacheWrite1h }
    var total: Int { return input + output + cacheWrite + cacheRead }

    /// Share of prompt tokens that were served from the prompt cache (0...1).
    var cacheHitRate: Double? {
        let prompt = input + cacheWrite + cacheRead
        if prompt == 0 { return nil }
        return Double(cacheRead) / Double(prompt)
    }

    mutating func add(_ other: TokenCounts) {
        input += other.input
        output += other.output
        cacheWrite5m += other.cacheWrite5m
        cacheWrite1h += other.cacheWrite1h
        cacheRead += other.cacheRead
        webSearches += other.webSearches
    }
}

/// Dollar cost split by what was paid for.
struct CostParts: Equatable {
    var input = 0.0
    var output = 0.0
    var cacheWrite = 0.0
    var cacheRead = 0.0
    var other = 0.0

    var total: Double { return input + output + cacheWrite + cacheRead + other }

    mutating func add(_ o: CostParts) {
        input += o.input
        output += o.output
        cacheWrite += o.cacheWrite
        cacheRead += o.cacheRead
        other += o.other
    }
}

/// One API response recorded in a transcript.
struct UsageEntry {
    var timestamp: Double          // seconds since 1970
    var model: String
    var tokens: TokenCounts
    var fast: Bool
    var recordedCost: Double?      // costUSD written by older Claude Code versions
    var isSidechain: Bool
    var dedupKey: String?
}

struct ModelUsage: Equatable {
    var model: String              // raw model id
    var displayName: String
    var requests = 0
    var tokens = TokenCounts()
    var cost = 0.0
    var priced = true
}

struct SessionSummary: Identifiable, Equatable {
    var id: String                 // "<project dir>/<session id>"
    var sessionId: String
    var projectDir: String
    var cwd: String?
    var gitBranch: String?
    var name: String?              // set with `claude --name` or /rename
    var title: String?
    var firstPrompt: String?
    var version: String?
    var transcriptPath: String?
    var start = 0.0
    var end = 0.0
    var activeSeconds = 0.0
    var requests = 0
    var tokens = TokenCounts()
    var costParts = CostParts()
    var models: [ModelUsage] = []
    var subagentRequests = 0
    var subagentTokens = 0
    var subagentCost = 0.0
    var hasUnpriced = false

    var cost: Double { return costParts.total }

    /// Who the session was for, taken from its name; nil when it has no name.
    var customer: String? { return Customer.tag(from: name) }

    /// Folder name of the project the session ran in.
    var projectName: String {
        if let c = cwd, !c.isEmpty {
            let name = (c as NSString).lastPathComponent
            if !name.isEmpty { return name }
        }
        // Claude Code names the folder after the path with separators replaced by "-".
        let parts = projectDir.split(separator: "-")
        if let last = parts.last { return String(last) }
        return projectDir
    }

    var displayTitle: String {
        if let t = title, !t.isEmpty { return t }
        if let p = firstPrompt, !p.isEmpty { return p }
        return "Session " + String(sessionId.prefix(8))
    }
}

struct Totals: Equatable {
    var cost = 0.0
    var tokens = 0
    var requests = 0
}

struct DayTotal: Equatable {
    var dayStart: Double
    var totals: Totals
}

/// Sessions are grouped by the part of their name before the first colon, so a start
/// script can run `claude --name "Acme"` and a later `/rename` to "Acme: billing" keeps
/// the session with Acme.
enum Customer {
    static func tag(from name: String?) -> String? {
        guard let name = name else { return nil }
        let head = name.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let tag = head.trimmingCharacters(in: .whitespacesAndNewlines)
        return tag.isEmpty ? nil : tag
    }
}

/// Usage of one customer; `name` is nil for sessions without a name.
struct CustomerTotals: Equatable {
    var name: String?
    var days: [DayTotal] = []      // ascending, only days with usage
    var today = Totals()
    var last7 = Totals()
    var last30 = Totals()
    var all = Totals()
}

/// Everything the interface shows, computed in one pass.
struct Snapshot: Equatable {
    var sessions: [SessionSummary] = []
    var days: [DayTotal] = []      // ascending, only days with usage
    var today = Totals()
    var last7 = Totals()
    var last30 = Totals()
    var all = Totals()
    var customers: [CustomerTotals] = []   // highest all-time spend first; unnamed last
    var todayStart = 0.0
    var unpricedModels: [String] = []
    var fileCount = 0
    var roots: [String] = []
    var generatedAt = 0.0
}
