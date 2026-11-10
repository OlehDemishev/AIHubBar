import SwiftUI

/// The panel in miniature: one card per shown block, in order, each with what it shows right now. Not the panel view
/// itself — that one takes over its window (glass, background) and refreshes on open.
struct PanelSketch: View {
    let modules: [ModuleKind]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Панель сейчас").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            VStack(spacing: 6) {
                ForEach(modules, id: \.self) { kind in
                    HStack(spacing: 8) {
                        Image(systemName: kind.symbol)
                            .foregroundStyle(kind.group.tint)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(kind.title).font(.system(size: 12, weight: .semibold))
                            live(kind)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
                }
                if modules.isEmpty {
                    Text("Панель пуста").font(.system(size: 12)).foregroundStyle(.secondary).padding(20)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5))
            .animation(.snappy(duration: 0.2), value: modules)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Схема панели: ") + modules.map(\.title).joined(separator: ", "))
    }

    /// What the block shows now, from the module's own file; its tagline when it has nothing live to show.
    @ViewBuilder private func live(_ kind: ModuleKind) -> some View {
        if let sketch = ModuleUI.of(kind).sketch { sketch() } else { SketchLine(kind.tagline) }
    }
}

/// What a profile shows inside a module (SPEC-profiles §3): a menu of checkmarks, «все» when nothing is chosen.
/// Used by «Профили» and «Панель».
struct ProfileModuleOptions: View {
    let module: ProfileModule
    let change: (ProfileModule) -> Void

    @Environment(AppSettings.self) private var settings

    var body: some View {
        switch module.kind {
        case .resources:
            choiceMenu(String(localized: "Показатели"), chosen: module.metrics,
                       items: ResourceMetric.allCases.map { ($0.rawValue, $0.title) }) { new in edit { $0.metrics = new } }
        case .quickCommands:
            choiceMenu(String(localized: "Команды"), chosen: module.commands,
                       items: settings.quickCommands.map { ($0.id, $0.title) }) { new in edit { $0.commands = new } }
        case .toggles:
            // nil here means «as in the module's settings», so a choice made in the profile is always kept as a list.
            let all = QuickToggle.allCases.map(\.rawValue)
            choiceMenu(String(localized: "Переключатели"), chosen: module.toggles ?? settings.quickToggles.map(\.rawValue),
                       items: QuickToggle.allCases.map { ($0.rawValue, $0.title) }) { new in edit { $0.toggles = new ?? all } }
        case .keepAwake:
            Toggle("Таймеры", isOn: Binding(
                get: { module.showTimers != false },
                set: { on in edit { $0.showTimers = on ? nil : false } }
            ))
            .toggleStyle(.checkbox)
            .help("Кнопки «15 мин», «1 ч», «2 ч» в панели")
        default:
            EmptyView()
        }
    }

    private func edit(_ apply: (inout ProfileModule) -> Void) {
        var new = module
        apply(&new)
        change(new)
    }

    private func choiceMenu(_ title: String, chosen: [String]?, items: [(id: String, title: String)],
                            set: @escaping ([String]?) -> Void) -> some View {
        let all = items.map(\.id)
        let count = chosen.map { list in all.filter(list.contains).count } ?? all.count
        return Menu {
            ForEach(items, id: \.id) { item in
                Button {
                    set(ProfileModule.toggled(item.id, in: chosen, all: all))
                } label: {
                    if ProfileModule.includes(item.id, in: chosen) {
                        Label(item.title, systemImage: "checkmark")
                    } else {
                        Text(item.title)
                    }
                }
            }
        } label: {
            Text(count == all.count ? String(localized: "\(title): все") : String(localized: "\(title): \(count) из \(all.count)"))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Что этот профиль показывает в блоке")
    }
}
