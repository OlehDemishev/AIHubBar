import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Records a global shortcut: click, press the keys; Esc cancels, ✕ clears.
struct HotKeyRecorder: View {
    @Binding var combo: KeyCombo?
    @State private var recording = false
    @State private var needsModifier = false
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            buttons
            if needsModifier {
                Text("Нужна ⌘, ⌃ или ⌥ — или одна клавиша F1–F20.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .onDisappear { stop() }
    }

    private var buttons: some View {
        HStack(spacing: 6) {
            Button {
                if recording { stop() } else { start() }
            } label: {
                Text(recording ? String(localized: "Нажмите сочетание…") : combo?.title ?? String(localized: "Записать"))
                    .monospacedDigit()
                    .frame(minWidth: 110)
            }
            .help(recording ? String(localized: "Нажмите клавиши с ⌘, ⌃ или ⌥; Esc — отменить") : String(localized: "Сочетание клавиш запускает команду из любого приложения"))
            .accessibilityLabel(combo.map { String(localized: "Сочетание клавиш: \($0.spoken)") } ?? String(localized: "Сочетание клавиш не задано"))
            .accessibilityHint(String(localized: "Нажмите и введите сочетание; Escape — отменить"))
            if combo != nil, !recording {
                Button { combo = nil } label: {
                    Label("Убрать сочетание", systemImage: "xmark.circle.fill").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Убрать сочетание")
            }
        }
    }

    /// One recorder at a time: starting another stops this one.
    @MainActor private static var stopActive: (() -> Void)?

    private func start() {
        Self.stopActive?()
        Self.stopActive = { stop() }
        recording = true
        needsModifier = false
        // Keys the app has registered never reach the window: Carbon hands them over here instead.
        GlobalHotKey.recorder = { finish($0) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let new = KeyCombo(event: event)
            MainActor.assumeIsolated {
                if new.keyCode == UInt32(kVK_Escape), new.modifiers == 0 {
                    stop()
                } else if new.isValid {
                    finish(new)
                } else {
                    needsModifier = true
                }
            }
            return nil
        }
    }

    private func finish(_ new: KeyCombo) {
        combo = new
        needsModifier = false
        stop()
    }

    private func stop() {
        guard recording else { return }
        Self.stopActive = nil
        recording = false
        GlobalHotKey.recorder = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
