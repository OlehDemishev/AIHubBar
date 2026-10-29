import AppKit
import SwiftUI

/// The menu bar label. It is the one view that lives as long as the app, so it also opens windows
/// requested by background work (the cleanup check output) when the panel is closed.
struct MenuBarLabel: View {
    let showsAlert: Bool
    let waitingCount: Int

    @Environment(CommandStore.self) private var commands
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuBarIcon(showsAlert: showsAlert, waitingCount: waitingCount)
            .onChange(of: commands.cleanupWindowRequest) {
                NSApp.activate()
                openWindow(id: "cleanup-output")
            }
    }
}

/// Menu bar icon: the sparkle symbol, a red dot when any project's health is red,
/// and the number of sessions waiting for Oleh's answer.
struct MenuBarIcon: View {
    let showsAlert: Bool
    let waitingCount: Int

    var body: some View {
        HStack(spacing: 3) {
            if showsAlert {
                Image(nsImage: Self.alertImage)
            } else {
                Image(systemName: "sparkle")
            }
            if waitingCount > 0 {
                Text("\(waitingCount)")
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = ["ClaudePult"]
        if showsAlert { parts.append("есть проекты с проблемами") }
        if waitingCount > 0 { parts.append("ждут ответа: \(waitingCount)") }
        return parts.joined(separator: ", ")
    }

    /// Drawn on demand, so the symbol follows the menu bar's light/dark appearance
    /// while the dot stays red (a template image would turn the dot monochrome).
    @MainActor private static let alertImage: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 16), flipped: false) { rect in
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.labelColor]))
            if let symbol = NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                let size = symbol.size
                symbol.draw(in: NSRect(
                    x: (rect.width - 4 - size.width) / 2,
                    y: (rect.height - size.height) / 2,
                    width: size.width,
                    height: size.height
                ))
            }
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - 7, y: 1, width: 6, height: 6)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }()
}
