import SwiftUI

// Small pieces several screens use (docs/SPEC-refactor.md §5).

/// The tallest content height reported by a view's children — the panel and the notch card size themselves by it.
struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// A white symbol on a coloured rounded tile, like System Settings' icons: Settings' sidebar and headers, module
/// tiles, help topics.
struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(tint.gradient))
            .accessibilityHidden(true)
    }
}

extension UsageLevel {
    /// Green below 50 %, orange to 80 %, red above — limits and Mac resources alike, everywhere in SwiftUI. The menu
    /// bar's AppKit drawing has the same in `MenuBarRenderer.color`.
    var color: Color {
        switch self {
        case .low: .green
        case .medium: .orange
        case .high: .red
        }
    }
}
