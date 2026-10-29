import AppKit
import SwiftUI

/// The menu bar label. It is the one view that lives as long as the app, so it also opens windows
/// requested while the panel is closed (cleanup check output, `--app-command help`).
struct MenuBarLabel: View {
    let state: MenuBarState

    @Environment(AppRequests.self) private var requests
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuBarIcon(state: state)
            .onChange(of: requests.window) {
                guard let id = requests.window?.id else { return }
                NSApp.activate()
                openWindow(id: id)
            }
    }
}

/// Everything the menu bar item shows.
struct MenuBarState: Hashable {
    var showsAlert = false
    var waitingCount = 0
    var mode: MenuBarUsageMode = .iconOnly
    var session: Double?
    var week: Double?

    /// Nothing besides the bare symbol to draw.
    var isPlain: Bool {
        !showsAlert && waitingCount == 0 && (mode == .iconOnly || session == nil)
    }

    var accessibilityText: String {
        var parts = ["ClaudePult"]
        if mode != .iconOnly, let session { parts.append("сессия \(Int(session.rounded())) %") }
        if mode == .sessionAndWeek, let week { parts.append("неделя \(Int(week.rounded())) %") }
        if showsAlert { parts.append("есть проекты с проблемами") }
        if waitingCount > 0 { parts.append("ждут ответа: \(waitingCount)") }
        return parts.joined(separator: ", ")
    }
}

/// The sparkle, a red dot for red projects, usage (percent or ring, coloured green/orange/red) and the number of
/// waiting sessions — drawn as one non-template image, because `MenuBarExtra` turns template labels monochrome.
struct MenuBarIcon: View {
    let state: MenuBarState

    var body: some View {
        Group {
            if state.isPlain {
                Image(systemName: "sparkle")
            } else {
                Image(nsImage: MenuBarRenderer.image(for: state))
            }
        }
        .accessibilityLabel(state.accessibilityText)
    }
}

@MainActor
enum MenuBarRenderer {
    private static var cache: [MenuBarState: NSImage] = [:]

    static func image(for state: MenuBarState) -> NSImage {
        if let cached = cache[state] { return cached }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        var parts: [(String, NSColor)] = []
        if state.mode == .session || state.mode == .sessionAndWeek, let session = state.session {
            parts.append(("\(Int(session.rounded()))%", color(session)))
        }
        if state.mode == .sessionAndWeek, let week = state.week {
            parts.append((" · ", .labelColor))
            parts.append(("\(Int(week.rounded()))%", color(week)))
        }
        if state.waitingCount > 0 {
            // ✋ marks the waiting count so it is not read as part of the percentages.
            parts.append(((parts.isEmpty ? "" : " ") + "✋\(state.waitingCount)", .labelColor))
        }
        let ring = state.mode == .ring ? state.session : nil

        let iconWidth: CGFloat = 16
        let ringWidth: CGFloat = ring == nil ? 0 : 16
        let textWidths = parts.map { ($0.0 as NSString).size(withAttributes: [.font: font]).width }
        let textWidth = textWidths.reduce(0, +)
        let width = iconWidth + (ringWidth > 0 ? 3 + ringWidth : 0) + (textWidth > 0 ? 3 + textWidth : 0)
        let height: CGFloat = 16

        let image = NSImage(size: NSSize(width: ceil(width), height: height), flipped: false) { rect in
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.labelColor]))
            if let symbol = NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let size = symbol.size
                symbol.draw(in: NSRect(x: (iconWidth - size.width) / 2, y: (height - size.height) / 2, width: size.width, height: size.height))
            }
            if state.showsAlert {
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: NSRect(x: iconWidth - 5, y: 0.5, width: 5.5, height: 5.5)).fill()
            }
            var x = iconWidth
            if let ring {
                x += 3
                let box = NSRect(x: x + 1, y: 1, width: 14, height: 14).insetBy(dx: 1.25, dy: 1.25)
                let track = NSBezierPath(ovalIn: box)
                track.lineWidth = 2.5
                NSColor.labelColor.withAlphaComponent(0.25).setStroke()
                track.stroke()
                let arc = NSBezierPath()
                arc.appendArc(withCenter: NSPoint(x: box.midX, y: box.midY), radius: box.width / 2,
                              startAngle: 90, endAngle: 90 - 360 * min(max(ring, 0), 100) / 100, clockwise: true)
                arc.lineWidth = 2.5
                arc.lineCapStyle = .round
                color(ring).setStroke()
                arc.stroke()
                x += ringWidth
            }
            if textWidth > 0 {
                x += 3
                for (index, part) in parts.enumerated() {
                    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: part.1]
                    let size = (part.0 as NSString).size(withAttributes: attributes)
                    (part.0 as NSString).draw(at: NSPoint(x: x, y: (rect.height - size.height) / 2), withAttributes: attributes)
                    x += textWidths[index]
                }
            }
            return true
        }
        image.isTemplate = false
        if cache.count > 200 { cache.removeAll() }
        cache[state] = image
        return image
    }

    static func color(_ percent: Double) -> NSColor {
        switch UsageLevel(percent) {
        case .low: .systemGreen
        case .medium: .systemOrange
        case .high: .systemRed
        }
    }
}
