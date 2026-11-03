import SwiftUI

/// Settings → «Модули» (SPEC-settings §3): ready-made sets on top, then a tile per module by section.
struct ModuleCatalog: View {
    let open: (ModuleKind) -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(ModeStore.self) private var modes

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

    private let columns = [GridItem(.adaptive(minimum: 196, maximum: 320), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 8) {
                    ForEach(presets, id: \.self) { preset in
                        Button { apply(preset) } label: {
                            Label(preset.title, systemImage: preset.symbol)
                                .padding(.horizontal, 4)
                        }
                        .controlSize(.large)
                        .help(String(localized: "Включить модули набора и выключить остальные"))
                    }
                    Spacer(minLength: 0)
                    Text("Включено: \(onCount) из \(listed.count)")
                        .foregroundStyle(.secondary)
                }
                ForEach(ModuleGroup.allCases, id: \.self) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 7) {
                            RoundedRectangle(cornerRadius: 3).fill(group.tint.gradient).frame(width: 11, height: 11)
                            Text(group.title).font(.system(size: 15, weight: .semibold))
                        }
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                            ForEach(group.modules.filter { listed.contains($0) }, id: \.self) { kind in
                                ModuleTile(kind: kind, open: { open(kind) })
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
    }

    private var listed: [ModuleKind] { ModuleKind.allCases.filter { !$0.isBeta || settings.betaUpdates } }
    private var onCount: Int { listed.filter(modes.isOn).count }
    private var presets: [Preset] { Preset.allCases.filter { $0 != .layout || settings.betaUpdates } }

    private func apply(_ preset: Preset) {
        for kind in listed where ModuleSwitch.canSwitch(kind, modes: modes) || !kind.isBuiltIn {
            let on = preset.includes(kind)
            if modes.isOn(kind) != on { modes.setOn(kind, on) }
        }
    }
}

/// A module's tile: icon, name, one line and its main switch; a click opens the module's page.
struct ModuleTile: View {
    let kind: ModuleKind
    let open: () -> Void

    @Environment(ModeStore.self) private var modes
    @State private var hovering = false

    var body: some View {
        let on = modes.isOn(kind)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                PaneIcon(pane: .module(kind), size: 34)
                Spacer()
                if ModuleSwitch.canSwitch(kind, modes: modes) {
                    Toggle(kind.title, isOn: Binding(get: { on }, set: { modes.setOn(kind, $0) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                }
            }
            HStack(spacing: 6) {
                Text(kind.title).font(.system(size: 14, weight: .semibold))
                if kind.isBeta { BetaBadge() }
            }
            if let action = ModuleSwitch.enableAction(kind, modes: modes) {
                Button(action: action.run) {
                    Label(kind == .projects ? String(localized: "Нужен источник проектов") : String(localized: "Включить в профиле"), systemImage: "plus.circle")
                        .font(.system(size: 12))
                }
                .buttonStyle(.link)
                .help(action.title)
            } else {
                Text(kind.tagline)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 118, maxHeight: 118, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(hovering ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.2), lineWidth: hovering ? 1 : 0.5))
        .opacity(on ? 1 : 0.6)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .help(kind.summary)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(kind.title)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("Открыть настройки модуля"), open)
    }
}
