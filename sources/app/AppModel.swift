import AppKit
import Combine
import SwiftUI

enum RangeFilter: String, CaseIterable, Identifiable {
    case today, week, month, all

    var id: String { return rawValue }

    var label: String {
        switch self {
        case .today: return "Today"
        case .week: return "7 days"
        case .month: return "30 days"
        case .all: return "All"
        }
    }
}

/// Which customer's numbers the popover shows; `.customer(nil)` is the sessions with no name.
enum CustomerFilter: Equatable {
    case all
    case customer(String?)

    /// Stored form: "*" for all, "" for the unnamed sessions, otherwise the name.
    var stored: String {
        switch self {
        case .all: return "*"
        case .customer(let name): return name ?? ""
        }
    }

    init(stored: String?) {
        switch stored {
        case nil, "*": self = .all
        case "": self = .customer(nil)
        case let name?: self = .customer(name)
        }
    }
}

/// One tab in the widget's customer switcher.
struct CustomerChoice: Identifiable {
    let filter: CustomerFilter
    let label: String

    var id: String { return filter.stored }
}

/// Owns the usage store and publishes what the views show. Lives on the main thread;
/// scanning happens on a background queue.
final class AppModel: ObservableObject {
    @Published var snapshot = Snapshot()
    @Published var loading = true
    @Published var customerFilter: CustomerFilter {
        didSet { UserDefaults.standard.set(customerFilter.stored, forKey: "customer") }
    }
    /// Customers always offered in the widget, even before they have a session.
    @Published var pinnedCustomers: [String] {
        didSet { UserDefaults.standard.set(pinnedCustomers, forKey: "customers") }
    }
    /// Start of a custom range; the widget then shows the spend from this day until now.
    @Published var since: Date? {
        didSet {
            if let s = since { UserDefaults.standard.set(s.timeIntervalSince1970, forKey: "since") }
            else { UserDefaults.standard.removeObject(forKey: "since") }
        }
    }
    @Published var now = Date()
    @Published var priceProblem: String?
    @Published var usingCustomPrices = false
    @Published var launchAtLogin = false
    @Published var showWidget: Bool {
        didSet {
            UserDefaults.standard.set(showWidget, forKey: "showWidget")
            onWidgetChange?(showWidget)
        }
    }
    /// Whether the widget floats above other windows or sits on the desktop under them.
    @Published var widgetOnTop: Bool {
        didSet {
            UserDefaults.standard.set(widgetOnTop, forKey: "widgetOnTop")
            onWidgetLevelChange?(widgetOnTop)
        }
    }

    var onWidgetChange: ((Bool) -> Void)?
    var onWidgetLevelChange: ((Bool) -> Void)?

    // MARK: Keep awake settings

    /// Hold off system sleep while a Claude Code session is working.
    @Published var keepAwake: Bool {
        didSet { UserDefaults.standard.set(keepAwake, forKey: "keepAwake"); updateSleep() }
    }
    @Published var keepAwakeOnBattery: Bool {
        didSet { UserDefaults.standard.set(keepAwakeOnBattery, forKey: "keepAwakeOnBattery"); updateSleep() }
    }
    /// Also count a session blocked on a permission prompt as working.
    @Published var keepAwakeWhileWaiting: Bool {
        didSet { UserDefaults.standard.set(keepAwakeWhileWaiting, forKey: "keepAwakeWhileWaiting"); updateWorkStates() }
    }
    /// Minutes to stay awake after the last session stops working.
    @Published var graceMinutes: Int {
        didSet { UserDefaults.standard.set(graceMinutes, forKey: "graceMinutes"); updateSleep() }
    }
    static let graceChoices = [2, 5, 15, 30]

    /// What each session's hooks last reported; empty until the hook is installed.
    @Published var sessionStates: [SessionState] = []
    @Published var busyCount = 0
    @Published var holdingAwake = false
    @Published var hookInstalled = false
    @Published var hookProblem: String?

    private let sleepBlocker = SleepBlocker()
    private let stateStore = SessionStateStore(folder: AppModel.sessionsFolder)
    private var lastBusy: Date?

    private let queue = DispatchQueue(label: "local.trackme.scan", qos: .utility)
    private var scanning = false
    private var refreshQueued = false
    private var timer: Timer?

    // Touched only on `queue`.
    private var store: UsageStore?
    private var priceStamp = -1.0
    private var queuePriceProblem: String?
    private var queueCustomPrices = false

    static let refreshInterval = 15.0
    static let activeWindow = 300.0

    init() {
        customerFilter = CustomerFilter(stored: UserDefaults.standard.string(forKey: "customer"))
        pinnedCustomers = UserDefaults.standard.stringArray(forKey: "customers") ?? ["vm", "ps"]
        if let stamp = UserDefaults.standard.object(forKey: "since") as? Double {
            since = Date(timeIntervalSince1970: stamp)
        }
        launchAtLogin = FileManager.default.fileExists(atPath: AppModel.launchAgentPath)
        showWidget = UserDefaults.standard.object(forKey: "showWidget") as? Bool ?? true
        widgetOnTop = UserDefaults.standard.bool(forKey: "widgetOnTop")
        keepAwake = UserDefaults.standard.object(forKey: "keepAwake") as? Bool ?? true
        keepAwakeOnBattery = UserDefaults.standard.bool(forKey: "keepAwakeOnBattery")
        keepAwakeWhileWaiting = UserDefaults.standard.bool(forKey: "keepAwakeWhileWaiting")
        let grace = UserDefaults.standard.integer(forKey: "graceMinutes")
        graceMinutes = grace > 0 ? grace : 5
    }

    // MARK: Refreshing

    func start() {
        // Keep the login item and the hook pointing at this copy of the app if it has moved.
        if launchAtLogin { setLaunchAtLogin(true) }
        checkHook()
        if hookInstalled, let settings = try? readClaudeSettings(), let exe = Bundle.main.executablePath,
           HookSettings.installedCommand(in: settings) != HookSettings.command(executable: exe) {
            setHookInstalled(true)
        }
        refresh()
        let t = Timer(timeInterval: AppModel.refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() {
        now = Date()
        updateWorkStates()
        if scanning {
            // Run once more when the current scan ends, so a change made meanwhile is not missed.
            refreshQueued = true
            return
        }
        scanning = true
        queue.async { [weak self] in
            guard let model = self else { return }
            let result = model.scan()
            let problem = model.queuePriceProblem
            let custom = model.queueCustomPrices
            DispatchQueue.main.async {
                model.scanning = false
                model.loading = false
                model.priceProblem = problem
                model.usingCustomPrices = custom
                if let fresh = result { model.snapshot = fresh }
                model.writeStatusSummary()
                if model.refreshQueued {
                    model.refreshQueued = false
                    model.refresh()
                }
            }
        }
    }

    /// Runs on `queue`.
    private func scan() -> Snapshot? {
        let roots = UsageStore.configRoots(environment: ProcessInfo.processInfo.environment,
                                           home: NSHomeDirectory(), override: nil)
        var table: PriceTable?
        let stamp = AppModel.modificationStamp(AppModel.pricesPath)
        if store == nil || stamp != priceStamp {
            priceStamp = stamp
            queuePriceProblem = nil
            queueCustomPrices = false
            if stamp > 0 {
                do {
                    let data = try Data(contentsOf: URL(fileURLWithPath: AppModel.pricesPath))
                    table = try PriceTable(json: data)
                    queueCustomPrices = true
                } catch {
                    table = PriceTable.builtIn()
                    queuePriceProblem = "prices.json has an error, so built-in prices are in use."
                }
            } else {
                table = PriceTable.builtIn()
            }
        }

        if let existing = store {
            existing.setRoots(roots)
            if let t = table { existing.setPriceTable(t) }
            return existing.refresh()
        }
        let created = UsageStore(roots: roots, priceTable: table ?? PriceTable.builtIn())
        store = created
        return created.refresh()
    }

    private static func modificationStamp(_ path: String) -> Double {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let date = attributes[.modificationDate] as? Date else { return 0 }
        return date.timeIntervalSince1970
    }

    // MARK: What the views read

    /// Totals of a range, for everything or for the selected customer.
    func totals(_ range: RangeFilter) -> Totals {
        if case .customer(let name) = customerFilter {
            guard let customer = selectedCustomer(name) else { return Totals() }
            switch range {
            case .today: return customer.today
            case .week: return customer.last7
            case .month: return customer.last30
            case .all: return customer.all
            }
        }
        switch range {
        case .today: return snapshot.today
        case .week: return snapshot.last7
        case .month: return snapshot.last30
        case .all: return snapshot.all
        }
    }

    /// Spend from the start of the `since` day until now, for the selected customer.
    var sinceTotals: Totals? {
        guard let since = since else { return nil }
        let start = Calendar.current.startOfDay(for: since).timeIntervalSince1970
        var days = snapshot.days
        if case .customer(let name) = customerFilter { days = selectedCustomer(name)?.days ?? [] }
        var totals = Totals()
        for day in days where day.dayStart >= start {
            totals.cost += day.totals.cost
            totals.tokens += day.totals.tokens
            totals.requests += day.totals.requests
        }
        return totals
    }

    var sinceLabel: String {
        guard let since = since else { return "" }
        return "Since " + Dates.calendarDay.string(from: since)
    }

    private func selectedCustomer(_ name: String?) -> CustomerTotals? {
        return snapshot.customers.first { $0.name == name }
    }

    /// The tabs in the widget: "All", the pinned customers, then any other named customer
    /// seen in the transcripts, and "Other" when some sessions have no name.
    var customerChoices: [CustomerChoice] {
        var choices = [CustomerChoice(filter: .all, label: "All")]
        var listed = Set<String>()
        for name in pinnedCustomers where !listed.contains(name) {
            listed.insert(name)
            choices.append(CustomerChoice(filter: .customer(name), label: name))
        }
        for customer in snapshot.customers {
            if let name = customer.name {
                if listed.contains(name) { continue }
                listed.insert(name)
                choices.append(CustomerChoice(filter: .customer(name), label: name))
            } else if snapshot.customers.count > 1 {
                choices.append(CustomerChoice(filter: .customer(nil), label: "Other"))
            }
        }
        if !choices.contains(where: { $0.filter == customerFilter }), case .customer(let name) = customerFilter {
            choices.append(CustomerChoice(filter: customerFilter, label: name ?? "Other"))
        }
        return choices
    }

    func isActive(_ session: SessionSummary) -> Bool {
        return now.timeIntervalSince1970 - session.end < AppModel.activeWindow
    }

    // MARK: Keep awake

    static var sessionsFolder: String {
        return (supportFolder as NSString).appendingPathComponent("sessions")
    }

    /// Reads the hook state files and decides whether the Mac must stay awake.
    private func updateWorkStates() {
        stateStore.prune(now: now, alive: Processes.isAlive)
        let states = stateStore.loadAll()
        let busy = states.filter {
            SessionStateStore.isBusy($0, includeWaiting: keepAwakeWhileWaiting, now: now, alive: Processes.isAlive)
        }
        if busy.count > 0 { lastBusy = now }
        if states != sessionStates { sessionStates = states }
        if busy.count != busyCount { busyCount = busy.count }
        updateSleep()
    }

    private func updateSleep() {
        var hold = false
        if keepAwake, let last = lastBusy, now.timeIntervalSince(last) <= Double(graceMinutes) * 60 {
            hold = keepAwakeOnBattery || Power.onAC
        }
        if hold {
            sleepBlocker.hold(reason: "trackme: Claude Code is working")
        } else {
            sleepBlocker.release()
        }
        if holdingAwake != sleepBlocker.holding { holdingAwake = sleepBlocker.holding }
    }

    /// One line for the menu about sleep and the sessions' states.
    var awakeLine: String {
        if hookProblem != nil { return hookProblem! }
        if !hookInstalled { return "Claude Code hook not installed, so sleep is not held off" }
        let working = busyCount == 1 ? "1 session working" : "\(busyCount) sessions working"
        if holdingAwake {
            return busyCount > 0 ? "Keeping awake · " + working : "Keeping awake a few more minutes"
        }
        if !keepAwake { return "Not keeping awake · " + working }
        if busyCount > 0 && !keepAwakeOnBattery && !Power.onAC { return working + " · on battery, may sleep" }
        return busyCount > 0 ? working : "No session working"
    }

    // MARK: Claude Code hook

    /// The settings.json Claude Code reads for this user.
    static var claudeSettingsPath: String {
        let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? ""
        let first = env.split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        let base = first.isEmpty ? (NSHomeDirectory() as NSString).appendingPathComponent(".claude")
                                 : (first as NSString).expandingTildeInPath
        return (base as NSString).appendingPathComponent("settings.json")
    }

    private struct SettingsError: LocalizedError {
        var errorDescription: String? { return "settings.json is not a JSON object" }
    }

    private func readClaudeSettings() throws -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: AppModel.claudeSettingsPath),
              !data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SettingsError() }
        return object
    }

    func checkHook() {
        guard let settings = try? readClaudeSettings() else {
            hookInstalled = false
            return
        }
        hookInstalled = HookSettings.installedCommand(in: settings) != nil
    }

    /// Adds trackme to, or removes it from, every hook event in Claude Code's settings.
    /// Other hooks are left as they are. The file before the first change is kept next to it.
    func setHookInstalled(_ enabled: Bool) {
        let fm = FileManager.default
        let path = AppModel.claudeSettingsPath
        do {
            let settings = try readClaudeSettings()
            let updated: [String: Any]
            if enabled {
                guard let exe = Bundle.main.executablePath else { return }
                updated = HookSettings.install(into: settings, command: HookSettings.command(executable: exe))
            } else {
                updated = HookSettings.remove(from: settings)
            }
            let data = try JSONSerialization.data(withJSONObject: updated,
                                                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true, attributes: nil)
            let backup = path + ".before-trackme"
            if fm.fileExists(atPath: path) && !fm.fileExists(atPath: backup) {
                try? fm.copyItem(atPath: path, toPath: backup)
            }
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            hookProblem = nil
        } catch {
            hookProblem = "Could not change " + path + ": " + error.localizedDescription
        }
        checkHook()
        refresh()
    }

    // MARK: Prices

    static var supportFolder: String {
        return (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/trackme")
    }

    static var pricesPath: String {
        return (supportFolder as NSString).appendingPathComponent("prices.json")
    }

    // MARK: Status line

    /// Where the totals for `scripts/statusline.sh` are written after every scan.
    static var statusSummaryPath: String {
        return (supportFolder as NSString).appendingPathComponent("status.json")
    }

    /// Exports the current snapshot for the status line script. Written on every refresh,
    /// even when nothing changed, so the script can tell that the app is running.
    private func writeStatusSummary() {
        if loading { return }
        try? StatusSummary(snapshot: snapshot, now: now).write(to: AppModel.statusSummaryPath)
    }

    /// Opens prices.json in the default editor, creating it from the built-in table first.
    func editPrices() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: AppModel.pricesPath) {
            try? fm.createDirectory(atPath: AppModel.supportFolder, withIntermediateDirectories: true, attributes: nil)
            try? defaultPricesJSON.write(toFile: AppModel.pricesPath, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: AppModel.pricesPath))
        refresh()
    }

    func resetPrices() {
        try? FileManager.default.removeItem(atPath: AppModel.pricesPath)
        refresh()
    }

    // MARK: Launch at login

    static var launchAgentPath: String {
        return (NSHomeDirectory() as NSString).appendingPathComponent("Library/LaunchAgents/local.trackme.login.plist")
    }

    /// Uses a per-user launch agent, which works on every macOS version and is one file to remove.
    func setLaunchAtLogin(_ enabled: Bool) {
        let fm = FileManager.default
        let path = AppModel.launchAgentPath
        if enabled, let executable = Bundle.main.executablePath {
            let plist: [String: Any] = [
                "Label": "local.trackme.login",
                "ProgramArguments": [executable],
                "RunAtLoad": true,
                "LimitLoadToSessionType": "Aqua",
            ]
            try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                    withIntermediateDirectories: true, attributes: nil)
            if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        } else {
            try? fm.removeItem(atPath: path)
        }
        launchAtLogin = fm.fileExists(atPath: path)
    }

    // MARK: Customers

    /// Asks for the pinned customer names, comma-separated.
    func editCustomers() {
        let hint = NSTextField(wrappingLabelWithString: "Names to show in the widget, separated by commas. A session counts for a customer when Claude Code was started with claude --name \"<customer>\".")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 300
        hint.frame = NSRect(x: 0, y: 0, width: 300, height: hint.sizeThatFits(NSSize(width: 300, height: 200)).height)

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = pinnedCustomers.joined(separator: ", ")
        field.focusRingType = .none

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: hint.frame.height + 12 + field.frame.height))
        field.setFrameOrigin(NSPoint(x: 0, y: content.frame.height - field.frame.height))
        hint.setFrameOrigin(.zero)
        content.addSubview(field)
        content.addSubview(hint)

        let response = GlassDialog.run(title: "Customers", content: content, firstResponder: field,
                                       buttons: [("Cancel", .cancel), ("Save", .OK)])
        guard response == .OK else { return }
        var names: [String] = []
        for part in field.stringValue.split(separator: ",") {
            let name = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty && !names.contains(name) { names.append(name) }
        }
        pinnedCustomers = names
    }

    // MARK: Since date

    /// Shows a calendar to pick the day the custom range starts on.
    func chooseSince() {
        let picker = NSDatePicker()
        picker.datePickerStyle = .clockAndCalendar
        picker.datePickerElements = .yearMonthDay
        picker.maxDate = Date()
        picker.dateValue = since ?? Date()
        picker.focusRingType = .none
        picker.sizeToFit()
        // The calendar has one fixed size, so it is drawn (and hit-tested) at a larger scale.
        let scale: CGFloat = 1.6
        let natural = picker.frame.size
        picker.scaleUnitSquare(to: NSSize(width: scale, height: scale))
        picker.setFrameSize(NSSize(width: natural.width * scale, height: natural.height * scale))

        var buttons: [(String, NSApplication.ModalResponse)] = [("Cancel", .cancel)]
        if since != nil { buttons.append(("Reset", GlassDialog.extraResponse)) }
        buttons.append(("Select", .OK))
        let response = GlassDialog.run(title: "Show spend since", content: picker, firstResponder: nil, buttons: buttons)
        if response == .OK {
            since = picker.dateValue
        } else if response == GlassDialog.extraResponse {
            since = nil
        }
    }

    func resetSince() {
        since = nil
    }

    // MARK: Small actions

    func quit() {
        NSApp.terminate(nil)
    }
}

/// A modal dialog on the same frosted, rounded glass as the widget: a small title in the
/// top left, the given content, and a centred row of buttons. Return triggers the last
/// button, Escape the first.
enum GlassDialog {
    /// For a third button besides Cancel and OK.
    static let extraResponse = NSApplication.ModalResponse(rawValue: 2)

    static func run(title: String, content: NSView, firstResponder: NSView?,
                    buttons: [(title: String, response: NSApplication.ModalResponse)]) -> NSApplication.ModalResponse {
        let margin: CGFloat = 20
        let titleBar: CGFloat = 28
        let buttonGap: CGFloat = 8
        let responder = Responder()
        let controls: [NSButton] = buttons.enumerated().map { index, spec in
            let b = NSButton(title: spec.title, target: responder, action: #selector(Responder.press(_:)))
            b.bezelStyle = .rounded
            b.tag = Int(spec.response.rawValue)
            if index == 0 { b.keyEquivalent = "\u{1b}" }
            if index == buttons.count - 1 { b.keyEquivalent = "\r" }
            b.sizeToFit()
            b.setFrameSize(NSSize(width: max(b.frame.width, 84), height: b.frame.height))
            return b
        }
        let buttonsWidth = controls.reduce(0) { $0 + $1.frame.width } + buttonGap * CGFloat(controls.count - 1)
        let width = max(content.frame.width, buttonsWidth) + margin * 2
        let height = titleBar + margin + content.frame.height + 16 + (controls.first?.frame.height ?? 0) + margin

        let glass = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        glass.material = WidgetPanel.material
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.maskImage = WidgetPanel.roundedMask(radius: WidgetPanel.cornerRadius)
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = NSFont.systemFont(ofSize: 9.5, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.sizeToFit()
        label.setFrameOrigin(NSPoint(x: margin, y: height - 16 - label.frame.height))
        glass.addSubview(label)
        content.setFrameOrigin(NSPoint(x: (width - content.frame.width) / 2, y: height - titleBar - margin - content.frame.height))
        glass.addSubview(content)
        var x = (width - buttonsWidth) / 2
        for button in controls {
            button.setFrameOrigin(NSPoint(x: x, y: margin))
            glass.addSubview(button)
            x += button.frame.width + buttonGap
        }

        let window = KeyableWindow(contentRect: glass.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.contentView = glass
        window.isReleasedWhenClosed = false
        window.initialFirstResponder = firstResponder
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        let response = NSApp.runModal(for: window)
        window.orderOut(nil)
        return response
    }

    /// A borderless window that still takes keyboard focus, so typing, Return and Escape work.
    private final class KeyableWindow: NSWindow {
        override var canBecomeKey: Bool { return true }
    }

    private final class Responder: NSObject {
        @objc func press(_ sender: NSButton) {
            NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: sender.tag))
        }
    }
}

enum Dates {
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    static let dayTime: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMdjm")
        return f
    }()

    static let day: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEMMMd")
        return f
    }()

    static let calendarDay: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("yMMMd")
        return f
    }()

    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()

    static func when(_ seconds: Double) -> String {
        let date = Date(timeIntervalSince1970: seconds)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today " + time.string(from: date) }
        if calendar.isDateInYesterday(date) { return "Yesterday " + time.string(from: date) }
        return dayTime.string(from: date)
    }
}
