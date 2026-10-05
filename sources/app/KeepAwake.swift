import Foundation
import IOKit.ps
import IOKit.pwr_mgt

/// Holds a power assertion that keeps the Mac, and so its network, awake. The display still
/// dims, sleeps and locks as usual; this is what `caffeinate -i` does.
final class SleepBlocker {
    private var assertion: IOPMAssertionID = 0
    private(set) var holding = false

    func hold(reason: String) {
        if holding { return }
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 reason as CFString, &id)
        if result == kIOReturnSuccess {
            assertion = id
            holding = true
        }
    }

    func release() {
        guard holding else { return }
        IOPMAssertionRelease(assertion)
        assertion = 0
        holding = false
    }

    deinit { release() }
}

enum Power {
    /// True on mains power, and on a Mac with no battery at all.
    static var onAC: Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return true }
        guard let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else { return true }
        return (type as String) == kIOPMACPowerKey
    }
}

enum Processes {
    static func isAlive(_ pid: Int32) -> Bool {
        if pid <= 0 { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Name and parent of a process, from the kernel's process table.
    static func info(of pid: Int32) -> (parent: Int32, name: String)? {
        var proc = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &proc, &size, nil, 0) == 0, size > 0 else { return nil }
        let name = withUnsafePointer(to: &proc.kp_proc.p_comm) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
        }
        return (proc.kp_eproc.e_ppid, name)
    }

    /// The Claude Code process that ran this hook. Hooks are started through a shell, so the
    /// shells are skipped; the first ancestor called claude or node is it. 0 when not found.
    static func claudeAncestor() -> Int32 {
        let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish"]
        var pid = getppid()
        var fallback: Int32 = 0
        for _ in 0..<6 {
            guard pid > 1, let (parent, name) = info(of: pid) else { break }
            if name == "claude" || name == "node" { return pid }
            if fallback == 0 && !shells.contains(name) { fallback = pid }
            pid = parent
        }
        return fallback
    }
}

/// `trackme --hook`: reads one hook payload from stdin and records the session's state.
/// Always exits 0, because a non-zero hook exit would interrupt Claude Code.
enum HookCommand {
    static func run() -> Never {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        if let object = try? JSONSerialization.jsonObject(with: data), let payload = object as? [String: Any] {
            let store = SessionStateStore(folder: AppModel.sessionsFolder)
            _ = try? store.apply(payload, pid: Processes.claudeAncestor())
        }
        exit(0)
    }
}
