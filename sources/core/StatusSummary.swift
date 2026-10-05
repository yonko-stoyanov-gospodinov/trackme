import Foundation

/// The numbers the Claude Code status line shows, exported from the app's snapshot after
/// every scan so that `scripts/statusline.sh` can read them without scanning transcripts.
///
/// Customers are keyed by their tag; sessions without a name are under "Other". `sessions`
/// maps a session ID to its customer so the script can find the customer of the session it
/// runs in. Amounts are dollars.
///
/// When the app shows the spend since a day, `total` is the spend from the start of that day
/// instead of the all-time figure, and `since` carries the day's label for the script.
struct StatusSummary: Equatable {
    struct Spend: Equatable {
        var today: Double
        var total: Double
    }

    static let unnamed = "Other"

    var generatedAt: Double
    var since: String?
    var all: Spend
    var customers: [String: Spend]
    var sessions: [String: String]

    /// `sinceStart` is the start of the chosen day in seconds since 1970, `sinceLabel` how
    /// the status line should name it; both nil for the all-time total.
    init(snapshot: Snapshot, sinceStart: Double? = nil, sinceLabel: String? = nil, now: Date = Date()) {
        generatedAt = now.timeIntervalSince1970
        since = sinceStart == nil ? nil : sinceLabel
        func spend(today: Totals, all: Totals, days: [DayTotal]) -> Spend {
            guard let start = sinceStart else { return Spend(today: today.cost, total: all.cost) }
            let total = days.filter { $0.dayStart >= start }.reduce(0.0) { $0 + $1.totals.cost }
            return Spend(today: today.cost, total: total)
        }
        all = spend(today: snapshot.today, all: snapshot.all, days: snapshot.days)
        var customers: [String: Spend] = [:]
        for c in snapshot.customers {
            customers[c.name ?? StatusSummary.unnamed] = spend(today: c.today, all: c.all, days: c.days)
        }
        self.customers = customers
        var sessions: [String: String] = [:]
        for s in snapshot.sessions {
            sessions[s.sessionId] = s.customer ?? StatusSummary.unnamed
        }
        self.sessions = sessions
    }

    /// JSON with sorted keys, so the file only changes when the numbers do.
    func json() throws -> Data {
        func spend(_ s: Spend) -> [String: Any] { return ["today": s.today, "total": s.total] }
        var object: [String: Any] = [
            "generatedAt": generatedAt,
            "all": spend(all),
            "customers": customers.mapValues(spend),
            "sessions": sessions,
        ]
        if let since = since { object["since"] = since }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    func write(to path: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                               withIntermediateDirectories: true, attributes: nil)
        try json().write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
