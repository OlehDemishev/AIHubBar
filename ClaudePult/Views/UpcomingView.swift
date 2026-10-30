import AppKit
import SwiftUI

/// «Ближайшее» in the panel (SPEC-modes §6): the next 7 days of all calendars, overdue in red; a click opens it.
struct UpcomingView: View {
    @Environment(CalendarStore.self) private var calendar
    @Environment(\.openWindow) private var openWindow
    @AppStorage("collapsedBlocks") private var collapsedRaw = ""

    var body: some View {
        let entries = calendar.upcoming()
        let collapsed = PanelBlock.collapsed(in: collapsedRaw).contains(.calendar)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                BlockTitle(block: .calendar, title: "Ближайшее")
                if collapsed, !entries.isEmpty {
                    Text(verbatim: "\(entries.count)")
                        .scaledFont(.caption)
                        .foregroundStyle(entries.contains { $0.isOverdue() } ? .red : .secondary)
                }
                Spacer()
                Button("Календарь") {
                    NSApp.activate()
                    openWindow(id: "calendar")
                }
                .buttonStyle(.link)
                .scaledFont(.caption)
            }
            if !collapsed {
                if entries.isEmpty {
                    Text("На неделю дат нет.")
                        .scaledFont(.caption)
                        .foregroundStyle(.tertiary)
                }
                ForEach(entries.prefix(8)) { entry in
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: entry.openPath))
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: entry.kind.symbol)
                                .frame(width: 14)
                                .foregroundStyle(entry.isOverdue() ? .red : .secondary)
                            Text(entry.title).lineLimit(1)
                            if let detail = entry.detail, !detail.isEmpty {
                                Text(detail).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            Text(CalendarText.relative(entry.date, hasTime: entry.hasTime))
                                .foregroundStyle(entry.isOverdue() ? .red : .secondary)
                                .lineLimit(1)
                        }
                        .scaledFont(.caption)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(entry.kind.title) · \(entry.modeName) — открыть")
                }
                if entries.count > 8 {
                    Text("и ещё \(entries.count - 8)…").scaledFont(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
