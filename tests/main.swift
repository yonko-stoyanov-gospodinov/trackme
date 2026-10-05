import Foundation

// Engine tests. They run on any platform with a Swift compiler: ./tests/run.sh

var failures = 0
var checks = 0

func check(_ condition: @autoclosure () -> Bool, _ label: String, line: Int = #line) {
    checks += 1
    if !condition() {
        failures += 1
        print("FAIL line \(line): \(label)")
    }
}

func close(_ a: Double, _ b: Double, _ label: String, line: Int = #line) {
    checks += 1
    if abs(a - b) > 1e-9 {
        failures += 1
        print("FAIL line \(line): \(label): got \(a), expected \(b)")
    }
}

// MARK: Fixture helpers

let fm = FileManager.default
let root = NSTemporaryDirectory() + "trackme-tests-\(ProcessInfo.processInfo.processIdentifier)"
try? fm.removeItem(atPath: root)

func write(_ relative: String, _ lines: [String], terminated: Bool = true) {
    let path = root + "/" + relative
    try! fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    let text = lines.joined(separator: "\n") + (terminated ? "\n" : "")
    try! text.write(toFile: path, atomically: false, encoding: .utf8)
}

func append(_ relative: String, _ text: String) {
    let handle = FileHandle(forWritingAtPath: root + "/" + relative)!
    handle.seekToEndOfFile()
    handle.write(text.data(using: .utf8)!)
    handle.closeFile()
}

func assistant(id: String, request: String?, model: String, time: String, usage: String,
               sidechain: Bool = false, extra: String = "") -> String {
    let req = request.map { "\"requestId\":\"\($0)\"," } ?? ""
    return "{\"type\":\"assistant\",\"timestamp\":\"\(time)\",\(req)\"sessionId\":\"s\",\"cwd\":\"/Users/me/code/webapp\",\"gitBranch\":\"main\",\"version\":\"2.1.300\",\"isSidechain\":\(sidechain)\(extra),\"message\":{\"id\":\"\(id)\",\"model\":\"\(model)\",\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"the \\\"usage\\\" word in text\"}],\"usage\":\(usage)}}"
}

let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()
let now = Date(timeIntervalSince1970: TranscriptParser.parseTimestamp("2026-10-02T12:00:00Z")!)

// MARK: Timestamps

do {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    for s in ["2026-10-01T10:00:00.123Z", "2024-02-29T23:59:59.999Z", "1999-12-31T00:00:00.000Z", "2026-03-01T05:06:07.5Z"] {
        let expected = iso.date(from: s.replacingOccurrences(of: ".5Z", with: ".500Z"))!.timeIntervalSince1970
        close(TranscriptParser.parseTimestamp(s) ?? -1, expected, "timestamp \(s)")
    }
    close(TranscriptParser.parseTimestamp("2026-10-01T10:00:00Z")!, 1790848800, "no fraction")
    close(TranscriptParser.parseTimestamp("2026-10-01T13:00:00+03:00")!, 1790848800, "positive offset")
    close(TranscriptParser.parseTimestamp("2026-10-01T05:30:00-04:30")!, 1790848800, "negative offset")
    check(TranscriptParser.parseTimestamp("yesterday") == nil, "garbage timestamp")
    check(TranscriptParser.parseTimestamp("2026-13-01T10:00:00Z") == nil, "month 13")
}

// MARK: Prices

do {
    let table = PriceTable.builtIn()
    let expect: [(String, String?)] = [
        ("claude-opus-5-5", "Opus 5.5"),
        ("claude-opus-5", "Opus 5"),
        ("claude-opus-5-20260301", "Opus 5"),
        ("claude-opus-5-7", nil),
        ("claude-opus-4-9", nil),
        ("claude-opus-4-1-20250805", "Opus 4.1"),
        ("claude-opus-4-20250514", "Opus 4"),
        ("claude-opus-4-8", "Opus 4.8"),
        ("claude-haiku-4-5-20251001", "Haiku 4.5"),
        ("us.anthropic.claude-sonnet-4-5-20250929-v1:0", "Sonnet 4.5"),
        ("claude-sonnet-4-5[1m]", "Sonnet 4.5"),
        ("claude-sonnet-4-20250514", "Sonnet 4"),
        ("claude-sonnet-5-5", "Sonnet 5.5"),
        ("claude-sonnet-5", "Sonnet 5"),
        ("claude-3-5-haiku-20241022", "Haiku 3.5"),
        ("claude-fable-5-1", "Fable 5.1"),
        ("claude-fable-5", "Fable 5"),
        ("claude-mythos-5-1", "Mythos 5.1"),
        ("gpt-4o", nil),
    ]
    for (model, name) in expect {
        check(table.price(for: model)?.name == name, "price match \(model) -> \(name ?? "nil"), got \(table.price(for: model)?.name ?? "nil")")
    }
    check(table.file.models.count == 19, "19 models in built-in table")
    // Cache prices follow the documented multipliers of the input price.
    for p in table.file.models {
        close(p.cacheWrite5m, p.input * 1.25, "\(p.name) 5m write = 1.25x input")
        close(p.cacheWrite1h, p.input * 2, "\(p.name) 1h write = 2x input")
        close(p.output, p.input * 5, "\(p.name) output = 5x input")
    }
}

// MARK: Paths

do {
    let a = UsageStore.identify(relativePath: "-Users-me-code-webapp/aaaa1111.jsonl")
    check(a?.projectDir == "-Users-me-code-webapp" && a?.sessionId == "aaaa1111" && a?.isSubagent == false, "session path")
    let b = UsageStore.identify(relativePath: "-Users-me-code-webapp/aaaa1111/subagents/agent-1.jsonl")
    check(b?.sessionId == "aaaa1111" && b?.isSubagent == true, "subagent path")
    let c = UsageStore.identify(relativePath: "p/agent-abc.jsonl")
    check(c?.sessionId == "agent-abc" && c?.isSubagent == true, "legacy flat agent file")
    check(UsageStore.identify(relativePath: "p/notes.txt") == nil, "non-jsonl ignored")
    check(UsageStore.identify(relativePath: "stray.jsonl") == nil, "file outside a project ignored")

    try! fm.createDirectory(atPath: root + "/cfg/projects", withIntermediateDirectories: true)
    try! fm.createDirectory(atPath: root + "/home/.claude/projects", withIntermediateDirectories: true)
    check(UsageStore.configRoots(environment: [:], home: root + "/home", override: nil) == [root + "/home/.claude"], "default root")
    check(UsageStore.configRoots(environment: ["CLAUDE_CONFIG_DIR": root + "/cfg"], home: root + "/home", override: nil) == [root + "/cfg"], "env root")
    check(UsageStore.configRoots(environment: ["CLAUDE_CONFIG_DIR": root + "/cfg/projects, " + root + "/missing"], home: root + "/home", override: nil) == [root + "/cfg"], "env root given as projects dir")
    check(UsageStore.configRoots(environment: [:], home: root + "/home", override: root + "/cfg") == [root + "/cfg"], "override root")
    check(UsageStore.configRoots(environment: [:], home: root + "/nowhere", override: nil).isEmpty, "no roots")
}

// MARK: Scanning and totals

let mainA = "data/projects/-Users-me-code-webapp/aaaa1111.jsonl"
let subA = "data/projects/-Users-me-code-webapp/aaaa1111/subagents/agent-1.jsonl"
let mainB = "data/projects/-Users-me-code-api/bbbb2222.jsonl"
let opus = "claude-opus-5-5"

let msg1Final = assistant(id: "msg_1", request: "req_1", model: opus, time: "2026-10-01T10:00:06.000Z",
    usage: "{\"input_tokens\":100,\"output_tokens\":500,\"cache_creation_input_tokens\":1000,\"cache_read_input_tokens\":0,\"cache_creation\":{\"ephemeral_5m_input_tokens\":1000,\"ephemeral_1h_input_tokens\":0}}")

write(mainA, [
    "{\"type\":\"user\",\"isMeta\":true,\"timestamp\":\"2026-10-01T10:00:00.000Z\",\"message\":{\"role\":\"user\",\"content\":\"Caveat: generated\"}}",
    "{\"type\":\"user\",\"timestamp\":\"2026-10-01T10:00:00.500Z\",\"cwd\":\"/Users/me/code/webapp\",\"message\":{\"role\":\"user\",\"content\":\"<command-name>/clear</command-name>\"}}",
    "{\"type\":\"user\",\"timestamp\":\"2026-10-01T10:00:01.000Z\",\"cwd\":\"/Users/me/code/webapp\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"Fix the   login\\nbug\"}]}}",
    // Streaming writes the same response more than once; only the fullest copy counts.
    assistant(id: "msg_1", request: "req_1", model: opus, time: "2026-10-01T10:00:05.000Z",
        usage: "{\"input_tokens\":100,\"output_tokens\":10,\"cache_creation_input_tokens\":1000,\"cache_read_input_tokens\":0}"),
    msg1Final,
    assistant(id: "msg_2", request: "req_2", model: opus, time: "2026-10-01T10:02:00.000Z",
        usage: "{\"input_tokens\":200,\"output_tokens\":1000,\"cache_creation_input_tokens\":2000,\"cache_read_input_tokens\":50000,\"cache_creation\":{\"ephemeral_5m_input_tokens\":0,\"ephemeral_1h_input_tokens\":2000}}"),
    "{\"type\":\"ai-title\",\"aiTitle\":\"Fix login bug\",\"sessionId\":\"aaaa1111\"}",
    "not json at all",
    "{\"type\":\"user\",\"timestamp\":\"2026-10-01T10:19:00.000Z\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"content\":\"\\\"usage\\\" appears here too\"}]}}",
    assistant(id: "msg_3", request: "req_3", model: opus, time: "2026-10-01T10:20:00.000Z",
        usage: "{\"input_tokens\":1000,\"output_tokens\":1000,\"speed\":\"fast\"}"),
    assistant(id: "msg_syn", request: "req_syn", model: "<synthetic>", time: "2026-10-01T10:20:01.000Z",
        usage: "{\"input_tokens\":0,\"output_tokens\":0}"),
])
write(subA, [
    assistant(id: "msg_s1", request: "req_s1", model: "claude-haiku-4-5-20251001", time: "2026-10-01T10:01:00.000Z",
        usage: "{\"input_tokens\":1000,\"output_tokens\":2000,\"cache_read_input_tokens\":10000,\"server_tool_use\":{\"web_search_requests\":2}}", sidechain: true),
])
write(mainB, [
    msg1Final,   // history replayed into a later session must not be counted twice
    assistant(id: "msg_b1", request: "req_b1", model: "claude-opus-9-9", time: "2026-10-02T08:59:00.000Z",
        usage: "{\"input_tokens\":10,\"output_tokens\":10}"),
    assistant(id: "msg_b2", request: nil, model: "claude-sonnet-5-5", time: "2026-10-02T09:00:00.000Z",
        usage: "{\"input_tokens\":1000000,\"output_tokens\":100000}"),
    assistant(id: "msg_b3", request: "req_b3", model: "mystery-model", time: "2026-10-02T09:01:00.000Z",
        usage: "{\"input_tokens\":5,\"output_tokens\":5}", extra: ",\"costUSD\":0.5"),
])

let store = UsageStore(roots: [root + "/data"], priceTable: PriceTable.builtIn())
guard let first = store.refresh(now: now, calendar: utc) else {
    print("FAIL: first refresh returned nil")
    exit(1)
}

check(first.sessions.count == 2, "two sessions, got \(first.sessions.count)")
check(first.fileCount == 3, "three files")
check(store.refresh(now: now, calendar: utc) == nil, "unchanged refresh returns nil")

if first.sessions.count == 2 {
    let b = first.sessions[0]
    let a = first.sessions[1]
    check(a.sessionId == "aaaa1111" && b.sessionId == "bbbb2222", "most recent session first")

    // Session A, worked by hand:
    //   msg_1: 100*4 + 500*20 + 1000*5 (5m write)          = 15,400 micro-dollars
    //   msg_2: 200*4 + 1000*20 + 2000*8 (1h write) + 50000*0.2 = 46,800
    //   msg_3 (fast, 2x): (1000*4 + 1000*20) * 2            = 48,000
    //   subagent (Haiku 4.5): 1000*1 + 2000*5 + 10000*0.1 = 12,000, plus 2 web searches = $0.02
    close(a.costParts.input, (400 + 800 + 8000 + 1000) / 1e6, "A input cost")
    close(a.costParts.output, (10000 + 20000 + 40000 + 10000) / 1e6, "A output cost")
    close(a.costParts.cacheWrite, (5000 + 16000) / 1e6, "A cache write cost")
    close(a.costParts.cacheRead, (10000 + 1000) / 1e6, "A cache read cost")
    close(a.costParts.other, 0.02, "A web search cost")
    close(a.cost, 0.1422, "A total cost")
    check(a.requests == 4, "A requests, got \(a.requests)")
    check(a.tokens == TokenCounts(input: 2300, output: 4500, cacheWrite5m: 1000, cacheWrite1h: 2000, cacheRead: 60000, webSearches: 2), "A tokens \(a.tokens)")
    check(a.tokens.total == 69800, "A token total")
    close(a.subagentCost, 0.032, "A subagent cost")
    check(a.subagentRequests == 1 && a.subagentTokens == 13000, "A subagent counts")
    check(a.title == "Fix login bug", "A title")
    check(a.firstPrompt == "Fix the login bug", "A first prompt: \(a.firstPrompt ?? "nil")")
    check(a.cwd == "/Users/me/code/webapp" && a.projectName == "webapp", "A project")
    check(a.gitBranch == "main" && a.version == "2.1.300", "A branch and version")
    close(a.start, TranscriptParser.parseTimestamp("2026-10-01T10:00:00.000Z")!, "A start")
    close(a.end, TranscriptParser.parseTimestamp("2026-10-01T10:20:00.000Z")!, "A end")
    close(a.activeSeconds, 54 + 60 + 300, "A active time caps the 18 minute gap")
    check(!a.hasUnpriced, "A fully priced")
    check(a.models.map { $0.displayName } == ["Opus 5.5", "Haiku 4.5"], "A models by cost")
    close(a.models.first?.cost ?? 0, 0.1102, "A Opus cost")
    check(a.transcriptPath == root + "/" + mainA, "A transcript path")
    close(a.tokens.cacheHitRate ?? 0, 60000.0 / 65300.0, "A cache hit rate")

    // Session B: 1M input + 100K output on Sonnet 5.5 = $2 + $1; one line with a recorded
    // cost of $0.50 on an unknown model; one unknown model with no recorded cost.
    close(b.cost, 3.5, "B total cost")
    check(b.requests == 3, "B requests (replayed msg_1 excluded), got \(b.requests)")
    check(b.hasUnpriced, "B has an unpriced model")
    check(b.displayTitle == "Session bbbb2222", "B fallback title")
    check(b.projectName == "webapp", "B project from cwd")
    check(first.unpricedModels == ["claude-opus-9-9"], "unpriced models \(first.unpricedModels)")
}

close(first.today.cost, 3.5, "today")
close(first.last7.cost, 3.6422, "7 days")
close(first.last30.cost, 3.6422, "30 days")
close(first.all.cost, 3.6422, "all time")
check(first.all.requests == 7 && first.today.requests == 3, "request totals")
check(first.days.count == 2, "two days")
close(first.days.reduce(0) { $0 + $1.totals.cost }, first.sessions.reduce(0) { $0 + $1.cost }, "days and sessions agree")

// A day boundary depends on the time zone: 09:00 UTC on Oct 2 is still Oct 2 in Sofia,
// but 22:30 UTC on Oct 1 is already Oct 2 there.
do {
    var sofia = Calendar(identifier: .gregorian)
    sofia.timeZone = TimeZone(identifier: "Europe/Sofia")!
    write("tz/projects/p/cccc3333.jsonl", [
        assistant(id: "m1", request: "r1", model: opus, time: "2026-10-01T22:30:00.000Z", usage: "{\"input_tokens\":1000000,\"output_tokens\":0}"),
        assistant(id: "m2", request: "r2", model: opus, time: "2026-10-01T20:30:00.000Z", usage: "{\"input_tokens\":500000,\"output_tokens\":0}"),
    ])
    let tzStore = UsageStore(roots: [root + "/tz"], priceTable: PriceTable.builtIn())
    let snap = tzStore.refresh(now: now, calendar: sofia)!
    close(snap.today.cost, 4.0, "Sofia: late evening UTC counts as today")
    close(snap.all.cost, 6.0, "Sofia: all")
    check(snap.days.count == 2, "Sofia: two local days")
    let utcSnap = UsageStore(roots: [root + "/tz"], priceTable: PriceTable.builtIn()).refresh(now: now, calendar: utc)!
    close(utcSnap.today.cost, 0, "UTC: nothing today")
}

// MARK: Incremental reads

let msg4 = assistant(id: "msg_4", request: "req_4", model: opus, time: "2026-10-01T10:21:00.000Z", usage: "{\"input_tokens\":1000,\"output_tokens\":0}")
let cut = msg4.index(msg4.startIndex, offsetBy: 90)
append(mainA, String(msg4[..<cut]))
let partial = store.refresh(now: now, calendar: utc)
close(partial?.all.cost ?? first.all.cost, 3.6422, "half-written line is not counted")
append(mainA, String(msg4[cut...]) + "\n")
let completed = store.refresh(now: now, calendar: utc)
close(completed?.all.cost ?? -1, 3.6462, "completed line is counted once")
check(completed?.all.requests == 8, "one more request")

// A complete last line with no trailing newline is still read, and not read twice.
let msg5 = assistant(id: "msg_5", request: "req_5", model: opus, time: "2026-10-01T10:22:00.000Z", usage: "{\"input_tokens\":1000,\"output_tokens\":0}")
append(mainA, msg5)
close(store.refresh(now: now, calendar: utc)?.all.cost ?? -1, 3.6502, "unterminated complete line counted")
append(mainA, "\n" + assistant(id: "msg_6", request: "req_6", model: opus, time: "2026-10-01T10:23:00.000Z", usage: "{\"input_tokens\":1000,\"output_tokens\":0}") + "\n")
let afterSix = store.refresh(now: now, calendar: utc)
close(afterSix?.all.cost ?? -1, 3.6542, "next line after it counted, nothing doubled")
check(afterSix?.all.requests == 10, "ten requests")

// A fresh store reading the same files from scratch must agree with the incremental one.
let fresh = UsageStore(roots: [root + "/data"], priceTable: PriceTable.builtIn()).refresh(now: now, calendar: utc)
check(fresh?.sessions == afterSix?.sessions, "incremental and full scans agree")

// A file that shrinks is read again from the start.
write(mainA, [msg1Final])
close(store.refresh(now: now, calendar: utc)?.all.cost ?? -1, 3.5 + 0.0154 + 0.032, "rewritten file is re-read")

// A deleted file drops out.
try! fm.removeItem(atPath: root + "/" + mainB)
let afterDelete = store.refresh(now: now, calendar: utc)
close(afterDelete?.all.cost ?? -1, 0.0154 + 0.032, "deleted file removed")
check(afterDelete?.sessions.count == 1, "one session left")

// The day rolling over forces a rebuild even with no file changes.
let tomorrow = now.addingTimeInterval(86400)
let rolled = store.refresh(now: tomorrow, calendar: utc)
check(rolled != nil, "new day triggers rebuild")
close(rolled?.today.cost ?? -1, 0, "nothing spent on the new day")

// Changing prices re-prices everything.
var cheaper = PriceTable.builtIn().file
for i in cheaper.models.indices { cheaper.models[i].input = 0; cheaper.models[i].output = 0; cheaper.models[i].cacheWrite5m = 0; cheaper.models[i].cacheWrite1h = 0; cheaper.models[i].cacheRead = 0 }
cheaper.webSearchPer1000 = 0
store.setPriceTable(PriceTable(file: cheaper))
close(store.refresh(now: tomorrow, calendar: utc)?.all.cost ?? -1, 0, "price change applied")

// A large file crosses the read-chunk boundary (4 MB) without losing or doubling lines.
do {
    var lines: [String] = []
    let padding = String(repeating: "x", count: 3000)
    for i in 0..<3000 {
        lines.append(assistant(id: "big_\(i)", request: "r_\(i)", model: opus, time: "2026-10-02T10:00:00.000Z",
                               usage: "{\"input_tokens\":1000,\"output_tokens\":0}", extra: ",\"pad\":\"\(padding)\""))
    }
    write("big/projects/p/dddd4444.jsonl", lines)
    let snap = UsageStore(roots: [root + "/big"], priceTable: PriceTable.builtIn()).refresh(now: now, calendar: utc)!
    check(snap.all.requests == 3000, "3000 lines across chunks, got \(snap.all.requests)")
    close(snap.all.cost, 12.0, "large file cost")
}

// MARK: Customers

check(Customer.tag(from: nil) == nil, "no name, no customer")
check(Customer.tag(from: "Acme") == "Acme", "plain name is the customer")
check(Customer.tag(from: " Acme : billing refactor") == "Acme", "text before the colon, trimmed")
check(Customer.tag(from: ": no customer") == nil, "empty head is no customer")
check(Customer.tag(from: "a:b:c") == "a", "first colon only")

do {
    let cheap = "{\"input_tokens\":1000000,\"output_tokens\":0}"   // $2 on Sonnet 5.5
    let sonnet = "claude-sonnet-5-5"
    write("customers/projects/-p/c1.jsonl", [
        "{\"type\":\"custom-title\",\"customTitle\":\"Acme\",\"sessionId\":\"c1\"}",
        assistant(id: "c1_1", request: "c1_1", model: sonnet, time: "2026-10-02T09:00:00.000Z", usage: cheap),
        assistant(id: "c1_2", request: "c1_2", model: sonnet, time: "2026-09-20T09:00:00.000Z", usage: cheap),
    ])
    write("customers/projects/-p/c2.jsonl", [
        // The name may come late in the file, after a rename, and the last one wins.
        assistant(id: "c2_1", request: "c2_1", model: sonnet, time: "2026-10-02T10:00:00.000Z", usage: cheap),
        "{\"type\":\"custom-title\",\"customTitle\":\"Globex\",\"sessionId\":\"c2\"}",
        "{\"type\":\"custom-title\",\"customTitle\":\"Acme: follow-up\",\"sessionId\":\"c2\"}",
    ])
    write("customers/projects/-p/c3.jsonl", [
        "{\"type\":\"custom-title\",\"customTitle\":\"Globex\",\"sessionId\":\"c3\"}",
        assistant(id: "c3_1", request: "c3_1", model: sonnet, time: "2026-10-02T11:00:00.000Z", usage: cheap),
    ])
    write("customers/projects/-p/c4.jsonl", [
        assistant(id: "c4_1", request: "c4_1", model: sonnet, time: "2026-10-01T11:00:00.000Z", usage: cheap),
    ])
    let store = UsageStore(roots: [root + "/customers"], priceTable: PriceTable.builtIn())
    if let snap = store.refresh(now: now, calendar: utc) {
        let names = snap.customers.map { $0.name ?? "<other>" }
        check(names == ["Acme", "Globex", "<other>"], "customers by spend, unnamed last: \(names)")
        check(snap.sessions.first { $0.sessionId == "c2" }?.customer == "Acme", "renamed session follows its latest name")
        if snap.customers.count == 3 {
            let acme = snap.customers[0], globex = snap.customers[1], other = snap.customers[2]
            close(acme.all.cost, 6, "Acme all time")
            close(acme.today.cost, 4, "Acme today")
            close(acme.last7.cost, 4, "Acme 7 days")
            close(acme.last30.cost, 6, "Acme 30 days")
            check(acme.days.count == 2 && acme.today.requests == 2, "Acme days and requests")
            close(globex.all.cost, 2, "Globex all time")
            close(other.all.cost, 2, "unnamed all time")
            close(other.today.cost, 0, "unnamed nothing today")
            close(acme.all.cost + globex.all.cost + other.all.cost, snap.all.cost, "customers sum to the total")
        }
    } else {
        check(false, "customers refresh returned nil")
    }
}

// MARK: Formatting

check(Format.money(0) == "$0.00", "money zero")
check(Format.money(0.004) == "<$0.01", "money tiny")
check(Format.money(4.215) == "$4.21" || Format.money(4.215) == "$4.22", "money cents")
check(Format.money(1234.5) == "$1,235" || Format.money(1234.5) == "$1,234", "money thousands: \(Format.money(1234.5))")
check(Format.tokens(999) == "999", "tokens small")
check(Format.tokens(1500) == "1.5K", "tokens K")
check(Format.tokens(2_000_000) == "2M", "tokens M")
check(Format.tokens(123_456_789) == "123M", "tokens 123M")
check(Format.duration(45) == "45s" && Format.duration(125) == "2m" && Format.duration(3725) == "1h 2m" && Format.duration(90000) == "1d 1h", "durations")
check(Format.grouped(1234567) == "1,234,567", "grouping")

// MARK: Session states from hooks

do {
    func payload(_ event: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        var p: [String: Any] = ["hook_event_name": event, "session_id": "s1", "transcript_path": "/t/s1.jsonl", "cwd": "/w"]
        for (k, v) in extra { p[k] = v }
        return p
    }
    check(HookEvents.transition(for: payload("UserPromptSubmit")) == .set(.working), "prompt starts work")
    check(HookEvents.transition(for: payload("PreToolUse")) == .set(.working), "tool use is work")
    check(HookEvents.transition(for: payload("SubagentStop")) == .set(.working), "subagent stop keeps main working")
    check(HookEvents.transition(for: payload("Stop")) == .set(.idle), "stop is idle")
    check(HookEvents.transition(for: payload("StopFailure")) == .set(.idle), "failure is idle")
    check(HookEvents.transition(for: payload("PermissionRequest")) == .set(.waiting), "permission waits")
    check(HookEvents.transition(for: payload("Notification", ["notification_type": "permission_prompt"])) == .set(.waiting), "permission notification waits")
    check(HookEvents.transition(for: payload("Notification", ["notification_type": "idle_prompt"])) == .set(.idle), "idle notification")
    check(HookEvents.transition(for: payload("Notification", ["notification_type": "auth_success"])) == .touch, "other notification only touches")
    check(HookEvents.transition(for: payload("SessionStart", ["source": "startup"])) == .set(.idle), "start is idle")
    check(HookEvents.transition(for: payload("SessionStart", ["source": "compact"])) == .set(.working), "compact restart is mid-turn")
    check(HookEvents.transition(for: payload("SessionEnd")) == .end, "end forgets")
    check(HookEvents.transition(for: payload("FileChanged")) == .ignore, "unknown event ignored")
    check(HookEvents.transition(for: ["session_id": "s1"]) == .ignore, "no event name ignored")

    let store = SessionStateStore(folder: root + "/sessions")
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    check(store.loadAll().isEmpty, "empty store")
    check(try! store.apply(payload("SessionStart", ["source": "startup"]), now: t0, pid: 4242)?.state == .idle, "start recorded")
    let working = try! store.apply(payload("UserPromptSubmit"), now: t0.addingTimeInterval(10))
    check(working?.state == .working && working?.pid == 4242 && working?.cwd == "/w", "prompt keeps pid and cwd: \(String(describing: working))")
    check(try! store.apply(payload("Notification", ["notification_type": "auth_success"]), now: t0.addingTimeInterval(20))?.at == 1_000_020, "touch refreshes time")
    check(try! store.apply(["hook_event_name": "Stop"], now: t0) == nil, "missing session id is ignored")
    try! store.apply(["hook_event_name": "PreToolUse", "session_id": "s2"], now: t0.addingTimeInterval(30), pid: 0)
    let all = store.loadAll()
    check(all.map { $0.sessionId } == ["s2", "s1"], "all sessions, newest first: \(all.map { $0.sessionId })")

    let alive: (Int32) -> Bool = { $0 == 4242 }
    let dead: (Int32) -> Bool = { _ in false }
    let s1 = store.load("s1")!
    let s2 = store.load("s2")!
    let soon = t0.addingTimeInterval(60)
    check(SessionStateStore.isBusy(s1, includeWaiting: false, now: soon, alive: alive), "working and alive is busy")
    check(!SessionStateStore.isBusy(s1, includeWaiting: false, now: soon, alive: dead), "dead process is not busy")
    check(SessionStateStore.isBusy(s2, includeWaiting: false, now: soon, alive: dead), "unknown pid relies on time")
    check(!SessionStateStore.isBusy(s2, includeWaiting: false, now: t0.addingTimeInterval(SessionStateStore.staleAfter + 60), alive: dead), "stale working is not busy")
    let waiting = try! store.apply(payload("PermissionRequest"), now: soon)!
    check(!SessionStateStore.isBusy(waiting, includeWaiting: false, now: soon, alive: alive), "waiting is not busy by default")
    check(SessionStateStore.isBusy(waiting, includeWaiting: true, now: soon, alive: alive), "waiting counts when asked")
    let idle = try! store.apply(payload("Stop"), now: soon)!
    check(!SessionStateStore.isBusy(idle, includeWaiting: true, now: soon, alive: alive), "idle is never busy")

    store.prune(now: soon, alive: dead)
    check(store.loadAll().map { $0.sessionId } == ["s2"], "prune drops dead processes, keeps unknown pid")
    store.prune(now: soon.addingTimeInterval(25 * 3600), alive: alive)
    check(store.loadAll().isEmpty, "prune drops day-old states")
    try! store.apply(payload("PreToolUse"), now: soon)
    try! store.apply(payload("SessionEnd"), now: soon)
    check(store.load("s1") == nil, "session end removes the file")
    check(store.load("../x") == nil, "odd id does not escape the folder")
}

// MARK: Status summary for the status line script

do {
    var snap = Snapshot()
    snap.today = Totals(cost: 5.5, tokens: 10, requests: 2)
    snap.all = Totals(cost: 300, tokens: 100, requests: 20)
    snap.customers = [
        CustomerTotals(name: "vm", today: Totals(cost: 3.2), all: Totals(cost: 148.4)),
        CustomerTotals(name: nil, today: Totals(cost: 0.5), all: Totals(cost: 9)),
    ]
    var vm = SessionSummary(id: "p/s1", sessionId: "s1", projectDir: "p")
    vm.name = "vm: status line"
    let other = SessionSummary(id: "p/s2", sessionId: "s2", projectDir: "p")
    snap.sessions = [vm, other]
    let summary = StatusSummary(snapshot: snap, now: Date(timeIntervalSince1970: 1000))
    check(summary.generatedAt == 1000, "generated stamp")
    check(summary.all == StatusSummary.Spend(today: 5.5, total: 300), "overall spend")
    check(summary.customers["vm"] == StatusSummary.Spend(today: 3.2, total: 148.4), "customer spend")
    check(summary.customers["Other"] == StatusSummary.Spend(today: 0.5, total: 9), "unnamed sessions are Other")
    check(summary.sessions == ["s1": "vm", "s2": "Other"], "session to customer map: \(summary.sessions)")
    let path = root + "/status/status.json"
    try! summary.write(to: path)
    let object = try! JSONSerialization.jsonObject(with: fm.contents(atPath: path)!) as! [String: Any]
    let customers = object["customers"] as! [String: [String: Double]]
    check(customers["vm"]?["today"] == 3.2 && customers["vm"]?["total"] == 148.4, "customers in the file")
    check((object["sessions"] as! [String: String])["s1"] == "vm", "sessions in the file")
    check((object["generatedAt"] as! NSNumber).doubleValue == 1000, "stamp in the file")
    check((object["all"] as! [String: Double])["total"] == 300, "overall totals in the file")
    let text = String(data: try! summary.json(), encoding: .utf8)!
    check(text == String(data: try! summary.json(), encoding: .utf8)!, "stable output")
    check(text.hasPrefix("{\"all\""), "keys sorted: \(text.prefix(20))")
    check(object["since"] == nil, "no since key without a since day")

    // With a since day the total is the spend from that day on, per customer and overall.
    snap.days = [DayTotal(dayStart: 86400 * 1, totals: Totals(cost: 100)),
                 DayTotal(dayStart: 86400 * 2, totals: Totals(cost: 40)),
                 DayTotal(dayStart: 86400 * 3, totals: Totals(cost: 5.5))]
    snap.customers[0].days = [DayTotal(dayStart: 86400 * 1, totals: Totals(cost: 90)),
                              DayTotal(dayStart: 86400 * 3, totals: Totals(cost: 3.2))]
    let sinceSummary = StatusSummary(snapshot: snap, sinceStart: 86400 * 2, sinceLabel: "Jan 3, 1970",
                                     now: Date(timeIntervalSince1970: 1000))
    check(sinceSummary.since == "Jan 3, 1970", "since label kept")
    check(sinceSummary.all == StatusSummary.Spend(today: 5.5, total: 45.5), "overall since total: \(sinceSummary.all)")
    check(sinceSummary.customers["vm"] == StatusSummary.Spend(today: 3.2, total: 3.2), "customer since total: \(String(describing: sinceSummary.customers["vm"]))")
    check(sinceSummary.customers["Other"] == StatusSummary.Spend(today: 0.5, total: 0), "customer with no days since: \(String(describing: sinceSummary.customers["Other"]))")
    let sinceObject = try! JSONSerialization.jsonObject(with: try! sinceSummary.json()) as! [String: Any]
    check(sinceObject["since"] as? String == "Jan 3, 1970", "since label in the file")
    check((sinceObject["all"] as! [String: Double])["total"] == 45.5, "since total in the file")
}

// MARK: Hook settings

do {
    let command = HookSettings.command(executable: "/Applications/trackme.app/Contents/MacOS/trackme")
    check(command == "\"/Applications/trackme.app/Contents/MacOS/trackme\" --hook", "hook command quoted: \(command)")
    let other: [String: Any] = ["type": "command", "command": "/Users/me/.config/iterm2/cc-status"]
    let settings: [String: Any] = [
        "model": "opus",
        "hooks": [
            "Stop": [["hooks": [other]]],
            "Notification": [["matcher": "idle_prompt", "hooks": [other]]],
        ],
    ]
    check(HookSettings.installedCommand(in: settings) == nil, "not installed at first")
    let installed = HookSettings.install(into: settings, command: command)
    check(HookSettings.installedCommand(in: installed) == command, "installed command found")
    check(installed["model"] as? String == "opus", "other settings untouched")
    let hooks = installed["hooks"] as! [String: Any]
    check(Set(hooks.keys).isSuperset(of: Set(HookEvents.installed)), "every event has an entry")
    let stop = hooks["Stop"] as! [[String: Any]]
    check(stop.count == 2 && (stop[0]["hooks"] as! [[String: Any]])[0]["command"] as? String == other["command"] as? String, "existing Stop hook kept first")
    check((stop[1]["hooks"] as! [[String: Any]])[0]["timeout"] as? Int == 10, "timeout in seconds")
    let notify = hooks["Notification"] as! [[String: Any]]
    check(notify[0]["matcher"] as? String == "idle_prompt", "existing matcher kept")
    let moved = HookSettings.install(into: installed, command: HookSettings.command(executable: "/tmp/trackme.app/Contents/MacOS/trackme"))
    check(HookSettings.installedCommand(in: moved)?.hasPrefix("\"/tmp/") == true, "reinstall replaces the path")
    check(((moved["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]).count == 2, "reinstall does not duplicate")
    let removed = HookSettings.remove(from: moved)
    check(HookSettings.installedCommand(in: removed) == nil, "removed")
    let left = removed["hooks"] as! [String: Any]
    check(Set(left.keys) == ["Stop", "Notification"], "only the other hooks' events remain: \(left.keys.sorted())")
    check((left["Stop"] as! [[String: Any]]).count == 1, "other Stop hook kept")
    let bare = HookSettings.remove(from: HookSettings.install(into: ["model": "opus"], command: command))
    check(bare["hooks"] == nil && bare.count == 1, "no empty hooks section left behind")
    check(JSONSerialization.isValidJSONObject(installed), "settings stay serialisable")
}

try? fm.removeItem(atPath: root)
print(failures == 0 ? "PASS: \(checks) checks" : "FAILED: \(failures) of \(checks) checks")
exit(failures == 0 ? 0 : 1)
