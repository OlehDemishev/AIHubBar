import AppKit
import SwiftUI

// «Ресурсы Mac» (docs/specs/SPEC-refactor.md §3): what the module is, its Settings sections and its «Панель сейчас» line.

extension ModuleDefinition {
    static let resources = ModuleDefinition(
        kind: .resources,
        group: .mac,
        symbol: "cpu",
        title: String(localized: "Ресурсы Mac"),
        summary: String(localized: "Процессор, память, диск, сеть, батарея и самые прожорливые приложения; уведомления о нагрузке, памяти, месте и заряде."),
        tagline: String(localized: "Процессор, память, диск, батарея"),
        places: [.panel, .menuBar, .notifications],
        menuBarKinds: [.cpu, .memory],
        primaryMenuBarKinds: [.cpu, .memory],
        notifications: [.resources],
        notificationSwitch: .resourceAlerts,
        keywords: [String(localized: "Уведомления о ресурсах")]
    )
}

extension ModuleUI {
    static let resources = ModuleUI(
        settings: { AnyView(ResourceSection()) },
        sketch: { AnyView(ResourcesSketch()) }
    )
}

/// «Панель сейчас»: processor and memory now.
private struct ResourcesSketch: View {
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        if let snapshot = monitor.snapshot {
            SketchLine(String(localized: "Процессор \(Int(snapshot.cpu.rounded())) % · память \(Int(snapshot.memoryPercent.rounded())) %"))
        } else {
            SketchLine(ModuleKind.resources.tagline)
        }
    }
}

struct ResourceSection: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Section {
            Toggle("Уведомлять о нагрузке, памяти, месте и заряде", systemImage: "bell.badge", isOn: $settings.resourceAlerts)
            Picker("Мало места — свободно меньше", systemImage: "internaldrive", selection: $settings.resourceDiskBelowGB) {
                ForEach([5, 10, 20, 50, 100], id: \.self) { Text("\($0) ГБ").tag($0) }
            }
            .disabled(!settings.resourceAlerts)
        } header: {
            Text("Уведомления о ресурсах")
        } footer: {
            Footnote(text: String(localized: "Процессор выше 90 % дольше 5 минут, критическая нехватка памяти, мало места, заряд ниже 15 % без зарядки — по одному уведомлению, пока не наладится. В строку меню процессор и память добавляются во вкладке «Строка меню»."))
        }
    }
}
