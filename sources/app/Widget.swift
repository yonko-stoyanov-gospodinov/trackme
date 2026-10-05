import AppKit
import SwiftUI

/// A borderless panel that sits on the desktop, under normal windows, like a widget.
final class WidgetPanel: NSPanel {
    static let width: CGFloat = 320
    static let cornerRadius: CGFloat = 18
    /// The dark frosted glass of HUD panels, whatever the system appearance.
    static let material: NSVisualEffectView.Material = .hudWindow

    /// `menu` builds the context menu for a right click; it is the menu bar menu.
    init(model: AppModel, menu: @escaping () -> NSMenu) {
        // The panel is as tall as its content, so the margins match top and bottom.
        let hosting = WidgetHostingView(rootView: WidgetView(model: model))
        hosting.contextMenu = menu
        let size = NSSize(width: WidgetPanel.width, height: ceil(hosting.fittingSize.height))
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        setOnTop(model.widgetOnTop)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        // The HUD material has a fixed tint; fading the whole panel lets more of the desktop through.
        alphaValue = 0.82

        let effect = NSVisualEffectView()
        effect.material = WidgetPanel.material
        effect.blendingMode = .behindWindow
        effect.state = .active
        // The HUD material is dark whatever the system appearance, so the text follows it.
        effect.appearance = NSAppearance(named: .darkAqua)
        // A behind-window blur is drawn by the window server over the whole window rectangle,
        // so rounding the layer leaves square corners; a mask image clips the blur and the shadow.
        effect.maskImage = WidgetPanel.roundedMask(radius: WidgetPanel.cornerRadius)

        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        contentView = effect

        // Remember where the user dragged it; the first time, put it in the top right corner.
        if setFrameUsingName("trackme.widget") {
            // The saved frame may be from a version with a different size.
            let top = frame.maxY
            setContentSize(size)
            setFrameOrigin(NSPoint(x: frame.minX, y: top - size.height))
        } else if let screen = NSScreen.main?.visibleFrame {
            setFrameOrigin(NSPoint(x: screen.maxX - size.width - 20, y: screen.maxY - size.height - 20))
        }
        setFrameAutosaveName("trackme.widget")
        invalidateShadow()
    }

    /// Above every normal window, or on the desktop just over the icons.
    func setOnTop(_ onTop: Bool) {
        level = onTop ? .floating : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    }

    override var canBecomeKey: Bool { return false }
    override var canBecomeMain: Bool { return false }

    /// A stretchable rounded-rectangle mask: only the corners are fixed, the middle scales.
    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Takes the first click even though the panel never becomes key, so the tabs work.
/// Moving the window is a gesture in the view, not a window-background drag, because a
/// background drag would take every mouse-down and the tabs would never get one.
/// A right click or a control-click shows the context menu, built fresh each time.
final class WidgetHostingView<Content: View>: NSHostingView<Content> {
    var contextMenu: (() -> NSMenu)?

    override var mouseDownCanMoveWindow: Bool { return false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }

    override func rightMouseDown(with event: NSEvent) {
        showContextMenu(for: event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            showContextMenu(for: event)
        } else {
            super.mouseDown(with: event)
        }
    }

    private func showContextMenu(for event: NSEvent) {
        guard let menu = contextMenu?() else { return }
        HintWindow.shared.hide()
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

struct WidgetView: View {
    @ObservedObject var model: AppModel

    @StateObject private var dragStart = LocalState<(mouse: NSPoint, origin: NSPoint)?>(nil)

    private var activeCount: Int {
        return model.snapshot.sessions.filter { model.isActive($0) }.count
    }

    private var awakeHelp: String {
        if model.busyCount > 0 { return "Keeping the Mac awake while Claude Code works. The screen can still lock." }
        return "Keeping the Mac awake for \(model.graceMinutes) more minutes at most, in case Claude Code continues."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Eyebrow(text: "trackme")
                Spacer()
                if model.busyCount > 0 {
                    HStack(spacing: 5) {
                        ActiveDot()
                        Eyebrow(text: "\(model.busyCount) working", color: Theme.accent)
                    }
                    .hint(model.busyCount == 1 ? "One Claude Code session is working on a request"
                                               : "\(model.busyCount) Claude Code sessions are working on requests")
                } else if activeCount > 0 {
                    HStack(spacing: 5) {
                        ActiveDot()
                        Eyebrow(text: "\(activeCount) active", color: Theme.accent)
                    }
                    .hint(activeCount == 1 ? "One session used the API in the last 5 minutes"
                                           : "\(activeCount) sessions used the API in the last 5 minutes")
                }
                if model.holdingAwake {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Theme.accent)
                        .hint(awakeHelp)
                }
            }

            CustomerTabs(choices: model.customerChoices, selection: $model.customerFilter)

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    let main = model.sinceTotals ?? model.totals(.today)
                    Text(model.loading ? "…" : Format.money(main.cost))
                        .font(Theme.figure(32))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Eyebrow(text: model.since == nil ? "Today" : model.sinceLabel)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    WidgetTotal(label: "7 days", value: model.totals(.week).cost)
                    WidgetTotal(label: "30 days", value: model.totals(.month).cost)
                }
            }
        }
        .foregroundColor(Theme.ink)
        .padding(16)
        .frame(width: WidgetPanel.width)
        .contentShape(Rectangle())
        .gesture(windowDrag)
    }

    /// Moves the panel with the mouse. Screen coordinates are used because the view's own
    /// coordinates move along with the window.
    private var windowDrag: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { _ in
                HintWindow.shared.hide()
                guard let window = NSApp.windows.first(where: { $0 is WidgetPanel }) else { return }
                let mouse = NSEvent.mouseLocation
                let start = dragStart.value ?? (mouse, window.frame.origin)
                dragStart.value = start
                window.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x,
                                              y: start.origin.y + mouse.y - start.mouse.y))
            }
            .onEnded { _ in dragStart.value = nil }
    }
}

struct WidgetTotal: View {
    let label: String
    let value: Double

    var body: some View {
        HStack(spacing: 8) {
            Eyebrow(text: label)
            Text(Format.money(value))
                .font(Theme.figure(13))
                .monospacedDigit()
                .frame(minWidth: 56, alignment: .trailing)
        }
    }
}
