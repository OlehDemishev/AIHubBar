import SwiftUI

/// «Лимиты» block at the top of the panel (spec §2.8): bars, resets, forecast, extra usage, per-project breakdown.
struct LimitsView: View {
    @Environment(UsageStore.self) private var usage
    @Environment(HubLimitsStore.self) private var hub
    @Environment(LaunchController.self) private var launcher
    @Environment(CommandEngine.self) private var engine
    @AppStorage("limitsBreakdownExpanded") private var showBreakdown = false
    @State private var period: UsageStore.Period = .session
    @AppStorage("collapsedBlocks") private var collapsedRaw = ""

    private var collapsed: Bool { PanelBlock.collapsed(in: collapsedRaw).contains(.limits) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if !collapsed {
                details
                hubRows
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    /// Other AI services (SPEC-hub), one compact row each, under Claude's own limits.
    @ViewBuilder
    private var hubRows: some View {
        if !hub.limits.isEmpty {
            Divider().padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(hub.limits) { limit in
                    HubRow(limit: limit)
                }
            }
        }
    }

    @ViewBuilder
    private var details: some View {
        if let snapshot = usage.snapshot {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        if let session = snapshot.session {
                            LimitRing(window: session, caption: UsageText.resetText(session, now: context.date, short: true))
                        }
                        if let week = snapshot.week {
                            LimitRing(window: week, caption: UsageText.resetText(week, now: context.date, short: true))
                        }
                    }
                    if let forecast = UsageText.forecast(usage.forecast) {
                        Text(forecast)
                            .scaledFont(.caption)
                            .foregroundStyle(runsOut ? .orange : .secondary)
                    }
                    if let week = usage.weekUsage, !week.days.isEmpty {
                        WeekStrip(week: week)
                    }
                    ForEach(snapshot.shownOtherWindows, id: \.key) { window in
                        // A model week usually resets with the week: no need to say it twice.
                        WindowRow(window: window, detail: nil, now: context.date, compact: true,
                                  showsReset: !UsageWindow.sameReset(window.resetsAt, snapshot.week?.resetsAt))
                    }
                }
            }
            // Figures that could not be refreshed are not passed off as current.
            .opacity(isStale ? 0.45 : 1)
            if let extra = snapshot.extra, extra.isEnabled {
                Label(extraText(extra), systemImage: "creditcard")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
            }
            // Models by API (SPEC-modes §11.2): shown once ClaudePult has spent something this month.
            let month = engine.summary(since: engine.monthStart)
            if month.tokens > 0 {
                Label("API за месяц: \(SpendText.line(month))", systemImage: "cpu")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = usage.error {
                Label("Не обновилось: \(error)", systemImage: "exclamationmark.triangle")
                    .scaledFont(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let error = usage.error {
            Label("Лимиты недоступны. \(error)", systemImage: "exclamationmark.triangle")
                .scaledFont(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Загружаю лимиты…").scaledFont(.caption).foregroundStyle(.secondary)
            }
        }

        ForEach(launcher.queued) { item in
            QueuedRow(item: item)
        }

        breakdown
    }

    private var isStale: Bool { usage.error != nil }

    private var runsOut: Bool {
        if case .runsOutAt = usage.forecast { return true }
        return false
    }

    /// The panel's own refresh (⌘R) updates the limits too; the age shows only while the figures are old.
    private var header: some View {
        HStack(spacing: 6) {
            BlockTitle(block: .limits, title: "Лимиты")
            // Folded, the block still says the two numbers that matter.
            if collapsed, let snapshot = usage.snapshot {
                Text(verbatim: [snapshot.session, snapshot.week].compactMap { $0.map { UsageText.percent($0.utilization) } }.joined(separator: " · "))
                    .scaledFont(.caption, weight: .semibold)
                    .monospacedDigit()
                    .opacity(isStale ? 0.45 : 1)
            }
            Spacer()
            if usage.isRefreshing {
                ProgressView().controlSize(.mini)
            } else if isStale, let fetched = usage.snapshot?.fetchedAt {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text("данные \(RelativeTime.ago(fetched, now: context.date))")
                        .scaledFont(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func extraText(_ extra: ExtraUsage) -> String {
        guard let used = extra.usedCredits else { return String(localized: "Extra usage включён") }
        let usedText = UsageText.money(used, decimals: extra.decimalPlaces, currency: extra.currency)
        guard let limit = extra.monthlyLimit else { return "Extra usage: \(usedText)" }
        return String(localized: "Extra usage: \(usedText) из \(UsageText.money(limit, decimals: extra.decimalPlaces, currency: extra.currency)) в месяц")
    }

    @ViewBuilder
    private var breakdown: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { showBreakdown.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(showBreakdown ? 90 : 0))
                    Text("Расход по проектам")
                    Spacer()
                }
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showBreakdown {
                Picker("", selection: $period) {
                    ForEach(UsageStore.Period.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)

                if let data = usage.breakdowns[period], !data.projects.isEmpty {
                    ForEach(data.projects.prefix(6)) { row in
                        HStack(spacing: 6) {
                            Text(row.name).lineLimit(1)
                            Spacer()
                            Text(TokenBreakdown.tokensText(row.tokens)).foregroundStyle(.secondary)
                            Text("\(Int((row.share * 100).rounded())) %")
                                .monospacedDigit()
                                .frame(width: 38, alignment: .trailing)
                        }
                        .scaledFont(.caption)
                    }
                    if let top = data.topSession {
                        Text("Самая затратная сессия: \(top.project) — \(Int((top.share * 100).rounded())) % (\(TokenBreakdown.tokensText(top.tokens)) токенов)")
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text(usage.breakdownUpdated == nil ? String(localized: "Считаю по журналам Claude Code…") : String(localized: "За этот период расхода нет"))
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Оценка по журналам Claude Code, а не точный расход лимита. Доли учитывают цену токенов (вывод ×5, чтение кэша ×0,1); токены — без чтения кэша.")
                    .scaledFont(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One limit: title, inline reset and percent on one line, then the bar; the session keeps a line of its own
/// for the reset and the forecast.
private struct WindowRow: View {
    let window: UsageWindow
    let detail: String?
    let now: Date
    var compact = false
    var showsReset = true

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(window.title)
                    .scaledFont(.caption, weight: compact ? .regular : .medium)
                    .layoutPriority(1)
                if detail == nil, showsReset, let reset = UsageText.resetText(window, now: now) {
                    Text(verbatim: "· " + reset)
                        .scaledFont(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(UsageText.percent(window.utilization))
                    .scaledFont(.caption, weight: .semibold)
                    .monospacedDigit()
                    .foregroundStyle(window.levelColor)
            }
            ProgressView(value: min(max(window.utilization, 0), 100), total: 100)
                .progressViewStyle(.linear)
                .tint(window.levelColor)
                .controlSize(compact ? .mini : .small)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .scaledFont(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// One other service: its name, then each window as «title · reset … percent» with a thin bar, or its spend.
private struct HubRow: View {
    let limit: HubLimit

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(limit.source.title)
                .scaledFont(.caption, weight: .medium)
            if let error = limit.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .scaledFont(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(limit.windows.enumerated()), id: \.offset) { _, window in
                HubWindowRow(window: window)
            }
        }
        .help([limit.source.title, limit.error].compactMap { $0 }.joined(separator: " · "))
    }
}

private struct HubWindowRow: View {
    let window: HubLimit.Window

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(window.title)
                    .scaledFont(.caption2)
                    .lineLimit(1)
                if let reset = window.resetsAt {
                    Text(verbatim: "· " + String(localized: "сброс \(reset.formatted(.relative(presentation: .named)))"))
                        .scaledFont(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if let percent = window.percent {
                    Text(UsageText.percent(percent))
                        .scaledFont(.caption, weight: .semibold)
                        .monospacedDigit()
                        .foregroundStyle(UsageWindow.color(for: percent))
                } else if let detail = window.detail {
                    Text(detail)
                        .scaledFont(.caption, weight: .semibold)
                        .monospacedDigit()
                }
            }
            if let percent = window.percent {
                ProgressView(value: min(max(percent, 0), 100), total: 100)
                    .progressViewStyle(.linear)
                    .tint(UsageWindow.color(for: percent))
                    .controlSize(.mini)
                if let detail = window.detail {
                    Text(detail).scaledFont(.caption2).foregroundStyle(.secondary)
                }
                if let runsOut = window.runsOutAt {
                    Text("кончится \(runsOut.formatted(.dateTime.weekday(.abbreviated).hour().minute())) при таком темпе")
                        .scaledFont(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}

/// The week's forecast and its days as small bars (today highlighted); hover a bar for its share of the week.
private struct WeekStrip: View {
    let week: WeekUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch week.forecast {
            case let .runsOutAt(date):
                Text("неделя кончится \(date.formatted(.dateTime.weekday(.abbreviated).hour().minute())) при таком темпе")
                    .foregroundStyle(.orange)
            case .lastsUntilReset:
                Text("неделе до сброса хватит")
                    .foregroundStyle(.secondary)
            case .unknown:
                EmptyView()
            }
            let top = max(week.days.map(\.percent).max() ?? 0, 1)
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(week.days) { day in
                    VStack(spacing: 2) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(day.isToday ? Color.accentColor : Color.primary.opacity(0.25))
                            .frame(height: max(2, 24 * day.percent / top))
                        Text(day.date.formatted(.dateTime.weekday(.narrow)))
                            .scaledFont(.caption2)
                            .foregroundStyle(day.isToday ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .help(String(localized: "\(day.date.formatted(.dateTime.weekday(.wide).day().month())): \(Int(day.percent.rounded())) % недельного лимита"))
                }
            }
            .frame(height: 40)
        }
        .scaledFont(.caption)
    }
}

/// Session or week: a ring in the level colour, the percentage, the window and when it resets.
private struct LimitRing: View {
    let window: UsageWindow
    let caption: String?

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.12), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: min(max(window.utilization, 0), 100) / 100)
                    .stroke(window.levelColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(UsageText.percent(window.utilization))
                    .scaledFont(.title3, weight: .semibold)
                    .monospacedDigit()
                    .foregroundStyle(window.levelColor)
                Text(window.title)
                    .scaledFont(.caption)
                    .lineLimit(1)
                if let caption {
                    Text(caption)
                        .scaledFont(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help([window.title, UsageText.percent(window.utilization), caption].compactMap { $0 }.joined(separator: " · "))
    }
}

private struct QueuedRow: View {
    let item: LaunchController.QueuedLaunch
    @Environment(LaunchController.self) private var launcher

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(.blue)
            Text("\(item.projectName): \(item.command.title) — запуск в \(item.launchAt.formatted(date: .omitted, time: .shortened))")
                .lineLimit(2)
            Spacer()
            Button("Отменить") { launcher.cancelQueued(item.id) }
                .controlSize(.mini)
        }
        .scaledFont(.caption)
    }
}

extension UsageWindow {
    var levelColor: Color { Self.color(for: utilization) }

    /// Green below 50 %, orange to 80 %, red above — limits and Mac resources alike.
    static func color(for value: Double) -> Color {
        switch UsageLevel(value) {
        case .low: .green
        case .medium: .orange
        case .high: .red
        }
    }
}
