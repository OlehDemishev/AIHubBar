import AppIntents
import SwiftUI
import WidgetKit

/// `widget-status.json` written by ClaudePult: who waits for an answer, how many sessions run, red projects,
/// whether «Не спать» holds.
struct WidgetStatusData: Decodable {
    var waiting: [String]
    var running: Int
    var problems: [String]
    var keepAwake: Bool
    var keepAwakeInstalled: Bool

    static var fileURL: URL { WidgetUsage.fileURL.deletingLastPathComponent().appending(path: "widget-status.json") }

    static func load() -> WidgetStatusData? {
        (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode(WidgetStatusData.self, from: $0) }
    }

    static let sample = WidgetStatusData(waiting: ["Survikon"], running: 2, problems: ["Ambo", "Cantero"], keepAwake: true, keepAwakeInstalled: true)
}

struct StatusEntry: TimelineEntry {
    var date: Date
    var status: WidgetStatusData?
}

struct StatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatusEntry { StatusEntry(date: .now, status: .sample) }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        completion(StatusEntry(date: .now, status: context.isPreview ? .sample : WidgetStatusData.load() ?? .sample))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        // ClaudePult reloads the timeline whenever the file changes; this is only the fallback.
        completion(Timeline(entries: [StatusEntry(date: .now, status: WidgetStatusData.load())], policy: .after(.now.addingTimeInterval(15 * 60))))
    }
}

struct StatusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StatusEntry

    var body: some View {
        Group {
            if let status = entry.status {
                VStack(alignment: .leading, spacing: 6) {
                    row(symbol: "hand.raised.fill", color: status.waiting.isEmpty ? .secondary : .orange,
                        count: status.waiting.count, title: String(localized: "ждут ответа"), names: status.waiting)
                    row(symbol: "bolt.fill", color: status.running > 0 ? .blue : .secondary,
                        count: status.running, title: String(localized: "работают"), names: [])
                    row(symbol: "exclamationmark.circle.fill", color: status.problems.isEmpty ? .secondary : .red,
                        count: status.problems.count, title: String(localized: "проекты с проблемами"), names: status.problems)
                    Spacer(minLength: 0)
                }
            } else {
                Text("Откройте AI Hub Bar").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private func row(symbol: String, color: Color, count: Int, title: String, names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(color)
                Text(verbatim: "\(count)").font(.title3.weight(.semibold)).monospacedDigit()
                Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if family != .systemSmall, !names.isEmpty {
                Text(names.joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.leading, 22)
            }
        }
    }
}

struct StatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ClaudePultStatus", provider: StatusProvider()) { entry in
            StatusWidgetView(entry: entry)
        }
        .configurationDisplayName("Сессии и проекты")
        .description("Кто из Claude ждёт ответа, сколько работает и какие проекты с проблемами — из AI Hub Bar.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Control Center: «Не спать»

@available(macOS 26.0, *)
struct KeepAwakeControl: ControlWidget {
    static let kind = "com.demishev.claudepult.keepawake"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: KeepAwakeValue()) { isOn in
            ControlWidgetToggle("Не спать", isOn: isOn, action: SetKeepAwakeIntent()) { on in
                Label(on ? "Mac не засыпает" : "Mac засыпает как обычно", systemImage: on ? "cup.and.saucer.fill" : "cup.and.saucer")
            }
        }
        .displayName("Не спать (AI Hub Bar)")
        .description("Не давать Mac засыпать, пока не выключите.")
    }
}

@available(macOS 26.0, *)
struct KeepAwakeValue: ControlValueProvider {
    var previewValue: Bool { false }

    func currentValue() async throws -> Bool { WidgetStatusData.load()?.keepAwake ?? false }
}

/// Runs in the sandboxed extension: it can't touch the app's files, so it posts a Darwin notification
/// (`com.demishev.claudepult.keepawake.on` / `.off`) that ClaudePult listens for.
@available(macOS 26.0, *)
struct SetKeepAwakeIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Не спать"

    @Parameter(title: "Включено")
    var value: Bool

    func perform() async throws -> some IntentResult {
        let name = value ? "com.demishev.claudepult.keepawake.on" : "com.demishev.claudepult.keepawake.off"
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true)
        return .result()
    }
}
