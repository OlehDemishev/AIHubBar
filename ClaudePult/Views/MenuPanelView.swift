import OSLog
import SwiftUI

/// Content of the menu bar panel. Sessions, projects and commands are added in later stages.
struct MenuPanelView: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Drives the entrance animation; reset when the panel closes so it replays on every open.
    @State private var isShown = false

    private let log = Logger(subsystem: "com.demishev.claudepult", category: "panel")

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .revealed(isShown, step: 0, reduceMotion: reduceMotion)

            Divider()

            emptyState
                .revealed(isShown, step: 1, reduceMotion: reduceMotion)

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
            .revealed(isShown, step: 2, reduceMotion: reduceMotion)
        }
        .frame(width: 420)
        .onAppear {
            log.debug("Panel shown")
            isShown = true
        }
        .onDisappear {
            isShown = false
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle")
                .font(.title3)
                .foregroundStyle(.orange)
                .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? false : isShown)
            Text("ClaudePult")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Пока пусто")
                .font(.headline)
            Text("Здесь появятся сессии Claude Code и проекты из ~/Projects.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 28)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
    }
}

private extension View {
    /// Staggered entrance: fades in and settles down from just under the menu bar.
    /// With Reduce Motion on, only the fade remains.
    func revealed(_ isShown: Bool, step: Int, reduceMotion: Bool) -> some View {
        self
            .opacity(isShown ? 1 : 0)
            .offset(y: isShown || reduceMotion ? 0 : -6)
            .animation(
                isShown
                    ? .spring(duration: 0.35, bounce: 0.15).delay(Double(step) * 0.05)
                    : nil,
                value: isShown
            )
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
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}
