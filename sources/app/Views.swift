import AppKit
import SwiftUI

/// The app's look: warm neutrals, one champagne accent, serif figures.
enum Theme {
    static let ink = dynamic(light: 0x1F1C18, dark: 0xFAF7F1)
    static let muted = dynamic(light: 0x7A7268, dark: 0xC2BBB0)
    static let accent = dynamic(light: 0xA9844E, dark: 0xDFC08F)

    static func figure(_ size: CGFloat) -> Font {
        return .system(size: size, weight: .regular, design: .serif)
    }

    private static func dynamic(light: Int, dark: Int, alpha: CGFloat = 1) -> Color {
        let color = NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return rgb(isDark ? dark : light, alpha: alpha)
        }
        return Color(color)
    }

    private static func rgb(_ hex: Int, alpha: CGFloat = 1) -> NSColor {
        return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                       green: CGFloat((hex >> 8) & 0xFF) / 255,
                       blue: CGFloat(hex & 0xFF) / 255,
                       alpha: alpha)
    }
}

/// Small uppercase label with open letter spacing.
struct Eyebrow: View {
    let text: String
    var color: Color = Theme.muted

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(1.3)
            .foregroundColor(color)
            .lineLimit(1)
    }
}

/// Hover hints for the popover, drawn by the app itself so they match its glass: a small
/// label near the pointer after a short hover.
final class HintWindow {
    static let shared = HintWindow()

    private let panel: NSPanel
    private let label: NSTextField
    private var pending: DispatchWorkItem?
    private static let delay = 0.6
    private static let padding = NSSize(width: 9, height: 6)

    private init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]

        let glass = NSVisualEffectView()
        glass.material = Widget.material
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.appearance = NSAppearance(named: .darkAqua)
        glass.maskImage = Widget.roundedMask(radius: 6)
        label = NSTextField(wrappingLabelWithString: "")
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = NSColor(white: 0.96, alpha: 1)
        label.preferredMaxLayoutWidth = 260
        glass.addSubview(label)
        panel.contentView = glass
    }

    func schedule(_ text: String) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.show(text) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + HintWindow.delay, execute: work)
    }

    func hide() {
        pending?.cancel()
        pending = nil
        panel.orderOut(nil)
    }

    private func show(_ text: String) {
        label.stringValue = text
        let fit = label.sizeThatFits(NSSize(width: 260, height: 400))
        let size = NSSize(width: fit.width + HintWindow.padding.width * 2, height: fit.height + HintWindow.padding.height * 2)
        label.frame = NSRect(x: HintWindow.padding.width, y: HintWindow.padding.height, width: fit.width, height: fit.height)
        panel.setContentSize(size)

        // Below and to the right of the pointer, kept on the screen the pointer is on.
        let mouse = NSEvent.mouseLocation
        var origin = NSPoint(x: mouse.x + 10, y: mouse.y - size.height - 16)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main {
            let area = screen.visibleFrame
            if origin.x + size.width > area.maxX { origin.x = mouse.x - size.width - 10 }
            if origin.y < area.minY { origin.y = mouse.y + 16 }
        }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
    }
}

private struct Hint: ViewModifier {
    let text: String

    func body(content: Content) -> some View {
        content.onHover { inside in
            if inside { HintWindow.shared.schedule(text) } else { HintWindow.shared.hide() }
        }
    }
}

extension View {
    /// A hover hint that works in the widget, where `.help` never shows.
    func hint(_ text: String) -> some View {
        return modifier(Hint(text: text))
    }
}

struct ActiveDot: View {
    var body: some View {
        Circle()
            .fill(Theme.accent)
            .frame(width: 5, height: 5)
    }
}

/// Text tabs with a gold underline under the chosen customer.
struct CustomerTabs: View {
    let choices: [CustomerChoice]
    @Binding var selection: CustomerFilter

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(choices) { choice in
                    let chosen = choice.filter == selection
                    Button(action: { selection = choice.filter }) {
                        VStack(spacing: 4) {
                            Eyebrow(text: choice.label, color: chosen ? Theme.ink : Theme.muted)
                            Rectangle()
                                .fill(chosen ? Theme.accent : Color.clear)
                                .frame(height: 1)
                        }
                        .fixedSize()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
    }
}
