import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private let model = AppModel()
    private var popover: NSPopover?
    private var outsideClick: Any?
    private var titleObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            // No icon: the item is the spend of the chosen customer, as text.
            button.setAccessibilityLabel("Claude Code usage")
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
            // A left click pops the widget up under the item, a right click opens the menu. The
            // menu is not attached to the item, because then every click would open it.
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        menu.delegate = self
        // objectWillChange fires before the model changes; the hop to the next run loop pass
        // reads the new values.
        titleObserver = model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateTitle() }
        updateTitle()
        model.start()
    }

    /// The spend of the customer chosen in the popover, all time or since the chosen day, as
    /// in the status line. An ellipsis until the first scan is done, so the item has a width.
    private func updateTitle() {
        guard let button = statusItem?.button else { return }
        if model.snapshot.generatedAt == 0 {
            button.title = "…"
            return
        }
        let total = model.sinceTotals ?? model.totals(.all)
        button.title = Format.money(total.cost)
    }

    // MARK: Menu bar item

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            togglePopover()
        }
    }

    /// Attaching the menu makes the button track it like a normal status item; it is detached
    /// again right after so that the next left click reaches the action.
    private func showMenu() {
        guard let item = statusItem else { return }
        popover?.close()
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    /// The widget in a popover under the item, closed by a click anywhere else.
    private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if let popover = popover, popover.isShown {
            popover.close()
            return
        }
        let popover = self.popover ?? makePopover()
        self.popover = popover
        model.refresh()
        // A transient popover only closes itself on an outside click while the app is active,
        // and since macOS 14 this request is often refused when another app is in front. The
        // global monitor installed in popoverDidShow closes it whatever the activation did.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    /// Clicks in other apps never reach this app's event queue, so they are watched globally.
    /// Clicks inside the app (the popover, the menu bar item) are handled as before.
    func popoverDidShow(_ notification: Notification) {
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) {
            [weak self] _ in
            self?.popover?.close()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        if let monitor = outsideClick {
            NSEvent.removeMonitor(monitor)
            outsideClick = nil
        }
    }

    private func makePopover() -> NSPopover {
        let hosting = WidgetHostingView(rootView: WidgetView(model: model))
        hosting.contextMenu = { [unowned self] in self.contextMenu() }
        let controller = NSViewController()
        controller.view = hosting
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: Widget.width, height: ceil(hosting.fittingSize.height))
        popover.behavior = .transient
        popover.animates = true
        // The same dark glass as the hints and the dialogs.
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self
        return popover
    }

    func popoverWillClose(_ notification: Notification) {
        HintWindow.shared.hide()
    }

    // MARK: Menu bar menu

    /// Rebuilt each time it opens, so the items reflect the current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        fill(menu)
    }

    /// The same menu, for a right click inside the popover.
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
    @objc private func editCustomers() { model.editCustomers() }
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
