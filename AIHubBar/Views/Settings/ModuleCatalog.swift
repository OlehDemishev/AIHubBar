import SwiftUI

/// The ready-made sets of modules, offered on «Что показывать».
enum ModuleCatalog {
    /// A set switches its modules on and the rest off; modules without a switch are left alone.
    enum Preset: CaseIterable {
        case ai, layout, mac, everything

        var title: String {
            switch self {
            case .ai: String(localized: "Только AI")
            case .layout: String(localized: "Только раскладка")
            case .mac: String(localized: "Утилиты Mac")
            case .everything: String(localized: "Всё")
            }
        }

        var symbol: String {
            switch self {
            case .ai: "sparkles"
            case .layout: "keyboard"
            case .mac: "laptopcomputer"
            case .everything: "square.grid.3x3.fill"
            }
        }

        func includes(_ kind: ModuleKind) -> Bool {
            switch self {
            case .ai: kind.group == .ai
            case .layout: kind == .layout
            case .mac: kind.group == .mac
            case .everything: true
            }
        }
    }
}
