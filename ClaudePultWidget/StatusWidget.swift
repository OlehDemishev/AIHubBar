import AppIntents
import SwiftUI
import WidgetKit

/// `widget-status.json` written by ClaudePult: who waits for an answer, how many sessions run, red projects,
/// whether «Не спать» holds.
struct WidgetStatusData: Decodable {
    struct Session: Decodable {
        var id: String
        var project: String
    }

    var waiting: [String]
    /// Missing in files written by AI Hub Bar before 0.3.0.
    var waitingSessions: [Session]?
    var running: Int
    var problems: [String]
    var keepAwake: Bool
    var keepAwakeInstalled: Bool

    static var fileURL: URL { WidgetUsage.fileURL.deletingLastPathComponent().appending(path: "widget-status.json") }

    static func load() -> WidgetStatusData? {
        (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode(WidgetStatusData.self, from: $0) }
    }

    static let sample = WidgetStatusData(waiting: ["Survikon"], waitingSessions: [Session(id: "sample", project: "Survikon")], running: 2,
                                         problems: ["Ambo", "Cantero"], keepAwake: true, keepAwakeInstalled: true)

    /// A click on the small widget: the one waiting session, otherwise the search with every session and project.
    var mainLink: URL {
        if let sessions = waitingSessions, sessions.count == 1 { return WidgetLink.session(sessions[0].id) }
        return WidgetLink.search
    }
}

/// `aihubbar://` links the app opens (ClaudePult/Models/WidgetLink.swift reads them).
enum WidgetLink {
    static let limits = URL(string: "aihubbar://limits")!
    static let search = URL(string: "aihubbar://search")!

    static func session(_ id: String) -> URL {
        URL(string: "aihubbar://session/" + (id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)) ?? search
    }
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
                    waitingRow(status)
                    linked(WidgetLink.search) {
                        row(symbol: "bolt.fill", color: status.running > 0 ? .blue : .secondary,
                            count: status.running, title: String(localized: "работают"))
                    }
                    linked(WidgetLink.search) {
                        VStack(alignment: .leading, spacing: 1) {
                            row(symbol: "exclamationmark.circle.fill", color: status.problems.isEmpty ? .secondary : .red,
                                count: status.problems.count, title: String(localized: "проекты с проблемами"))
                            if family != .systemSmall, !status.problems.isEmpty {
                                names(Text(status.problems.joined(separator: ", ")))
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .overlay(alignment: .topTrailing) {
                    if status.keepAwakeInstalled { KeepAwakeButton(isOn: status.keepAwake) }
                }
                .widgetURL(status.mainLink)
            } else {
                Text("Откройте AI Hub Bar").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    /// The medium widget links each waiting project to its own session; the row itself opens the first one.
    @ViewBuilder
    private func waitingRow(_ status: WidgetStatusData) -> some View {
        let sessions = status.waitingSessions ?? []
        VStack(alignment: .leading, spacing: 1) {
            linked(sessions.first.map { WidgetLink.session($0.id) } ?? WidgetLink.search) {
                row(symbol: "hand.raised.fill", color: status.waiting.isEmpty ? .secondary : .orange,
                    count: status.waiting.count, title: String(localized: "ждут ответа"))
            }
            if family != .systemSmall, !status.waiting.isEmpty {
                if sessions.isEmpty {
                    names(Text(status.waiting.joined(separator: ", ")))
                } else {
                    HStack(spacing: 0) {
                        ForEach(Array(sessions.enumerated()), id: \.offset) { index, session in
                            Link(destination: WidgetLink.session(session.id)) {
                                Text(verbatim: index == 0 ? session.project : ", " + session.project)
                            }
                        }
                    }
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.leading, 22)
                }
            }
        }
    }

    /// The small widget is one tap target (`widgetURL`); the medium one takes a link per row.
    @ViewBuilder
    private func linked(_ url: URL, @ViewBuilder _ content: () -> some View) -> some View {
        if family == .systemSmall {
            content()
        } else {
            Link(destination: url, label: content)
        }
    }

    private func row(symbol: String, color: Color, count: Int, title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(verbatim: "\(count)").font(.title3.weight(.semibold)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func names(_ text: Text) -> some View {
        text.font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            .padding(.leading, 22)
    }
}

/// «Не спать» right in the widget: the same request the Control Center toggle sends, without opening the app.
struct KeepAwakeButton: View {
    let isOn: Bool

    var body: some View {
        Button(intent: SetKeepAwakeIntent(value: !isOn)) {
            Image(systemName: isOn ? "cup.and.saucer.fill" : "cup.and.saucer")
                .foregroundStyle(isOn ? Color.orange : Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Не спать"))
        .accessibilityValue(isOn ? Text("Mac не засыпает") : Text("Mac засыпает как обычно"))
        .help(isOn ? String(localized: "Mac не засыпает — нажмите, чтобы выключить") : String(localized: "Не давать Mac засыпать"))
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
/// (`com.demishev.claudepult.keepawake.on` / `.off`) that ClaudePult listens for. Also the status widget's ☕ button.
struct SetKeepAwakeIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Не спать"

    @Parameter(title: "Включено")
    var value: Bool

    init() {}

    init(value: Bool) {
        self.value = value
    }

    func perform() async throws -> some IntentResult {
        let name = value ? "com.demishev.claudepult.keepawake.on" : "com.demishev.claudepult.keepawake.off"
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true)
        // WidgetKit redraws when this returns: give the app a moment to write the new state, so ☕ doesn't flicker back.
        await WidgetWait.until(seconds: 2) { WidgetStatusData.load()?.keepAwake == value }
        return .result()
    }
}

/// The limits widget's ↻: asks the app to fetch the limits now (it keeps its own pauses after HTTP 429).
struct RefreshLimitsIntent: AppIntent {
    static let title: LocalizedStringResource = "Обновить лимиты"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        let before = WidgetUsage.load()?.updated
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName("com.demishev.claudepult.limits.refresh" as CFString), nil, nil, true)
        await WidgetWait.until(seconds: 4) { WidgetUsage.load()?.updated != before }
        return .result()
    }
}

enum WidgetWait {
    /// Polls a file the app writes; the app reloads the widget itself if it takes longer.
    static func until(seconds: Double, _ done: () -> Bool) async {
        for _ in 0..<Int(seconds * 5) where !done() {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }
}
