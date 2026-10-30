import SwiftUI

/// «Лимиты» block at the top of the panel (spec §2.8): bars, resets, forecast, extra usage, per-project breakdown.
struct LimitsView: View {
    @Environment(UsageStore.self) private var usage
    @Environment(LaunchController.self) private var launcher
    @Environment(CommandEngine.self) private var engine
    @AppStorage("limitsBreakdownExpanded") private var showBreakdown = false
    @State private var period: UsageStore.Period = .session

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if let snapshot = usage.snapshot {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(alignment: .leading, spacing: 8) {
                        if let session = snapshot.session {
                            WindowRow(window: session, detail: sessionDetail(session, now: context.date), now: context.date)
                        }
                        if let week = snapshot.week {
                            WindowRow(window: week, detail: nil, now: context.date)
                        }
                        ForEach(snapshot.otherWindows, id: \.key) { window in
                            WindowRow(window: window, detail: nil, now: context.date, compact: true)
                        }
                    }
                }
                if let extra = snapshot.extra, extra.isEnabled {
                    Label(extraText(extra), systemImage: "creditcard")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                }
                // Models by API (SPEC-modes §11.2): shown once ClaudePult has spent something this month.
                let month = engine.summary(since: engine.monthStart)
                if month.tokens > 0 {
                    Label("API за месяц: " + SpendText.line(month), systemImage: "cpu")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error = usage.error {
                    Label("Не обновилось: \(error)", systemImage: "exclamationmark.triangle")
                        .scaledFont(.caption)
                        .foregroundStyle(.orange)
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
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Лимиты")
                .scaledFont(.caption, weight: .semibold)
                .foregroundStyle(.secondary)
            Spacer()
            if let fetched = usage.snapshot?.fetchedAt {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(RelativeTime.ago(fetched, now: context.date))
                        .scaledFont(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Button {
                Task { await usage.refresh() }
            } label: {
                if usage.isRefreshing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise").scaledFont(.caption)
                }
            }
            .buttonStyle(.borderless)
            .disabled(usage.isRefreshing || (usage.pausedUntil.map { $0 > .now } ?? false))
            .help(usage.pausedUntil.map { $0 > .now ? "Пауза до \($0.formatted(date: .omitted, time: .shortened)): сервер просит запрашивать реже" : "Обновить лимиты" } ?? "Обновить лимиты")
        }
    }

    private func sessionDetail(_ session: UsageWindow, now: Date) -> String? {
        [UsageText.resetText(session, now: now), UsageText.forecast(usage.forecast)]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func extraText(_ extra: ExtraUsage) -> String {
        guard let used = extra.usedCredits else { return "Extra usage включён" }
        let usedText = UsageText.money(used, decimals: extra.decimalPlaces, currency: extra.currency)
        guard let limit = extra.monthlyLimit else { return "Extra usage: \(usedText)" }
        return "Extra usage: \(usedText) из \(UsageText.money(limit, decimals: extra.decimalPlaces, currency: extra.currency)) в месяц"
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
                    Text(usage.breakdownUpdated == nil ? "Считаю по журналам Claude Code…" : "За этот период расхода нет")
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

private struct WindowRow: View {
    let window: UsageWindow
    let detail: String?
    let now: Date
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(window.title)
                    .scaledFont(.caption, weight: compact ? .regular : .medium)
                Spacer()
                Text(UsageText.percent(window.utilization))
                    .scaledFont(.caption, weight: .semibold)
                    .monospacedDigit()
                    .foregroundStyle(window.levelColor)
            }
            ProgressView(value: min(max(window.utilization, 0), 100), total: 100)
                .progressViewStyle(.linear)
                .tint(window.levelColor)
                .controlSize(compact ? .mini : .small)
            if let text = detail ?? UsageText.resetText(window, now: now), !text.isEmpty {
                Text(text)
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
    var levelColor: Color {
        switch UsageLevel(utilization) {
        case .low: .green
        case .medium: .orange
        case .high: .red
        }
    }
}
