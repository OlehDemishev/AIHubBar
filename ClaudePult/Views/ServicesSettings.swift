import AppKit
import SwiftUI

/// Settings → «Сервисы AI» (SPEC-modes §11.3): installed agents, API keys with «Проверить», the model per service.
struct ServicesSettings: View {
    @Environment(AIServiceStore.self) private var services

    var body: some View {
        Form {
            Section {
                ForEach(AgentKind.allCases, id: \.self) { kind in
                    AgentRow(kind: kind, info: services.agents[kind])
                }
            } header: {
                HStack {
                    Text("Агенты — работают с файлами в папке проекта")
                    Spacer()
                    Button("Найти заново") { Task { await services.scan() } }
                        .controlSize(.small)
                        .disabled(services.isScanning)
                }
            } footer: {
                Footnote(text: "Вход у каждого агента свой (его команда в подсказке), ClaudePult их токены не трогает. В фоне пока работает только Claude Code: остальные открываются в Терминале, пока их запрет действий не проверен вживую.")
            }

            Section {
                ForEach(APIProvider.allCases, id: \.self) { provider in
                    ProviderRow(provider: provider)
                }
            } header: {
                Text("Модели по API — получают только текст")
            } footer: {
                Footnote(text: "Ключ хранится только в связке ключей macOS (запись «ClaudePult API key»), не пишется в журнал и не попадает в экспорт. «Проверить» запрашивает список моделей — токены на это не тратятся. Модели по API заработают с командами-шаблонами (этап 4).")
            }
        }
        .formStyle(.grouped)
        .frame(height: 600)
        .task { if services.agents.isEmpty { await services.scan() } }
    }
}

private struct AgentRow: View {
    let kind: AgentKind
    let info: AIServiceStore.AgentInfo?

    var body: some View {
        LabeledContent {
            if let info {
                Text(info.version ?? "установлен")
                    .foregroundStyle(.secondary)
                    .help(info.path)
            } else {
                HStack(spacing: 6) {
                    Text("не установлен").foregroundStyle(.tertiary)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(kind.install, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help("Скопировать: \(kind.install)")
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                Text(info == nil ? kind.install : "Вход: \(kind.login)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let note = kind.note {
                    Text(note).font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct ProviderRow: View {
    let provider: APIProvider

    @Environment(AIServiceStore.self) private var services
    @Environment(AppSettings.self) private var settings
    @State private var keyText = ""
    @State private var error: String?
    @State private var editing = false

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(provider == .compatible && !settings.aiServices.compatibleName.isEmpty
                     ? settings.aiServices.compatibleName : provider.title)
                Spacer()
                status
            }
            if provider == .compatible {
                TextField("Название", text: $settings.aiServices.compatibleName, prompt: Text("Ollama, LM Studio, OpenRouter…"))
                TextField("Адрес", text: $settings.aiServices.compatibleBaseURL, prompt: Text(APIProvider.compatible.defaultBaseURL))
            }
            if editing || (!services.hasKey.contains(provider) && provider.keyRequired) {
                HStack {
                    SecureField("Ключ API", text: $keyText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(save)
                    Button("Сохранить", action: save)
                        .disabled(keyText.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let page = provider.keyPage, let url = URL(string: page) {
                        Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                            .help("Где взять ключ: \(page)")
                    }
                }
            }
            HStack(spacing: 10) {
                if services.hasKey.contains(provider) || !provider.keyRequired {
                    Button("Проверить") { Task { await services.check(provider) } }
                        .disabled(services.checking.contains(provider))
                }
                if services.hasKey.contains(provider) {
                    Button(editing ? "Отмена" : "Заменить ключ") { editing.toggle(); keyText = "" }
                    Button("Удалить ключ", role: .destructive) { Task { await services.deleteKey(provider) } }
                }
                if !provider.keyRequired, !services.hasKey.contains(provider) {
                    Button("Ключ (если нужен)") { editing.toggle() }
                }
                Spacer()
                if case let .ok(models) = services.checks[provider], !models.isEmpty {
                    Picker("Модель", selection: Binding(
                        get: { settings.aiServices.model(provider) ?? models[0] },
                        set: { settings.aiServices.models[provider.rawValue] = $0 }
                    )) {
                        ForEach(models, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(maxWidth: 260)
                } else if let model = settings.aiServices.model(provider) {
                    Text(model).font(.caption).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var status: some View {
        if services.checking.contains(provider) {
            ProgressView().controlSize(.small)
        } else if let check = services.checks[provider] {
            Label(check.text, systemImage: check.isOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(check.isOK ? .green : .orange)
                .font(.caption)
        } else if services.hasKey.contains(provider) {
            Text("ключ сохранён").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func save() {
        let key = keyText
        keyText = ""
        Task {
            do {
                try await services.saveKey(key, for: provider)
                error = nil
                editing = false
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

extension APICheck {
    var isOK: Bool { if case .ok = self { true } else { false } }
}
