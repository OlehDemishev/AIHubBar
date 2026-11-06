import SwiftUI

/// Settings → «Клавиши»: every shortcut of the app on one page. The modules keep theirs too, next to what they do.
struct ShortcutsSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ProfileStore.self) private var modes
    @Environment(CommandHotKeys.self) private var hotKeys

    var body: some View {
        @Bindable var settings = settings
        SettingsPage {
            Section {
                Picker("Открывать поиск с клавиатуры", systemImage: "magnifyingglass", selection: $settings.panelHotKey) {
                    ForEach(PanelHotKey.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .onChange(of: settings.panelHotKey) { GlobalHotKey.register(settings.panelHotKey) }
                if modes.isOn(.quickPrompt) {
                    Picker("Быстрый запрос", systemImage: "text.bubble", selection: $settings.quickPrompt.hotKey) {
                        ForEach(QuickPromptHotKey.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                if modes.isOn(.notch) {
                    Toggle("Горячие клавиши ⌃⌥Y / ⌃⌥N для запросов", systemImage: "keyboard", isOn: $settings.notch.hotKeys)
                        .onChange(of: settings.notch.hotKeys) { GlobalHotKey.registerIsland(settings.notch.hotKeys) }
                }
            } footer: {
                Footnote(text: String(localized: "Работают из любой программы. В панели: ⌘R — обновить, ⌘, — настройки, ↑ ↓ и ↵ — результаты поиска."))
            }

            if modes.isOn(.quickCommands), !settings.quickCommands.isEmpty {
                Section {
                    ForEach($settings.quickCommands) { $command in
                        LabeledContent {
                            HotKeyRecorder(combo: $command.hotKey)
                        } label: {
                            Label(command.title, systemImage: command.symbol)
                        }
                        if let problem = hotKeys.problem(for: command) {
                            Label(problem.text, systemImage: problem.blocks ? "exclamationmark.triangle.fill" : "info.circle")
                                .font(.caption)
                                .foregroundStyle(problem.blocks ? .orange : .secondary)
                        }
                    }
                } header: {
                    Text("Быстрые команды")
                }
            }
        }
    }
}
