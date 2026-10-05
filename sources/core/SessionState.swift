import Foundation

/// What a Claude Code session is doing right now, as reported by its hooks.
enum WorkState: String, Codable {
    case working               // a turn is in progress: thinking, or running a tool
    case waiting               // blocked on the user: a permission prompt
    case idle                  // at the prompt, nothing to do
}

/// The last thing a session's hooks reported. One file per session in the state folder.
struct SessionState: Codable, Equatable {
    var sessionId: String
    var state: WorkState
    var event: String          // hook event that set the state
    var at: Double             // seconds since 1970
    var transcriptPath: String?
    var cwd: String?
    /// Process ID of the Claude Code process, when the hook could find it. 0 when unknown.
    var pid: Int32 = 0

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id", state, event, at
        case transcriptPath = "transcript_path", cwd, pid
    }
}

/// How one hook event changes a session's state.
enum StateTransition: Equatable {
    case set(WorkState)
    case touch                 // keep the state, refresh the time
    case end                   // the session is over: forget it
    case ignore
}

enum HookEvents {
    /// Every event the hook is installed for. The hook is harmless for any event, but only
    /// these change what the app shows.
    static let installed = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
        "PermissionRequest", "PermissionDenied", "Notification", "Stop", "StopFailure",
        "SubagentStart", "SubagentStop", "PreCompact", "PostCompact", "SessionEnd",
    ]

    /// `payload` is the JSON Claude Code writes to the hook's stdin.
    static func transition(for payload: [String: Any]) -> StateTransition {
        guard let event = payload["hook_event_name"] as? String else { return .ignore }
        switch event {
        case "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionDenied",
             "SubagentStart", "SubagentStop", "PreCompact", "PostCompact":
            return .set(.working)
        case "SessionStart":
            // A compaction happens in the middle of a turn; every other start waits for a prompt.
            return .set(payload["source"] as? String == "compact" ? .working : .idle)
        case "PermissionRequest":
            return .set(.waiting)
        case "Notification":
            switch payload["notification_type"] as? String {
            case "permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input":
                return .set(.waiting)
            case "idle_prompt": return .set(.idle)
            default: return .touch
            }
        case "Stop", "StopFailure":
            return .set(.idle)
        case "SessionEnd":
            return .end
        default:
            return .ignore
        }
    }
}

/// Reads and writes the per-session state files. Not thread-safe.
final class SessionStateStore {
    let folder: String

    /// A "working" state this old with no newer event is treated as abandoned: Claude Code
    /// reports at least once per tool call, and a tool call cannot run anywhere near this long.
    static let staleAfter = 30.0 * 60

    init(folder: String) {
        self.folder = folder
    }

    private func path(_ sessionId: String) -> String {
        // Session ids are UUIDs; anything else is kept from escaping the folder.
        let safe = sessionId.replacingOccurrences(of: "/", with: "_")
        return (folder as NSString).appendingPathComponent(safe + ".json")
    }

    func load(_ sessionId: String) -> SessionState? {
        guard let data = FileManager.default.contents(atPath: path(sessionId)) else { return nil }
        return try? JSONDecoder().decode(SessionState.self, from: data)
    }

    func save(_ state: SessionState) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: URL(fileURLWithPath: path(state.sessionId)), options: .atomic)
    }

    func remove(_ sessionId: String) {
        try? FileManager.default.removeItem(atPath: path(sessionId))
    }

    /// Applies one hook payload. Returns the state written, or nil when nothing was kept.
    @discardableResult
    func apply(_ payload: [String: Any], now: Date = Date(), pid: Int32 = 0) throws -> SessionState? {
        guard let sessionId = payload["session_id"] as? String, !sessionId.isEmpty else { return nil }
        let event = payload["hook_event_name"] as? String ?? ""
        switch HookEvents.transition(for: payload) {
        case .ignore:
            return nil
        case .end:
            remove(sessionId)
            return nil
        case .touch:
            guard var existing = load(sessionId) else { return nil }
            existing.at = now.timeIntervalSince1970
            try save(existing)
            return existing
        case .set(let state):
            let previous = load(sessionId)
            let fresh = SessionState(sessionId: sessionId, state: state, event: event,
                                     at: now.timeIntervalSince1970,
                                     transcriptPath: payload["transcript_path"] as? String ?? previous?.transcriptPath,
                                     cwd: payload["cwd"] as? String ?? previous?.cwd,
                                     pid: pid != 0 ? pid : previous?.pid ?? 0)
            try save(fresh)
            return fresh
        }
    }

    /// Every session with a state file, most recent first.
    func loadAll() -> [SessionState] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return [] }
        var result: [SessionState] = []
        for name in names where name.hasSuffix(".json") {
            let full = (folder as NSString).appendingPathComponent(name)
            if let data = FileManager.default.contents(atPath: full),
               let state = try? JSONDecoder().decode(SessionState.self, from: data) {
                result.append(state)
            }
        }
        return result.sorted { $0.at > $1.at }
    }

    /// Deletes the files of sessions whose process is gone or whose last report is older than a day.
    func prune(now: Date = Date(), alive: (Int32) -> Bool) {
        for state in loadAll() {
            let old = now.timeIntervalSince1970 - state.at > 24 * 3600
            let dead = state.pid != 0 && !alive(state.pid)
            if old || dead { remove(state.sessionId) }
        }
    }

    /// Whether the session is doing something that should keep the Mac awake.
    static func isBusy(_ state: SessionState, includeWaiting: Bool, now: Date, alive: (Int32) -> Bool) -> Bool {
        switch state.state {
        case .idle: return false
        case .waiting: if !includeWaiting { return false }
        case .working: break
        }
        if now.timeIntervalSince1970 - state.at > staleAfter { return false }
        if state.pid != 0 && !alive(state.pid) { return false }
        return true
    }
}

/// Edits the `hooks` section of a Claude Code settings.json so that every event runs the
/// trackme hook, without touching any other hook that is configured.
enum HookSettings {
    static func command(executable: String) -> String {
        return "\"" + executable.replacingOccurrences(of: "\"", with: "\\\"") + "\" --hook"
    }

    /// Recognises trackme's entry whatever path the app lives at.
    static func isOurs(_ hook: [String: Any]) -> Bool {
        guard let command = hook["command"] as? String else { return false }
        return command.hasSuffix(" --hook") && command.contains("/trackme\"")
    }

    /// The command the settings currently run for trackme, if any.
    static func installedCommand(in settings: [String: Any]) -> String? {
        guard let hooks = settings["hooks"] as? [String: Any] else { return nil }
        for (_, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            for group in groups {
                for hook in group["hooks"] as? [[String: Any]] ?? [] where isOurs(hook) {
                    return hook["command"] as? String
                }
            }
        }
        return nil
    }

    static func install(into settings: [String: Any], command: String) -> [String: Any] {
        var result = remove(from: settings)
        var hooks = result["hooks"] as? [String: Any] ?? [:]
        let entry: [String: Any] = ["type": "command", "command": command, "timeout": 10]
        for event in HookEvents.installed {
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups.append(["hooks": [entry]])
            hooks[event] = groups
        }
        result["hooks"] = hooks
        return result
    }

    static func remove(from settings: [String: Any]) -> [String: Any] {
        var result = settings
        guard var hooks = result["hooks"] as? [String: Any] else { return result }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            var kept: [[String: Any]] = []
            for var group in groups {
                let list = (group["hooks"] as? [[String: Any]] ?? []).filter { !isOurs($0) }
                if list.isEmpty && group["hooks"] != nil { continue }
                group["hooks"] = list
                kept.append(group)
            }
            if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
        }
        if hooks.isEmpty { result.removeValue(forKey: "hooks") } else { result["hooks"] = hooks }
        return result
    }
}
