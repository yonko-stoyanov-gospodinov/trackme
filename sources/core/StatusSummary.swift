import Foundation

/// The numbers the Claude Code status line shows, exported from the app's snapshot after
/// every scan so that `scripts/statusline.sh` can read them without scanning transcripts.
///
/// Customers are keyed by their tag; sessions without a name are under "Other". `sessions`
/// maps a session ID to its customer so the script can find the customer of the session it
/// runs in. Amounts are dollars.
struct StatusSummary: Equatable {
    struct Spend: Equatable {
        var today: Double
        var total: Double
    }

    static let unnamed = "Other"

    var generatedAt: Double
    var all: Spend
    var customers: [String: Spend]
    var sessions: [String: String]

    init(snapshot: Snapshot, now: Date = Date()) {
        generatedAt = now.timeIntervalSince1970
        all = Spend(today: snapshot.today.cost, total: snapshot.all.cost)
        var customers: [String: Spend] = [:]
        for c in snapshot.customers {
            customers[c.name ?? StatusSummary.unnamed] = Spend(today: c.today.cost, total: c.all.cost)
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
        let object: [String: Any] = [
            "generatedAt": generatedAt,
            "all": spend(all),
            "customers": customers.mapValues(spend),
            "sessions": sessions,
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    func write(to path: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                               withIntermediateDirectories: true, attributes: nil)
        try json().write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
