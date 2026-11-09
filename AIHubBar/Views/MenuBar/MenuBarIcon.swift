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
            .onChange(of: requests.window) { openRequested() }
            .onAppear(perform: openRequested)
    }
}

extension MenuBarLabel {
    /// Opens the requested window — also one asked for before this label appeared (the notch's first setup).
    fileprivate func openRequested() {
        guard let id = requests.takeWindow() else { return }
        NSApp.activate()
        if id == .settings { openSettings() } else { openWindow(id) }
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
        MenuBarItemImage(config: state.config, data: state.data)
        .accessibilityLabel(MenuBarComposer.accessibilityText(state.config, state.data))
        .task(id: MenuBarComposer.accessibilityText(state.config, state.data)) {
            // The status item exists a moment after launch.
            try? await Task.sleep(for: .milliseconds(500))
            StatusItemTooltip.set(MenuBarComposer.accessibilityText(state.config, state.data))
        }
    }
}

/// The item as an image: a template symbol when it is a lone symbol, else the drawn strip. Also the previews in
/// Settings and the assistant.
struct MenuBarItemImage: View {
    let config: MenuBarConfig
    let data: MenuBarData

    var body: some View {
        let strip = MenuBarComposer.strip(config, data)
        if let symbol = MenuBarComposer.plainSymbol(strip, look: config.look) {
            Image(systemName: symbol)
        } else {
            Image(nsImage: MenuBarRenderer.image(strip, config: config))
        }
    }
}

/// `MenuBarExtra` has no tooltip of its own: the item is an `NSStatusBarButton` in the app's status bar window, and
/// hovering over it shows what the icons and numbers mean.
@MainActor
enum StatusItemTooltip {
    private static var text: String?
    /// The open panel says all of it already, and the tooltip would come up over its title.
    static var panelIsOpen = false { didSet { apply() } }

    static func set(_ text: String) {
        self.text = text
        apply()
    }

    private static func apply() {
        statusButton()?.toolTip = panelIsOpen ? nil : text
    }

    static func statusButton() -> NSButton? {
        let items = NSApp.windows.filter { $0.className.contains("StatusBarWindow") }
        return PanelOpener.panelItem(among: items, other: PanelOpener.otherItemWindow()).flatMap { button(in: $0.contentView) }
    }

    private static func button(in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton { return button }
        return view.subviews.lazy.compactMap { button(in: $0) }.first
    }
}

@MainActor
enum MenuBarRenderer {
    private struct Key: Hashable {
        var strip: [MenuBarPiece]
        var separator: MenuBarConfig.Separator
        var smallText: Bool
        var look: MenuBarConfig.Look
    }

    private static var cache: [Key: NSImage] = [:]

    /// Wider than this and a MacBook with a notch may hide the item (SPEC-modes §7).
    static let wideWidth: CGFloat = 180

    static func image(_ strip: [MenuBarPiece], config: MenuBarConfig) -> NSImage {
        let key = Key(strip: strip, separator: config.separator, smallText: config.smallText, look: config.look)
        if let cached = cache[key] { return cached }
        let layout = Layout(strip: strip, separator: config.separator, small: config.smallText, look: config.look)
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
        let strip = MenuBarComposer.strip(config, data)
        if MenuBarComposer.plainSymbol(strip, look: config.look) != nil { return 16 }
        return Layout(strip: strip, separator: config.separator, small: config.smallText, look: config.look).width
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
        /// Inside a capsule, from its edge to the first and last piece.
        static let capsulePadding: CGFloat = 4

        enum Piece {
            case symbol(String, size: CGFloat, NSColor)
            case dot(standalone: Bool)
            case text(String, NSColor)
            case ring(Double, NSColor)
            case bar(Double, NSColor)
            case line
            case space(CGFloat)
        }

        let font: NSFont
        let symbolSize: CGFloat
        var pieces: [(Piece, CGFloat)] = []
        /// Piece ranges drawn on a rounded backing («Капсулы по группам»).
        var capsules: [Range<Int>] = []

        init(strip: [MenuBarPiece], separator: MenuBarConfig.Separator, small: Bool, look: MenuBarConfig.Look) {
            font = NSFont.monospacedDigitSystemFont(ofSize: small ? 10 : 12, weight: .medium)
            symbolSize = small ? 11 : 13
            var capsuleStart: Int?
            func openCapsule() {
                capsuleStart = pieces.count
                add(.space(Self.capsulePadding))
            }
            func closeCapsule() {
                guard let start = capsuleStart else { return }
                add(.space(Self.capsulePadding))
                capsules.append(start..<pieces.count)
                capsuleStart = nil
            }
            if look == .capsules { openCapsule() }
            for piece in strip {
                switch piece {
                case let .group(group): addGroup(group)
                case .separator: add(.text(separator.text, .labelColor))
                case .gap: add(.space(Self.gap))
                case let .divider(style):
                    switch style {
                    case .space: add(.space(6))
                    case .wideSpace: add(.space(14))
                    case .dot: add(.text(" · ", .secondaryLabelColor))
                    case .bar: add(.text(" | ", .secondaryLabelColor))
                    case .slash: add(.text(" / ", .secondaryLabelColor))
                    case .chevron: add(.text(" › ", .secondaryLabelColor))
                    case .line: add(.line)
                    case .group:
                        if look == .capsules {
                            closeCapsule()
                            add(.space(Self.gap))
                            openCapsule()
                        } else {
                            add(.space(10))
                        }
                    }
                }
            }
            if look == .capsules { closeCapsule() }
        }

        private mutating func addGroup(_ group: [MenuBarSegment]) {
            for (position, segment) in group.enumerated() {
                switch segment {
                case let .symbol(name): add(.symbol(name, size: symbolSize, .labelColor))
                case let .tintedSymbol(name, tint): add(.symbol(name, size: symbolSize, MenuBarRenderer.color(tint)))
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

        var width: CGFloat { max(pieces.reduce(0) { $0 + $1.1 }, 1) }

        private mutating func add(_ piece: Piece) {
            let width: CGFloat = switch piece {
            // The main icon gets the usual menu bar room; counter symbols sit tight against their number.
            case let .symbol(name, size, _): symbolImage(name, size: size, color: .labelColor).map { size < symbolSize ? $0.size.width : max($0.size.width, size + 3) } ?? 0
            case let .dot(standalone): standalone ? 7 : 0
            case let .text(text, _): (text as NSString).size(withAttributes: [.font: font]).width
            case .ring: 14
            case .bar: 22
            case .line: 9
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
            var starts: [CGFloat] = []
            var x: CGFloat = 0
            for (_, width) in pieces {
                starts.append(x)
                x += width
            }
            for capsule in capsules where !capsule.isEmpty {
                let left = starts[capsule.lowerBound]
                let right = starts[capsule.upperBound - 1] + pieces[capsule.upperBound - 1].1
                NSColor.labelColor.withAlphaComponent(0.14).setFill()
                NSBezierPath(roundedRect: NSRect(x: left, y: 0, width: right - left, height: height), xRadius: 4.5, yRadius: 4.5).fill()
            }
            for ((piece, width), x) in zip(pieces, starts) {
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
                case .line:
                    NSColor.labelColor.withAlphaComponent(0.35).setFill()
                    NSRect(x: x + width / 2 - 0.5, y: 2.5, width: 1, height: height - 5).fill()
                case .space:
                    break
                }
            }
        }
    }
}

/// Free space on the system volume, when the resources monitor has no reading yet. Read at most every 5 minutes.
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
