import SwiftUI

/// Settings → Модули → Лимиты → «Другие AI» (SPEC-hub): what each service needs, its keys and consents.
struct HubSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(HubLimitsStore.self) private var hub

    var body: some View {
        @Bindable var settings = settings
        Section {
            ForEach(HubLimit.Source.allCases) { source in
                HubSourceRow(source: source)
            }
            HStack {
                Button("Проверить сейчас") { Task { await hub.refresh() } }
                    .disabled(hub.isRefreshing)
                if hub.isRefreshing { ProgressView().controlSize(.small) }
            }
        } header: {
            Text("Другие AI")
        } footer: {
            Footnote(text: String(localized: "Сервис появляется под кольцами Claude сам, когда найден на Маке или сохранён его ключ. Ключи хранятся только в связке ключей. Codex и Copilot спрашиваются через свои программы (codex, gh); вход Gemini CLI и Cursor читается только с вашего согласия. Обновляется раз в 5 минут, пороги уведомлений — те же, что у Claude. Форматы ответов не документированы производителями и могут поменяться."))
        }
    }
}

private struct HubSourceRow: View {
    let source: HubLimit.Source
    @Environment(AppSettings.self) private var settings
    @Environment(HubLimitsStore.self) private var hub
    @State private var keyText = ""
    @State private var error: String?

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle(source.title, isOn: Binding(
                    get: { !settings.hubDisabled.contains(source.rawValue) },
                    set: { settings.setHubEnabled(source, $0) }
                ))
                Spacer()
                Text(status)
                    .font(.caption)
                    .foregroundStyle(hub.available.contains(source) ? Color.secondary : Color.orange)
            }
            Text("Нужно: \(source.requirement)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if source.keychainAccount != nil {
                HStack {
                    if hub.savedKeys.contains(source) {
                        Text("Ключ сохранён").font(.caption)
                        Spacer()
                        Button("Удалить ключ", role: .destructive) { Task { await hub.deleteKey(for: source) } }
                    } else {
                        SecureField("Ключ", text: $keyText)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(save)
                        Button("Сохранить", action: save)
                            .disabled(keyText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if let page = source.keyPage {
                        Link(destination: page) { Image(systemName: "arrow.up.right.square") }
                            .help("Где взять ключ: \(page.absoluteString)")
                    }
                }
            }
            if source == .gemini {
                Toggle("Точная квота через вход Gemini CLI", isOn: $settings.hubGeminiQuota)
                    .help("Иначе запросы считаются по журналам ~/.gemini за сегодня и делятся на дневной лимит тарифа")
                Picker("Запросов в день по тарифу", selection: $settings.hubGeminiDailyLimit) {
                    Text("250 — бесплатный ключ API").tag(250)
                    Text("1 000 — аккаунт Google").tag(1000)
                    Text("1 500 — AI Pro").tag(1500)
                    Text("2 000 — AI Ultra").tag(2000)
                }
            }
            if source == .cursor {
                Toggle("Разрешить читать вход Cursor", isOn: $settings.hubCursor)
                    .help("Токен берётся из базы настроек Cursor только для запроса расхода и нигде не сохраняется")
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }

    private var status: String {
        if let limit = hub.limits.first(where: { $0.source == source }) {
            if let error = limit.error { return error }
            return limit.windows.map { window in
                window.percent.map { "\(window.title) \(UsageText.percent($0))" } ?? [window.title, window.detail].compactMap { $0 }.joined(separator: " ")
            }.joined(separator: " · ")
        }
        if hub.available.contains(source) { return String(localized: "найден") }
        return source.keychainAccount != nil ? String(localized: "нет ключа") : String(localized: "не найден")
    }

    private func save() {
        let key = keyText
        Task {
            do {
                try await hub.saveKey(key, for: source)
                keyText = ""
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
