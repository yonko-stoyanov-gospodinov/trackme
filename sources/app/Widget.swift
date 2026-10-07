import AppKit
import SwiftUI

/// The look shared by the widget popover, the hints and the dialogs.
enum Widget {
    static let width: CGFloat = 320
    static let cornerRadius: CGFloat = 18
    /// The dark frosted glass of HUD panels, whatever the system appearance.
    static let material: NSVisualEffectView.Material = .hudWindow

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

/// Hosts the widget content in the popover under the menu bar item. Takes the first click so
/// the tabs work as soon as the popover opens. A right click or a control-click shows the
/// context menu, built fresh each time.
final class WidgetHostingView<Content: View>: NSHostingView<Content> {
    var contextMenu: (() -> NSMenu)?

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

/// The widget's content: the spend of the chosen customer and who is working.
struct WidgetView: View {
    @ObservedObject var model: AppModel

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
        .frame(width: Widget.width)
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
