import AppKit
import SwiftUI

// «История буфера» (docs/specs/SPEC-refactor.md §3): what the module is, its Settings sections and its «Панель сейчас» line.

extension ModuleDefinition {
    static let clipboard = ModuleDefinition(
        kind: .clipboard,
        group: .work,
        symbol: "doc.on.clipboard",
        title: String(localized: "История буфера"),
        summary: String(localized: "Последние копирования: поиск, закрепление, снова в буфер одним кликом. Пароли из менеджеров паролей не запоминаются."),
        tagline: String(localized: "Последние копирования, поиск"),
        keywords: [String(localized: "Хранить последних")]
    )
}

extension ModuleUI {
    static let clipboard = ModuleUI(
        settings: { AnyView(ClipboardSection()) },
        sketch: { AnyView(ClipboardSketch()) }
    )
}

/// «Панель сейчас»: how many copies it keeps.
private struct ClipboardSketch: View {
    @Environment(ClipboardHistory.self) private var clipboard

    var body: some View {
        SketchLine(String(localized: "Записей: \(clipboard.items.count)"))
    }
}

struct ClipboardSection: View {
    @State private var showsApps = false
    @Environment(AppSettings.self) private var settings
    @Environment(ClipboardHistory.self) private var history

    var body: some View {
        @Bindable var settings = settings
        Section {
            Picker("Хранить последних", systemImage: "tray.full", selection: $settings.clipboardLimit) {
                ForEach([20, 50, 100, 200], id: \.self) { Text(verbatim: "\($0)").tag($0) }
            }
            Toggle("Помнить после перезапуска", systemImage: "arrow.clockwise", isOn: $settings.clipboardRemember)
                .onChange(of: settings.clipboardRemember) { history.rememberChanged() }
            IconRow("Не запоминать из приложений", systemImage: "hand.raised.slash", content: {
                HStack {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { showsApps.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text(verbatim: "\(settings.clipboardExcludedApps.count)")
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .rotationEffect(.degrees(showsApps ? 90 : 0))
                        }
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Показать приложения")
                    Button("Добавить…", action: addApps)
                    Button("По умолчанию") { settings.clipboardExcludedApps = ClipboardPolicy.defaultExcludedApps }
                }
            })
            if showsApps {
                ForEach(settings.clipboardExcludedApps, id: \.self) { app in
                    HStack {
                        Text(verbatim: Self.name(app))
                        Spacer()
                        Button { settings.clipboardExcludedApps.removeAll { $0 == app } } label: {
                            Label("Убрать", systemImage: "minus.circle").labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .help("Убрать")
                    }
                    .padding(.leading, 30)
                }
            }
            ConfirmedButton(title: "Очистить историю", message: String(localized: "Удалить всё, кроме закреплённого"), confirm: "Очистить") {
                history.clear()
            } label: { Text("Очистить историю") }
        } header: {
            Text("История буфера")
        } footer: {
            Footnote(text: String(localized: "Не запоминается то, что менеджеры паролей помечают как скрытое, и всё, что скопировано, пока впереди менеджер паролей или «Связка ключей». Без «Помнить после перезапуска» история живёт только в памяти; с ним — в файле, доступном только вам."))
        }
    }

    /// The default list's apps, by name also on a Mac that doesn't have them.
    private static let knownApps = [
        "com.1password.1password": "1Password", "com.agilebits.onepassword7": "1Password 7", "com.bitwarden.desktop": "Bitwarden",
        "org.keepassxc.keepassxc": "KeePassXC", "com.lastpass.LastPass": "LastPass", "com.dashlane.dashlanephonefinal": "Dashlane",
    ]

    /// An app's name from its bundle id; the id itself when the app isn't on this Mac and isn't a known one.
    private static func name(_ id: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { FileManager.default.displayName(atPath: $0.path) }
            ?? knownApps[id] ?? id
    }

    private func addApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        let ids = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        settings.clipboardExcludedApps = Array(Set(settings.clipboardExcludedApps + ids)).sorted()
    }
}
