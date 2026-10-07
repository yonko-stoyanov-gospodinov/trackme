import AppKit

// Run as a Claude Code hook: record the event and exit, without starting the app.
if CommandLine.arguments.dropFirst().contains("--hook") {
    HookCommand.run()
}

// Menu bar app with a widget popover: no Dock icon, no main window.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
