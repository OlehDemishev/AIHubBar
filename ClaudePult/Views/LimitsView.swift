import SwiftUI

/// «Лимиты» block at the top of the panel (spec §2.8): bars, resets, forecast, extra usage, per-project breakdown.
struct LimitsView: View {
    @Environment(UsageStore.self) private var usage
    @Environment(LaunchController.self) private var launcher
    @Environment(CommandEngine.self) private var engine
    @AppStorage("limitsBreakdownExpanded") private var showBreakdown = false
    @State private var period: UsageStore.Period = .session
    @AppStorage("collapsedBlocks") private var collapsedRaw = ""

    private var collapsed: Bool { PanelBlock.collapsed(in: collapsedRaw).contains(.limits) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if !collapsed { details }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var details: some View {
        if let snapshot = usage.snapshot {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(alignment: .leading, spacing: 8) {
                    if let session = snapshot.session {
                        WindowRow(window: session, detail: sessionDetail(session, now: context.date), now: context.date)
                    }
                    if let week = snapshot.week {
                        WindowRow(window: week, detail: nil, now: context.date)
                    }
                    ForEach(snapshot.shownOtherWindows, id: \.key) { window in
                        // A model week usually resets with the week: no need to say it twice.
                        WindowRow(window: window, detail: nil, now: context.date, compact: true,
                                  showsReset: window.resetsAt != snapshot.week?.resetsAt)
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

    private func sessionDetail(_ session: UsageWindow, now: Date) -> String? {
        [UsageText.resetText(session, now: now), UsageText.forecast(usage.forecast)]
            .compactMap { $0 }.joined(separator: " · ")
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
