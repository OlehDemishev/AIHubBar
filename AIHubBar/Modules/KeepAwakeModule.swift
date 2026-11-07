import AppKit
import SwiftUI

// «Не спать» (docs/specs/SPEC-refactor.md §3): what the module is, its Settings sections and its «Панель сейчас» line.

extension ModuleDefinition {
    static let keepAwake = ModuleDefinition(
        kind: .keepAwake,
        group: .mac,
        symbol: "cup.and.saucer",
        title: String(localized: "Не спать"),
        summary: String(localized: "Mac не засыпает, пока работает Claude, на время, при подключённом питании или мониторе, пока открыты выбранные приложения."),
        tagline: String(localized: "Mac не засыпает по правилам"),
        places: [.panel, .menuBar],
        menuBarKinds: [.keepAwake],
        primaryMenuBarKinds: [.keepAwake],
        keywords: [String(localized: "Правила «Не спать»"), String(localized: "С закрытой крышкой")]
    )
}

extension ModuleUI {
    static let keepAwake = ModuleUI(
        settings: { AnyView(KeepAwakeSection()) },
        sketch: { AnyView(KeepAwakeSketch()) }
    )
}

/// «Панель сейчас»: whether it holds the Mac awake.
private struct KeepAwakeSketch: View {
    @Environment(KeepAwakeController.self) private var keepAwake

    var body: some View {
        SketchLine(keepAwake.reason == nil ? String(localized: "Mac может уснуть") : String(localized: "Не даёт уснуть"))
    }
}

struct KeepAwakeSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(KeepAwakeController.self) private var keepAwake
    @State private var lidBusy = false
    @State private var lidError: String?
    @State private var sleepOffNow = false

    var body: some View {
        @Bindable var settings = settings
        Section {
            Toggle("Пока работает Claude (сессия или фоновая задача)", systemImage: "sparkles", isOn: $settings.keepAwakeRules.whileClaudeWorks)
            Toggle("Пока подключено питание", systemImage: "powerplug", isOn: $settings.keepAwakeRules.whileOnPower)
            Toggle("Пока подключён внешний монитор", systemImage: "display", isOn: $settings.keepAwakeRules.whileExternalDisplay)
            IconRow("Пока открыты приложения", systemImage: "app.badge") {
                HStack {
                    Text(settings.keepAwakeRules.whileApps.isEmpty ? String(localized: "нет") : settings.keepAwakeRules.whileApps.map(\.name).joined(separator: ", "))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button("Выбрать…", action: chooseApps)
                    if !settings.keepAwakeRules.whileApps.isEmpty {
                        Button("Очистить") { settings.keepAwakeRules.whileApps = [] }
                    }
                }
            }
            Toggle("Не гасить и экран", systemImage: "sun.max", isOn: $settings.keepAwakeRules.keepDisplayOn)
        } header: {
            Text("Правила «Не спать»")
        } footer: {
            Footnote(text: String(localized: "Любое сработавшее правило не даёт Mac уснуть; вручную — переключателем и таймерами в панели. Системные настройки не меняются: как только правил нет, Mac засыпает как обычно. На Mac без своего экрана любой монитор считается внешним."))
        }
        Section {
            if !LidSleep.hasLid {
                Text("У этого Mac нет крышки: правило нужно только ноутбукам.")
                    .foregroundStyle(.secondary)
            }
            Toggle("И с закрытой крышкой", systemImage: "laptopcomputer", isOn: $settings.keepAwakeRules.lidClosed)
                .disabled(!keepAwake.lidInstalled || !LidSleep.hasLid)
            IconRow("Разрешение администратора", systemImage: "lock.shield") {
                HStack {
                    Text(keepAwake.lidInstalled ? String(localized: "есть") : String(localized: "нет"))
                        .foregroundStyle(.secondary)
                    if keepAwake.lidInstalled {
                        Button("Убрать…") { change { await keepAwake.removeLidPermission() } }
                    } else {
                        Button("Разрешить…") { change { await keepAwake.installLidPermission() } }
                            .disabled(!LidSleep.hasLid)
                    }
                }
                .disabled(lidBusy)
            }
            if let lidError {
                Text(lidError).foregroundStyle(.red).scaledFont(.caption)
            }
            if sleepOffNow && !keepAwake.lidHeld {
                Text("Сейчас сон уже отключён другим приложением или командой pmset — AI Hub Bar его не трогает.")
                    .foregroundStyle(.secondary)
                    .scaledFont(.caption)
            }
        } header: {
            Text("С закрытой крышкой")
        } footer: {
            Footnote(text: String(localized: "Без монитора и питания закрытый Mac засыпает всегда, это может отменить только pmset от имени администратора. «Разрешить…» один раз спрашивает пароль и добавляет правило /etc/sudoers.d/claudepult: только команды pmset -a disablesleep 0 и 1. Пока держит правило «Не спать», сон выключен; потом и при выходе из AI Hub Bar — включается обратно. На батарее ниже 20 % — тоже включается. Закрытый Mac греется: не кладите его в сумку."))
        }
        .task { sleepOffNow = await LidSleep.systemSleepDisabled() }
    }

    private func change(_ action: @escaping () async -> LidSleep.AdminResult) {
        lidBusy = true
        lidError = nil
        Task {
            switch await action() {
            case .done, .cancelled: break
            case let .failed(message): lidError = message.isEmpty ? String(localized: "Не получилось") : message
            }
            if !keepAwake.lidInstalled { settings.keepAwakeRules.lidClosed = false }
            sleepOffNow = await LidSleep.systemSleepDisabled()
            lidBusy = false
        }
    }

    private func chooseApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        let picked = panel.urls.compactMap { url -> KeepAwakeRules.App? in
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
            return KeepAwakeRules.App(bundleID: id, name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
        }
        settings.keepAwakeRules.whileApps = Array(Set(settings.keepAwakeRules.whileApps + picked)).sorted { $0.name < $1.name }
    }
}
