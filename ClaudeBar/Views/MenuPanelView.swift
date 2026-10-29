import SwiftUI

/// Content of the menu bar panel. Sessions, projects and commands are added in later stages.
struct MenuPanelView: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("ClaudeBar")
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            Divider()

            Text("Здесь появятся сессии Claude Code и проекты из ~/Projects.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            VStack(spacing: 2) {
                PanelButton(title: "Настройки…", shortcut: ",") {
                    NSApp.activate()
                    openSettings()
                }
                PanelButton(title: "Выход", shortcut: "q") {
                    NSApp.terminate(nil)
                }
            }
            .padding(6)
        }
        .frame(width: 420)
    }
}

/// Full-width menu-like button with a ⌘-shortcut hint.
private struct PanelButton: View {
    let title: String
    let shortcut: Character
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Text("⌘\(String(shortcut).uppercased())")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovered ? Color.primary.opacity(0.1) : .clear)
            )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(shortcut), modifiers: .command)
        .onHover { isHovered = $0 }
    }
}
