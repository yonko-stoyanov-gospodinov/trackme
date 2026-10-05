import Foundation

// Foundation on macOS hands back autoreleased objects; without a pool per step, a first scan
// of large transcripts would hold all of them until it finished.
#if canImport(ObjectiveC)
private func pooled(_ body: () -> Void) { autoreleasepool(invoking: body) }
#else
private func pooled(_ body: () -> Void) { body() }
#endif

/// What has been read from one transcript file so far.
final class FileRecord {
    let path: String
    let projectDir: String
    let sessionId: String
    let isSubagentFile: Bool
    var offset = 0                 // bytes consumed (always ends on a line boundary)
    var size = -1
    var modified = 0.0
    var entries: [UsageEntry] = []
    var cwd: String?
    var gitBranch: String?
    var version: String?
    var name: String?
    var title: String?
    var titleRank = 0
    var firstPrompt: String?
    var firstTimestamp: Double?
    var probes = 0                 // non-usage lines parsed while looking for the first prompt

    init(path: String, projectDir: String, sessionId: String, isSubagentFile: Bool) {
        self.path = path
        self.projectDir = projectDir
        self.sessionId = sessionId
        self.isSubagentFile = isSubagentFile
    }

    var sessionKey: String { return projectDir + "/" + sessionId }

    func reset() {
        offset = 0
        entries = []
        cwd = nil
        gitBranch = nil
        version = nil
        name = nil
        title = nil
        titleRank = 0
        firstPrompt = nil
        firstTimestamp = nil
        probes = 0
    }
}

/// Scans Claude Code's transcript folders and keeps a running picture of usage.
/// Not thread-safe: call it from one queue.
final class UsageStore {
    private(set) var priceTable: PriceTable
    private var roots: [String]
    private var files: [String: FileRecord] = [:]
    private var needsRebuild = true
    private var lastTodayStart = 0.0

    /// Gaps longer than this between two responses do not count as active time.
    static let idleGap = 300.0
    private static let maxProbes = 200
    private static let chunkSize = 4 << 20

    init(roots: [String], priceTable: PriceTable) {
        self.roots = roots
        self.priceTable = priceTable
    }

    func setPriceTable(_ table: PriceTable) {
        priceTable = table
        needsRebuild = true
    }

    func setRoots(_ newRoots: [String]) {
        if newRoots == roots { return }
        roots = newRoots
        files = [:]
        needsRebuild = true
    }

    // MARK: Locating transcripts

    /// Claude Code config folders that contain a `projects` folder.
    static func configRoots(environment: [String: String], home: String, override: String?) -> [String] {
        var candidates: [String] = []
        if let o = override, !o.isEmpty {
            candidates = [o]
        } else if let env = environment["CLAUDE_CONFIG_DIR"], !env.isEmpty {
            candidates = env.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        } else {
            let xdg = environment["XDG_CONFIG_HOME"] ?? (home as NSString).appendingPathComponent(".config")
            candidates = [(xdg as NSString).appendingPathComponent("claude"),
                          (home as NSString).appendingPathComponent(".claude")]
        }
        var result: [String] = []
        for candidate in candidates {
            var path = (candidate as NSString).expandingTildeInPath
            if (path as NSString).lastPathComponent == "projects" {
                path = (path as NSString).deletingLastPathComponent
            }
            var isDir: ObjCBool = false
            let projects = (path as NSString).appendingPathComponent("projects")
            if FileManager.default.fileExists(atPath: projects, isDirectory: &isDir), isDir.boolValue, !result.contains(path) {
                result.append(path)
            }
        }
        return result
    }

    /// Maps a path below `projects/` to its project folder and session.
    /// `<project>/<session>.jsonl` is a session; anything nested deeper
    /// (`<project>/<session>/subagents/agent-x.jsonl`) belongs to that session as subagent work.
    static func identify(relativePath: String) -> (projectDir: String, sessionId: String, isSubagent: Bool)? {
        let parts = relativePath.split(separator: "/").map(String.init)
        guard parts.count >= 2, let fileName = parts.last, fileName.hasSuffix(".jsonl") else { return nil }
        let stem = String(fileName.dropLast(6))
        if stem.isEmpty { return nil }
        if parts.count == 2 {
            return (parts[0], stem, stem.hasPrefix("agent-"))
        }
        return (parts[0], parts[1], true)
    }

    // MARK: Refresh

    /// Re-reads whatever changed on disk. Returns nil when nothing changed since the last call.
    func refresh(now: Date = Date(), calendar: Calendar = Calendar.current) -> Snapshot? {
        let fm = FileManager.default
        var seen = Set<String>()

        for root in roots {
            let projects = (root as NSString).appendingPathComponent("projects")
            guard let walker = fm.enumerator(atPath: projects) else { continue }
            while let relative = walker.nextObject() as? String {
                if !relative.hasSuffix(".jsonl") { continue }
                pooled {
                    guard let identity = UsageStore.identify(relativePath: relative) else { return }
                    let path = (projects as NSString).appendingPathComponent(relative)
                    guard let attributes = try? fm.attributesOfItem(atPath: path) else { return }
                    if let kind = attributes[.type] as? FileAttributeType, kind != .typeRegular { return }
                    let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
                    let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                    seen.insert(path)

                    let record: FileRecord
                    if let existing = files[path] {
                        record = existing
                    } else {
                        record = FileRecord(path: path, projectDir: identity.projectDir,
                                            sessionId: identity.sessionId, isSubagentFile: identity.isSubagent)
                        files[path] = record
                    }
                    if record.size == size && record.modified == modified { return }
                    if size < record.offset { record.reset() }
                    record.size = size
                    record.modified = modified
                    read(record)
                    needsRebuild = true
                }
            }
        }

        for path in Array(files.keys) where !seen.contains(path) {
            files[path] = nil
            needsRebuild = true
        }

        let todayStart = calendar.startOfDay(for: now).timeIntervalSince1970
        if todayStart != lastTodayStart { needsRebuild = true }
        if !needsRebuild { return nil }
        needsRebuild = false
        lastTodayStart = todayStart
        return buildSnapshot(now: now, calendar: calendar)
    }

    // MARK: Reading files

    private func read(_ record: FileRecord) {
        guard let handle = FileHandle(forReadingAtPath: record.path) else { return }
        defer { handle.closeFile() }
        // The throwing calls are used because the older ones raise an exception Swift cannot catch.
        guard (try? handle.seek(toOffset: UInt64(record.offset))) != nil else { return }

        var carry = Data()
        var done = false
        while !done {
            pooled {
                let chunk = (try? handle.read(upToCount: UsageStore.chunkSize)) ?? Data()
                if chunk.isEmpty {
                    done = true
                    return
                }
                var buffer: Data
                if carry.isEmpty {
                    buffer = chunk
                } else {
                    buffer = carry
                    buffer.append(chunk)
                }
                let consumed = consumeLines(in: buffer, record: record)
                record.offset += consumed
                carry = consumed < buffer.count ? buffer.subdata(in: consumed..<buffer.count) : Data()
            }
        }

        // A last line without a newline is taken only if it is already complete JSON;
        // otherwise it is still being written and is read again next time.
        pooled {
            if !carry.isEmpty, (try? JSONSerialization.jsonObject(with: carry, options: [])) != nil {
                let count = carry.count
                carry.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    if let base = raw.baseAddress { handleLine(base, count, record) }
                }
                record.offset += count
            }
        }
    }

    /// Handles every complete line in `buffer`; returns the number of bytes consumed.
    private func consumeLines(in buffer: Data, record: FileRecord) -> Int {
        let count = buffer.count
        var consumed = 0
        buffer.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var start = 0
            while start < count {
                guard let hit = memchr(base + start, 10, count - start) else { break }
                let end = base.distance(to: UnsafeRawPointer(hit))
                handleLine(base + start, end - start, record)
                start = end + 1
                consumed = start
            }
        }
        return consumed
    }

    private static let usageNeedle = Array("\"usage\"".utf8)
    private static let titleNeedles = [Array("\"customTitle\":".utf8), Array("\"aiTitle\":".utf8), Array("\"type\":\"summary\"".utf8)]

    private static func contains(_ base: UnsafeRawPointer, _ length: Int, _ needle: [UInt8]) -> Bool {
        let n = needle.count
        if n == 0 || length < n { return false }
        var position = 0
        let last = length - n
        while position <= last {
            guard let hit = memchr(base + position, Int32(needle[0]), last - position + 1) else { return false }
            let index = base.distance(to: UnsafeRawPointer(hit))
            if memcmp(base + index, needle, n) == 0 { return true }
            position = index + 1
        }
        return false
    }

    private func handleLine(_ base: UnsafeRawPointer, _ length: Int, _ record: FileRecord) {
        if length < 2 { return }
        // Parsing every line would be slow on large transcripts, so only lines that can
        // matter are decoded: ones with usage, title lines, and the first few lines of a
        // file while looking for the opening prompt.
        let hasUsage = UsageStore.contains(base, length, UsageStore.usageNeedle)
        if !hasUsage {
            var wanted = false
            if record.firstPrompt == nil && record.probes < UsageStore.maxProbes {
                record.probes += 1
                wanted = true
            } else {
                for needle in UsageStore.titleNeedles where UsageStore.contains(base, length, needle) {
                    wanted = true
                    break
                }
            }
            if !wanted { return }
        }

        let data = Data(bytes: base, count: length)
        var decoded: [String: Any]?
        pooled { decoded = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] }
        guard let object = decoded else { return }

        if let s = object["cwd"] as? String, !s.isEmpty { record.cwd = s }
        if let s = object["gitBranch"] as? String, !s.isEmpty { record.gitBranch = s }
        if let s = object["version"] as? String, !s.isEmpty { record.version = s }
        if let s = object["customTitle"] as? String, !s.isEmpty { record.name = s }
        if record.firstTimestamp == nil, let s = object["timestamp"] as? String {
            record.firstTimestamp = TranscriptParser.parseTimestamp(s)
        }
        if let found = TranscriptParser.title(from: object), found.rank >= record.titleRank {
            record.title = found.text
            record.titleRank = found.rank
        }
        if record.firstPrompt == nil, let prompt = TranscriptParser.promptText(from: object) {
            record.firstPrompt = prompt
        }
        if hasUsage, (object["type"] as? String) == "assistant",
           let entry = TranscriptParser.usageEntry(from: object, sessionKey: record.sessionKey,
                                                   fileIsSidechain: record.isSubagentFile) {
            record.entries.append(entry)
        }
    }

    // MARK: Aggregation

    /// When the same response appears twice (streaming writes several lines per response, and
    /// resumed sessions can replay history), keep the main-thread copy, then the fuller one.
    static func shouldReplace(existing: UsageEntry, with candidate: UsageEntry) -> Bool {
        if candidate.isSidechain != existing.isSidechain { return existing.isSidechain }
        if candidate.tokens.total != existing.tokens.total { return candidate.tokens.total > existing.tokens.total }
        return candidate.fast && !existing.fast
    }

    private final class SessionBuilder {
        var summary: SessionSummary
        var models: [String: ModelUsage] = [:]
        var times: [Double] = []
        var hasMainFile = false
        var titleRank = -1
        init(summary: SessionSummary) { self.summary = summary }
    }

    private func buildSnapshot(now: Date, calendar: Calendar) -> Snapshot {
        // Oldest files first, so a replayed response stays with the session it first ran in.
        let records = files.values.sorted { a, b in
            let ta = a.firstTimestamp ?? Double.greatestFiniteMagnitude
            let tb = b.firstTimestamp ?? Double.greatestFiniteMagnitude
            if ta != tb { return ta < tb }
            return a.path < b.path
        }

        var winners: [(record: FileRecord, entry: UsageEntry)] = []
        var indexByKey: [String: Int] = [:]
        for record in records {
            for entry in record.entries {
                if let key = entry.dedupKey {
                    if let index = indexByKey[key] {
                        if UsageStore.shouldReplace(existing: winners[index].entry, with: entry) {
                            winners[index] = (record, entry)
                        }
                        continue
                    }
                    indexByKey[key] = winners.count
                }
                winners.append((record, entry))
            }
        }

        var builders: [String: SessionBuilder] = [:]
        func builder(for record: FileRecord) -> SessionBuilder {
            if let b = builders[record.sessionKey] { return b }
            let b = SessionBuilder(summary: SessionSummary(id: record.sessionKey, sessionId: record.sessionId,
                                                           projectDir: record.projectDir))
            builders[record.sessionKey] = b
            return b
        }

        // Labels come from the session's own file; subagent files only fill gaps.
        for record in records where !record.entries.isEmpty || !record.isSubagentFile {
            let b = builder(for: record)
            let main = !record.isSubagentFile
            if main { b.hasMainFile = true }
            if main || b.summary.cwd == nil { if let v = record.cwd { b.summary.cwd = v } }
            if main || b.summary.gitBranch == nil { if let v = record.gitBranch { b.summary.gitBranch = v } }
            if main || b.summary.version == nil { if let v = record.version { b.summary.version = v } }
            if main || b.summary.name == nil { if let v = record.name { b.summary.name = v } }
            if main {
                b.summary.transcriptPath = record.path
                if let t = record.title, record.titleRank > b.titleRank {
                    b.summary.title = t
                    b.titleRank = record.titleRank
                }
                if let p = record.firstPrompt { b.summary.firstPrompt = p }
                if let t = record.firstTimestamp { b.summary.start = t }
            } else if b.summary.transcriptPath == nil {
                b.summary.transcriptPath = record.path
            }
        }

        var dayTotals: [Double: Totals] = [:]
        var customerDayTotals: [String?: [Double: Totals]] = [:]
        var dayStart = 0.0
        var dayEnd = 0.0
        var unpriced = Set<String>()
        var all = Totals()

        for winner in winners {
            let entry = winner.entry
            let b = builder(for: winner.record)
            let parts = priceTable.cost(of: entry)
            let cost = parts?.total ?? 0

            b.summary.requests += 1
            b.summary.tokens.add(entry.tokens)
            if let p = parts { b.summary.costParts.add(p) }
            if parts == nil {
                b.summary.hasUnpriced = true
                unpriced.insert(entry.model)
            }
            if entry.isSidechain {
                b.summary.subagentRequests += 1
                b.summary.subagentTokens += entry.tokens.total
                b.summary.subagentCost += cost
            }
            var usage = b.models[entry.model] ?? ModelUsage(model: entry.model,
                                                            displayName: priceTable.displayName(for: entry.model))
            usage.requests += 1
            usage.tokens.add(entry.tokens)
            usage.cost += cost
            if parts == nil { usage.priced = false }
            b.models[entry.model] = usage
            b.times.append(entry.timestamp)

            // Days are local calendar days; the bounds are cached because entries cluster in time.
            if entry.timestamp < dayStart || entry.timestamp >= dayEnd {
                let date = Date(timeIntervalSince1970: entry.timestamp)
                let start = calendar.startOfDay(for: date)
                dayStart = start.timeIntervalSince1970
                dayEnd = (calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)).timeIntervalSince1970
            }
            var totals = dayTotals[dayStart] ?? Totals()
            totals.cost += cost
            totals.tokens += entry.tokens.total
            totals.requests += 1
            dayTotals[dayStart] = totals

            let customer = b.summary.customer
            var customerTotals = customerDayTotals[customer]?[dayStart] ?? Totals()
            customerTotals.cost += cost
            customerTotals.tokens += entry.tokens.total
            customerTotals.requests += 1
            customerDayTotals[customer, default: [:]][dayStart] = customerTotals

            all.cost += cost
            all.tokens += entry.tokens.total
            all.requests += 1
        }

        var sessions: [SessionSummary] = []
        for b in builders.values where b.summary.requests > 0 {
            let times = b.times.sorted()
            var summary = b.summary
            if let first = times.first, let last = times.last {
                if summary.start == 0 || summary.start > first { summary.start = first }
                summary.end = last
            }
            var active = 0.0
            if times.count > 1 {
                for i in 1..<times.count { active += min(times[i] - times[i - 1], UsageStore.idleGap) }
            }
            summary.activeSeconds = active
            summary.models = b.models.values.sorted { a, c in
                if a.cost != c.cost { return a.cost > c.cost }
                return a.model < c.model
            }
            sessions.append(summary)
        }
        sessions.sort { a, b in
            if a.end != b.end { return a.end > b.end }
            return a.id < b.id
        }

        var snapshot = Snapshot()
        snapshot.sessions = sessions
        snapshot.days = dayTotals.keys.sorted().map { DayTotal(dayStart: $0, totals: dayTotals[$0] ?? Totals()) }
        snapshot.all = all
        snapshot.unpricedModels = unpriced.sorted()
        snapshot.fileCount = files.count
        snapshot.roots = roots
        snapshot.generatedAt = now.timeIntervalSince1970

        let today = calendar.startOfDay(for: now)
        snapshot.todayStart = today.timeIntervalSince1970
        let weekStart = (calendar.date(byAdding: .day, value: -6, to: today) ?? today).timeIntervalSince1970
        let monthStart = (calendar.date(byAdding: .day, value: -29, to: today) ?? today).timeIntervalSince1970
        let ranges = UsageStore.rangeTotals(of: snapshot.days, todayStart: snapshot.todayStart,
                                            weekStart: weekStart, monthStart: monthStart)
        snapshot.today = ranges.today
        snapshot.last7 = ranges.last7
        snapshot.last30 = ranges.last30

        for (name, byDay) in customerDayTotals {
            var customer = CustomerTotals(name: name)
            customer.days = byDay.keys.sorted().map { DayTotal(dayStart: $0, totals: byDay[$0] ?? Totals()) }
            let sums = UsageStore.rangeTotals(of: customer.days, todayStart: snapshot.todayStart,
                                              weekStart: weekStart, monthStart: monthStart)
            customer.today = sums.today
            customer.last7 = sums.last7
            customer.last30 = sums.last30
            customer.all = sums.all
            snapshot.customers.append(customer)
        }
        snapshot.customers.sort { a, b in
            switch (a.name, b.name) {
            case (nil, _): return false
            case (_, nil): return true
            case let (x?, y?):
                if a.all.cost != b.all.cost { return a.all.cost > b.all.cost }
                return x < y
            }
        }
        return snapshot
    }

    private static func rangeTotals(of days: [DayTotal], todayStart: Double, weekStart: Double,
                                    monthStart: Double) -> (today: Totals, last7: Totals, last30: Totals, all: Totals) {
        var today = Totals(), last7 = Totals(), last30 = Totals(), all = Totals()
        for day in days {
            func add(_ into: inout Totals) {
                into.cost += day.totals.cost
                into.tokens += day.totals.tokens
                into.requests += day.totals.requests
            }
            add(&all)
            if day.dayStart >= todayStart { add(&today) }
            if day.dayStart >= weekStart { add(&last7) }
            if day.dayStart >= monthStart { add(&last30) }
        }
        return (today, last7, last30, all)
    }
}
