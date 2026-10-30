import OSLog
import SwiftUI
import WidgetKit

private let log = Logger(subsystem: "com.demishev.claudepult.widget", category: "usage")

/// `usage.json` written by ClaudePult (spec §2.8): `five_hour`, `seven_day`, `updated`.
struct WidgetUsage: Decodable, Equatable {
    struct Window: Decodable, Equatable {
        var utilization: Double
        var resetsAt: Date?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            utilization = try c.decode(Double.self, forKey: .utilization)
            resetsAt = (try? c.decodeIfPresent(String.self, forKey: .resetsAt)).flatMap { $0.flatMap(WidgetUsage.date) }
        }

        init(utilization: Double, resetsAt: Date?) {
            self.utilization = utilization
            self.resetsAt = resetsAt
        }
    }

    var session: Window?
    var week: Window?
    var updated: Date?

    enum CodingKeys: String, CodingKey {
        case session = "five_hour"
        case week = "seven_day"
        case updated
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        session = try? c.decodeIfPresent(Window.self, forKey: .session)
        week = try? c.decodeIfPresent(Window.self, forKey: .week)
        updated = (try? c.decodeIfPresent(String.self, forKey: .updated)).flatMap { $0.flatMap(WidgetUsage.date) }
    }

    init(session: Window?, week: Window?, updated: Date?) {
        self.session = session
        self.week = week
        self.updated = updated
    }

    static func date(_ string: String) -> Date? {
        (try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(string, strategy: Date.ISO8601FormatStyle()))
    }

    /// The real home folder: inside the sandbox `NSHomeDirectory()` points to the widget's container.
    static var fileURL: URL {
        let home = getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appending(path: "Library/Application Support/ClaudePult/usage.json")
    }

    static func load() -> WidgetUsage? {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            log.error("Cannot read usage.json: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let usage = try? JSONDecoder().decode(WidgetUsage.self, from: data)
        log.notice("usage.json read: session \(usage?.session?.utilization ?? -1, privacy: .public)%")
        return usage
    }

    static let sample = WidgetUsage(
        session: Window(utilization: 34, resetsAt: .now.addingTimeInterval(2 * 3600 + 14 * 60)),
        week: Window(utilization: 58, resetsAt: .now.addingTimeInterval(3 * 86_400)),
        updated: .now
    )
}

struct UsageEntry: TimelineEntry {
    var date: Date
    var usage: WidgetUsage?
    var otherAI: [WidgetOtherAI] = WidgetOtherAI.load()
}

/// `other-ai.json` written by AI Hub Bar: the fullest limit of each other AI service (SPEC-hub).
struct WidgetOtherAI: Decodable, Equatable {
    var name: String
    var percent: Double

    static func load() -> [WidgetOtherAI] {
        let url = WidgetUsage.fileURL.deletingLastPathComponent().appending(path: "other-ai.json")
        return (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([WidgetOtherAI].self, from: $0) } ?? []
    }
}

struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: .now, usage: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(UsageEntry(date: .now, usage: context.isPreview ? (WidgetUsage.load() ?? .sample) : WidgetUsage.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        // ClaudePult asks WidgetKit to reload after each update; this is the fallback schedule.
        let entry = UsageEntry(date: .now, usage: WidgetUsage.load())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(5 * 60))))
    }
}

/// Green < 50 %, orange 50–80 %, red > 80 % — same as the app.
func levelColor(_ percent: Double) -> Color {
    percent > 80 ? .red : percent >= 50 ? .orange : .green
}

func resetText(_ date: Date?, now: Date) -> String? {
    guard let date else { return nil }
    let minutes = Int(max(0, date.timeIntervalSince(now)) / 60)
    if minutes < 60 { return String(localized: "сброс через \(minutes) мин") }
    if minutes < 24 * 60 { return String(localized: "сброс через \(minutes / 60) ч \(minutes % 60) мин") }
    return String(localized: "сброс \(date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
}

struct SmallUsageView: View {
    let entry: UsageEntry

    var body: some View {
        if let session = entry.usage?.session {
            VStack(spacing: 6) {
                ZStack {
                    Circle().stroke(.quaternary, lineWidth: 9)
                    Circle()
                        .trim(from: 0, to: min(session.utilization, 100) / 100)
                        .stroke(levelColor(session.utilization), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text("\(Int(session.utilization.rounded()))%")
                            .font(.title2.weight(.semibold))
                            .monospacedDigit()
                        Text("сессия").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                if let reset = resetText(session.resetsAt, now: entry.date) {
                    Text(reset).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                }
            }
        } else {
            NoDataView()
        }
    }
}

struct MediumUsageView: View {
    let entry: UsageEntry

    var body: some View {
        if let usage = entry.usage, usage.session != nil || usage.week != nil {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Лимиты Claude", systemImage: "sparkle").font(.headline)
                    Spacer()
                    if let updated = usage.updated {
                        Text(updated, style: .relative).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if let session = usage.session { row(String(localized: "Сессия (5 ч)"), session) }
                if let week = usage.week { row(String(localized: "Неделя"), week) }
                if !entry.otherAI.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(Array(entry.otherAI.prefix(3).enumerated()), id: \.offset) { _, other in
                            HStack(spacing: 3) {
                                Text(other.name).foregroundStyle(.secondary)
                                Text("\(Int(other.percent.rounded()))%")
                                    .monospacedDigit()
                                    .foregroundStyle(levelColor(other.percent))
                            }
                        }
                    }
                    .font(.caption2)
                    .lineLimit(1)
                }
            }
        } else {
            NoDataView()
        }
    }

    private func row(_ title: String, _ window: WidgetUsage.Window) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.caption.weight(.medium))
                Spacer()
                Text("\(Int(window.utilization.rounded())) %")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(levelColor(window.utilization))
            }
            ProgressView(value: min(window.utilization, 100), total: 100)
                .tint(levelColor(window.utilization))
            if let reset = resetText(window.resetsAt, now: entry.date) {
                Text(reset).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct NoDataView: View {
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "sparkle").font(.title2)
            Text("Нет данных — откройте AI Hub Bar").font(.caption).multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
    }
}

struct UsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry

    var body: some View {
        Group {
            switch family {
            case .systemSmall: SmallUsageView(entry: entry)
            default: MediumUsageView(entry: entry)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct UsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ClaudePultUsage", provider: UsageProvider()) { entry in
            UsageWidgetView(entry: entry)
        }
        .configurationDisplayName("Лимиты Claude")
        .description("Сессия и неделя подписки Claude — из AI Hub Bar.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct ClaudePultWidgetBundle: WidgetBundle {
    var body: some Widget {
        UsageWidget()
        StatusWidget()
        if #available(macOS 26.0, *) {
            KeepAwakeControl()
        }
    }
}
