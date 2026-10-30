import SwiftUI

/// «Не спать» in the panel (SPEC-profiles §4.2): what holds the Mac awake now, a switch and quick timers.
struct KeepAwakeView: View {
    @Environment(KeepAwakeController.self) private var keepAwake
    @AppStorage("collapsedBlocks") private var collapsedRaw = ""

    private var collapsed: Bool { PanelBlock.collapsed(in: collapsedRaw).contains(.keepAwake) }
    private var manual: Bool { keepAwake.manualUntil != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                BlockTitle(block: .keepAwake, title: "Не спать")
                Image(systemName: keepAwake.reason == nil ? "cup.and.saucer" : "cup.and.saucer.fill")
                    .foregroundStyle(keepAwake.reason == nil ? Color.secondary : Color.orange)
                    .scaledFont(.caption)
                    .help(KeepAwakeText.status(keepAwake.reason))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { manual },
                    set: { $0 ? keepAwake.holdManually(for: nil) : keepAwake.stopManual() }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Не давать Mac засыпать, пока не выключите")
            }
            if !collapsed {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(KeepAwakeText.status(keepAwake.reason, now: context.date))
                        .scaledFont(.caption)
                        .foregroundStyle(keepAwake.reason == nil ? .secondary : .primary)
                }
                if keepAwake.lidHeld {
                    Label("и с закрытой крышкой", systemImage: "laptopcomputer")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    ForEach([(15, String(localized: "15 мин")), (60, String(localized: "1 ч")), (120, String(localized: "2 ч"))], id: \.0) { minutes, title in
                        Button(title) { keepAwake.holdManually(for: TimeInterval(minutes * 60)) }
                            .help(String(localized: "Не давать Mac засыпать: \(title)"))
                    }
                    if manual {
                        Button("Отпустить") { keepAwake.stopManual() }
                            .help("Снять ручной запрет сна: дальше решают правила")
                    }
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
