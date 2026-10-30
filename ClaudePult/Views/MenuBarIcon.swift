import AppKit
import SwiftUI

/// The menu bar label. It is the one view that lives as long as the app, so it also opens windows
/// requested while the panel is closed (cleanup check output, `--app-command help`).
struct MenuBarLabel: View {
    let state: MenuBarState

    @Environment(AppRequests.self) private var requests
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    /// Ticks once a minute while the reset countdown is shown.
    @State private var minute = Date.now

    var body: some View {
        var shown = state
        shown.data.now = minute
        let ticks = state.config.element(.resetCountdown).enabled
        return MenuBarIcon(state: shown)
            .task(id: ticks) {
                while ticks, !Task.isCancelled {
                    minute = .now
                    try? await Task.sleep(for: .seconds(60 - Double(Calendar.current.component(.second, from: .now))))
                }
            }
            .onChange(of: requests.window) {
                guard let id = requests.window?.id else { return }
                NSApp.activate()
                if id == "settings" { openSettings() } else { openWindow(id: id) }
            }
    }
}

/// Everything the menu bar item shows: what to show (the builder config) and the data to show.
struct MenuBarState: Hashable {
    var config: MenuBarConfig
    var data: MenuBarData
}

/// The menu bar item drawn from `MenuBarComposer` segments — one non-template image, because `MenuBarExtra`
/// turns template labels monochrome. A lone symbol stays a template image, like a system item.
struct MenuBarIcon: View {
    let state: MenuBarState

    var body: some View {
        let groups = MenuBarComposer.groups(state.config, state.data)
        Group {
            if let symbol = MenuBarComposer.plainSymbol(groups) {
                Image(systemName: symbol)
            } else {
                Image(nsImage: MenuBarRenderer.image(groups, config: state.config))
            }
        }
        .accessibilityLabel(MenuBarComposer.accessibilityText(state.config, state.data))
    }
}

@MainActor
enum MenuBarRenderer {
    private struct Key: Hashable {
        var groups: [[MenuBarSegment]]
        var separator: MenuBarConfig.Separator
        var smallText: Bool
    }

    private static var cache: [Key: NSImage] = [:]

    /// Wider than this and a MacBook with a notch may hide the item (SPEC-modes §7).
    static let wideWidth: CGFloat = 180

    static func image(_ groups: [[MenuBarSegment]], config: MenuBarConfig) -> NSImage {
        let key = Key(groups: groups, separator: config.separator, smallText: config.smallText)
        if let cached = cache[key] { return cached }
        let layout = Layout(groups: groups, separator: config.separator, small: config.smallText)
        let image = NSImage(size: NSSize(width: ceil(layout.width), height: Layout.height), flipped: false) { _ in
            layout.draw()
            return true
        }
        image.isTemplate = false
        if cache.count > 200 { cache.removeAll() }
        cache[key] = image
        return image
    }

    static func width(_ config: MenuBarConfig, _ data: MenuBarData) -> CGFloat {
        let groups = MenuBarComposer.groups(config, data)
        if MenuBarComposer.plainSymbol(groups) != nil { return 16 }
        return Layout(groups: groups, separator: config.separator, small: config.smallText).width
    }

    nonisolated static func color(_ percent: Double) -> NSColor {
        switch UsageLevel(percent) {
        case .low: .systemGreen
        case .medium: .systemOrange
        case .high: .systemRed
        }
    }

    nonisolated static func color(_ tint: MenuBarSegment.Tint) -> NSColor {
        switch tint {
        case .label: .labelColor
        case .secondary: .secondaryLabelColor
        case let .level(value): color(value)
        case .warning: .systemOrange
        }
    }

    /// Measures every piece once; `draw()` walks the same list.
    private struct Layout {
        static let height: CGFloat = 16
        static let gap: CGFloat = 4

        enum Piece {
            case symbol(String, size: CGFloat, NSColor)
            case dot(standalone: Bool)
            case text(String, NSColor)
            case ring(Double, NSColor)
            case bar(Double, NSColor)
            case space(CGFloat)
        }

        let font: NSFont
        let symbolSize: CGFloat
        var pieces: [(Piece, CGFloat)] = []

        init(groups: [[MenuBarSegment]], separator: MenuBarConfig.Separator, small: Bool) {
            font = NSFont.monospacedDigitSystemFont(ofSize: small ? 10 : 12, weight: .medium)
            symbolSize = small ? 11 : 13
            for (index, group) in groups.enumerated() {
                if index > 0 {
                    if MenuBarComposer.usesSeparator(between: groups[index - 1], and: group) {
                        add(.text(separator.text, .labelColor))
                    } else {
                        add(.space(Self.gap))
                    }
                }
                for (position, segment) in group.enumerated() {
                    switch segment {
                    case let .symbol(name): add(.symbol(name, size: symbolSize, .labelColor))
                    case .dot: add(.dot(standalone: position == 0))
                    case let .text(text, tint): add(.text(text, MenuBarRenderer.color(tint)))
                    case let .labeled(symbol, text, tint):
                        add(.symbol(symbol, size: symbolSize - 2, MenuBarRenderer.color(tint)))
                        add(.space(2))
                        add(.text(text, MenuBarRenderer.color(tint)))
                    case let .ring(value, tint): add(.ring(value, MenuBarRenderer.color(tint)))
                    case let .bar(value, tint): add(.bar(value, MenuBarRenderer.color(tint)))
                    }
                }
            }
        }

        var width: CGFloat { max(pieces.reduce(0) { $0 + $1.1 }, 1) }

        private mutating func add(_ piece: Piece) {
            let width: CGFloat = switch piece {
            // The main icon gets the usual menu bar room; counter symbols sit tight against their number.
            case let .symbol(name, size, _): symbolImage(name, size: size, color: .labelColor).map { size < symbolSize ? $0.size.width : max($0.size.width, size + 3) } ?? 0
            case let .dot(standalone): standalone ? 7 : 0
            case let .text(text, _): (text as NSString).size(withAttributes: [.font: font]).width
            case .ring: 14
            case .bar: 22
            case let .space(width): width
            }
            pieces.append((piece, width))
        }

        private func symbolImage(_ name: String, size: CGFloat, color: NSColor) -> NSImage? {
            let config = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
            return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        }

        func draw() {
            let height = Self.height
            var x: CGFloat = 0
            for (piece, width) in pieces {
                switch piece {
                case let .symbol(name, size, color):
                    if let symbol = symbolImage(name, size: size, color: color) {
                        let s = symbol.size
                        symbol.draw(in: NSRect(x: x + (width - s.width) / 2, y: (height - s.height) / 2, width: s.width, height: s.height))
                    }
                case let .dot(standalone):
                    NSColor.systemRed.setFill()
                    // On the icon: its top-right corner; alone: centred.
                    let rect = standalone
                        ? NSRect(x: x + 0.75, y: (height - 5.5) / 2, width: 5.5, height: 5.5)
                        : NSRect(x: x - 5, y: 0.5, width: 5.5, height: 5.5)
                    NSBezierPath(ovalIn: rect).fill()
                case let .text(text, color):
                    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                    let size = (text as NSString).size(withAttributes: attributes)
                    (text as NSString).draw(at: NSPoint(x: x, y: (height - size.height) / 2), withAttributes: attributes)
                case let .ring(value, color):
                    let box = NSRect(x: x, y: 1, width: 14, height: 14).insetBy(dx: 1.25, dy: 1.25)
                    let track = NSBezierPath(ovalIn: box)
                    track.lineWidth = 2.5
                    NSColor.labelColor.withAlphaComponent(0.25).setStroke()
                    track.stroke()
                    let arc = NSBezierPath()
                    arc.appendArc(withCenter: NSPoint(x: box.midX, y: box.midY), radius: box.width / 2,
                                  startAngle: 90, endAngle: 90 - 360 * min(max(value, 0), 100) / 100, clockwise: true)
                    arc.lineWidth = 2.5
                    arc.lineCapStyle = .round
                    color.setStroke()
                    arc.stroke()
                case let .bar(value, color):
                    let track = NSRect(x: x, y: (height - 5) / 2, width: width, height: 5)
                    NSColor.labelColor.withAlphaComponent(0.25).setFill()
                    NSBezierPath(roundedRect: track, xRadius: 2.5, yRadius: 2.5).fill()
                    let filled = NSRect(x: x, y: track.minY, width: max(5, width * min(max(value, 0), 100) / 100), height: 5)
                    color.setFill()
                    NSBezierPath(roundedRect: filled, xRadius: 2.5, yRadius: 2.5).fill()
                case .space:
                    break
                }
                x += width
            }
        }
    }
}

/// Free space on the system volume, for the menu bar when no report gives it. Read at most every 5 minutes.
@MainActor
enum DiskSpace {
    private static var cached: (bytes: Int64?, at: Date)?

    static func freeBytes(now: Date = .now) -> Int64? {
        if let cached, now.timeIntervalSince(cached.at) < 300 { return cached.bytes }
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let bytes = values?.volumeAvailableCapacityForImportantUsage
        cached = (bytes, now)
        return bytes
    }
}
