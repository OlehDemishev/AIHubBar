import AppKit
import SwiftUI

/// A module's screens (docs/specs/SPEC-refactor.md §3), next to its `ModuleDefinition` in the module's file: the sections
/// of its Settings page and its line in «Панель сейчас». The panel card itself is still drawn by `MenuPanelView`.
@MainActor
struct ModuleUI {
    /// The module's own sections on its Settings page; nil — it has none.
    var settings: (() -> AnyView)?
    /// What its block shows right now, in one line, for the panel builder's preview; nil — its tagline.
    var sketch: (() -> AnyView)?

    static func of(_ kind: ModuleKind) -> ModuleUI {
        switch kind {
        case .limits: .limits
        case .sessions: .sessions
        case .upcoming: .upcoming
        case .projects: .projects
        case .reports: .reports
        case .resources: .resources
        case .keepAwake: .keepAwake
        case .quickCommands: .quickCommands
        case .toggles: .toggles
        case .clipboard: .clipboard
        case .notes: .notes
        case .notch: .notch
        case .layout: .layout
        case .quickPrompt: .quickPrompt
        case .telegram: .telegram
        }
    }
}

/// One line of «Панель сейчас».
struct SketchLine: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
    }
}

/// A limit as the panel draws it: a thin bar coloured by level and its percent.
struct MiniRing: View {
    let value: Double

    var body: some View {
        HStack(spacing: 4) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: min(value, 100) / 100)
                    .stroke(UsageLevel(value).color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 13, height: 13)
            Text("\(Int(value.rounded())) %").font(.system(size: 10.5, weight: .medium)).monospacedDigit()
        }
    }

}
