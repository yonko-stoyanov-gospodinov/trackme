import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private let model = AppModel()
    private var widget: WidgetPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            // pawprint.fill is available since macOS 12, so no fallback is needed.
            button.image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Claude Code usage")
            button.imagePosition = .imageOnly
        }
        menu.delegate = self
        item.menu = menu

        model.onWidgetChange = { [weak self] visible in
            self?.setWidgetVisible(visible)
        }
        model.onWidgetLevelChange = { [weak self] onTop in
            self?.widget?.setOnTop(onTop)
        }
        setWidgetVisible(model.showWidget)
        model.start()
    }

    private func setWidgetVisible(_ visible: Bool) {
        if visible {
            if widget == nil {
                widget = WidgetPanel(model: model, menu: { [unowned self] in self.contextMenu() })
            }
            widget?.orderFront(nil)
        } else {
            widget?.orderOut(nil)
        }
    }

    // MARK: Menu bar menu

    /// Rebuilt each time it opens, so the items reflect the current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        fill(menu)
    }

    /// The same menu, for a right click on the widget.
    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        fill(menu)
        return menu
    }

    private func fill(_ menu: NSMenu) {
        menu.removeAllItems()
        model.refresh()

        func add(_ title: String, _ action: Selector, key: String = "") {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            menu.addItem(item)
        }

        let status = NSMenuItem(title: statusLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        let awake = NSMenuItem(title: model.awakeLine, action: nil, keyEquivalent: "")
        awake.isEnabled = false
        menu.addItem(awake)
        menu.addItem(.separator())

        add("Refresh now", #selector(refresh))
        let onTop = NSMenuItem(title: "On top", action: #selector(toggleOnTop), keyEquivalent: "")
        onTop.target = self
        onTop.state = model.widgetOnTop ? .on : .off
        menu.addItem(onTop)
        add(model.showWidget ? "Hide" : "Show", #selector(toggleWidget))
        menu.addItem(.separator())
        add("Customers…", #selector(editCustomers))
        add("Since…", #selector(chooseSince))
        if model.since != nil {
            add("Reset since date", #selector(resetSince))
        }
        add("Prices…", #selector(editPrices))
        if model.usingCustomPrices || model.priceProblem != nil {
            add("Reset to built-in prices", #selector(resetPrices))
        }
        menu.addItem(.separator())
        let keepAwake = NSMenuItem(title: "Keep awake", action: nil, keyEquivalent: "")
        keepAwake.submenu = keepAwakeMenu()
        menu.addItem(keepAwake)
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Launch at login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = model.launchAtLogin ? .on : .off
        menu.addItem(login)
        add("Quit", #selector(quit), key: "q")
    }

    private var statusLine: String {
        if let problem = model.priceProblem { return problem }
        if let missing = model.snapshot.unpricedModels.first { return "No price for " + missing }
        if model.loading { return "Scanning…" }
        let stamp = Dates.clock.string(from: Date(timeIntervalSince1970: model.snapshot.generatedAt))
        return "Updated " + stamp + (model.usingCustomPrices ? " · custom prices" : "")
    }

    /// Sleep settings, and the Claude Code hook they depend on.
    private func keepAwakeMenu() -> NSMenu {
        let sub = NSMenu()
        func toggle(_ title: String, _ on: Bool, _ action: Selector, tag: Int = 0) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.state = on ? .on : .off
            item.tag = tag
            sub.addItem(item)
        }
        toggle("Working", model.keepAwake, #selector(toggleKeepAwake))
        toggle("Approving", model.keepAwakeWhileWaiting, #selector(toggleKeepAwakeWaiting))
        toggle("On battery", model.keepAwakeOnBattery, #selector(toggleKeepAwakeBattery))
        sub.addItem(.separator())
        let grace = NSMenuItem(title: "Linger for", action: nil, keyEquivalent: "")
        grace.isEnabled = false
        sub.addItem(grace)
        for minutes in AppModel.graceChoices {
            toggle("\(minutes) minutes", model.graceMinutes == minutes, #selector(chooseGrace(_:)), tag: minutes)
        }
        sub.addItem(.separator())
        let hook = NSMenuItem(title: model.hookInstalled ? "Remove hook" : "Install hook",
                              action: #selector(toggleHook), keyEquivalent: "")
        hook.target = self
        sub.addItem(hook)
        return sub
    }

    @objc private func refresh() { model.refresh() }
    @objc private func toggleWidget() { model.showWidget.toggle() }
    @objc private func editCustomers() { model.editCustomers() }
    @objc private func toggleOnTop() { model.widgetOnTop.toggle() }
    @objc private func chooseSince() { model.chooseSince() }
    @objc private func resetSince() { model.resetSince() }
    @objc private func editPrices() { model.editPrices() }
    @objc private func resetPrices() { model.resetPrices() }
    @objc private func toggleLaunchAtLogin() { model.setLaunchAtLogin(!model.launchAtLogin) }
    @objc private func toggleKeepAwake() { model.keepAwake.toggle() }
    @objc private func toggleKeepAwakeWaiting() { model.keepAwakeWhileWaiting.toggle() }
    @objc private func toggleKeepAwakeBattery() { model.keepAwakeOnBattery.toggle() }
    @objc private func chooseGrace(_ sender: NSMenuItem) { model.graceMinutes = sender.tag }
    @objc private func toggleHook() { model.setHookInstalled(!model.hookInstalled) }
    @objc private func quit() { model.quit() }
}
