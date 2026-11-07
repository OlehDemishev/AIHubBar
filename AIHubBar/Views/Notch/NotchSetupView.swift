import SwiftUI

/// The island's first setup (SPEC-notch §6.1): what the module doesn't decide for the person, asked once when it is
/// installed — requests, the summary's place, the pill, the hot keys. Closing it unanswered keeps the defaults.
struct NotchSetupView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var islandOnly = false
    @State private var summary: NotchSummary = .menuBar
    @State private var pill = !NotchGeometry.macHasNotch
    @State private var hotKeys = false

    var body: some View {
        Form {
            Section {
                Text("Остров у чёлки показывает лимиты, сессии и запросы Claude рядом с чёлкой. Четыре вопроса — всё потом меняется в Настройках → «Остров у чёлки».")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Когда Claude просит разрешение или ждёт ответа") {
                Picker("Когда Claude просит разрешение или ждёт ответа", selection: $islandOnly) {
                    Text("Остров и уведомление").tag(false)
                    Text("Только остров").tag(true)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Footnote(text: String(localized: "Если острова не видно (экран спит, Mac заблокирован), уведомление всё равно придёт."))
            }
            Section("Сводка — лимиты и сессии") {
                Picker("Сводка — лимиты и сессии", selection: $summary) {
                    ForEach(NotchSummary.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
            Section("На экранах без чёлки") {
                Picker("На экранах без чёлки", selection: $pill) {
                    Text("Показывать пилюлю сверху по центру").tag(true)
                    Text("Не показывать").tag(false)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
            Section("Горячие клавиши «Разрешить» / «Отклонить»") {
                Picker("Горячие клавиши «Разрешить» / «Отклонить»", selection: $hotKeys) {
                    Text("Включить ⌃⌥Y / ⌃⌥N").tag(true)
                    Text("Не нужны").tag(false)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Footnote(text: String(localized: "Клавишей легко разрешить, не прочитав команду."))
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Готово", action: save)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onDisappear {
            // Closed without «Готово»: the defaults stay, and the window doesn't come back.
            if !settings.notch.setupDone { settings.notch.setupDone = true }
        }
    }

    private func save() {
        settings.notch.replaceNotifications = islandOnly
        settings.notch.summary = summary
        settings.notch.pill = pill
        settings.notch.hotKeys = hotKeys
        settings.notch.setupDone = true
        AppLog.info("Notch island set up: island only \(islandOnly), summary \(summary.rawValue), pill \(pill), hot keys \(hotKeys)")
        dismiss()
    }
}
