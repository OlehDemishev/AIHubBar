import AppKit
import SwiftUI

/// Menu bar icon: the sparkle symbol, with a red dot when any project's health is red.
struct MenuBarIcon: View {
    let showsAlert: Bool

    var body: some View {
        if showsAlert {
            Image(nsImage: Self.alertImage)
                .accessibilityLabel("ClaudePult: есть проекты с проблемами")
        } else {
            Image(systemName: "sparkle")
                .accessibilityLabel("ClaudePult")
        }
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
