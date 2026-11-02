import SwiftUI

/// Settings → Модули → Лимиты → «Другие AI»: a summary; each service's switch, keys and consents are in its tab of
/// «Сервисы AI» (SPEC-ai-services §4).
struct HubSection: View {
    @Environment(HubLimitsStore.self) private var hub

    var body: some View {
        Section {
            ForEach(HubLimit.Source.allCases) { source in
                LabeledContent(source.title) {
                    Text(hub.statusText(source))
                        .foregroundStyle(hub.available.contains(source) ? Color.secondary : Color.orange)
                }
            }
            HStack {
                Button("Проверить сейчас") { Task { await hub.refresh() } }
                    .disabled(hub.isRefreshing)
                if hub.isRefreshing { ProgressView().controlSize(.small) }
                Spacer()
                Button("Открыть «Сервисы AI»") {
                    SettingsRoute.open(service: hub.available.first.map(ServiceTab.init(hub:)) ?? .codex)
                }
            }
        } header: {
            Text("Другие AI")
        } footer: {
            Footnote(text: String(localized: "Включить сервис, вставить ключ или дать согласие — в «Сервисы AI», на вкладке сервиса."))
        }
    }
}

/// One limit source with its switch, status, key and consents (a service's tab in «Сервисы AI»).
struct HubSourceRow: View {
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
                Text(hub.statusText(source))
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
                Toggle("Точная квота через вход Gemini CLI", systemImage: "checkmark.seal", isOn: $settings.hubGeminiQuota)
                    .help("Иначе запросы считаются по журналам ~/.gemini за сегодня и делятся на дневной лимит тарифа")
                Picker("Запросов в день по тарифу", systemImage: "number", selection: $settings.hubGeminiDailyLimit) {
                    Text("250 — бесплатный ключ API").tag(250)
                    Text("1 000 — аккаунт Google").tag(1000)
                    Text("1 500 — AI Pro").tag(1500)
                    Text("2 000 — AI Ultra").tag(2000)
                }
            }
            if source == .cursor {
                Toggle("Разрешить читать вход Cursor", systemImage: "key", isOn: $settings.hubCursor)
                    .help("Токен берётся из базы настроек Cursor только для запроса расхода и нигде не сохраняется")
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
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

extension HubLimitsStore {
    /// The source's windows, its error, or whether it was found.
    func statusText(_ source: HubLimit.Source) -> String {
        if let limit = limits.first(where: { $0.source == source }) {
            if let error = limit.error { return error }
            return limit.windows.map { window in
                window.percent.map { "\(window.title) \(UsageText.percent($0))" } ?? [window.title, window.detail].compactMap { $0 }.joined(separator: " ")
            }.joined(separator: " · ")
        }
        if available.contains(source) { return String(localized: "найден") }
        return source.keychainAccount != nil ? String(localized: "нет ключа") : String(localized: "не найден")
    }
}
