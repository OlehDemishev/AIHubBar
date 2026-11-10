import AppKit
import SwiftUI

/// «Лимиты» block at the top of the panel (spec §2.8): bars, resets, forecast, extra usage, per-project breakdown.
struct LimitsView: View {
    @Environment(\.panelCalm) private var panelCalm
    @Environment(UsageStore.self) private var usage
    @Environment(HubLimitsStore.self) private var hub
    @Environment(ClaudeAccountsStore.self) private var accounts
    @Environment(LaunchController.self) private var launcher
    @Environment(CommandEngine.self) private var engine
    @Environment(AIServiceStore.self) private var services
    @Environment(AppSettings.self) private var settings
    @Environment(\.openWindow) private var openWindow
    @AppStorage(StorageKey.limitsBreakdownExpanded) private var showBreakdown = false
    @State private var period: UsageStore.Period = .session
    @AppStorage(StorageKey.collapsedBlocks) private var collapsedRaw = ""

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

    /// Other AI services (SPEC-hub) under Claude, each drawn by the same card (SPEC-ai-services stage 2).
    @ViewBuilder
    private var hubRows: some View {
        ForEach(accounts.usages) { account in
            Divider().padding(.vertical, 2)
            ServiceCard(usage: account)
        }
        ForEach(hub.usages) { service in
            Divider().padding(.vertical, 2)
            ServiceCard(usage: service)
        }
    }

    private var signIn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Чтобы видеть лимиты подписки, войдите в Claude Code.")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
            Button("Войти в Claude Code") { ClaudeSignIn.start(usage: usage, claudePath: settings.claudePath) }
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private var details: some View {
        if let snapshot = usage.snapshot {
            ServiceCard(usage: .claude(snapshot, forecast: usage.forecast, pace: usage.pace, week: usage.weekUsage, error: usage.lastError),
                        showsTitle: !hub.limits.isEmpty || !accounts.usages.isEmpty, showsDetails: false)
            // A snapshot is kept for a day: an expired sign-in must still say so.
            if usage.signedOut, services.agents[.claudeCode] != nil { signIn }
            // Models by API (SPEC-modes §11.2): shown once AI Hub Bar has spent something this month.
            let month = engine.summary(since: engine.monthStart)
            if month.tokens > 0 {
                Label("API за месяц: \(SpendText.line(month))", systemImage: "cpu")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if usage.signedOut, services.hasScanned, services.agents[.claudeCode] == nil {
            VStack(alignment: .leading, spacing: 6) {
                Text("Лимиты подписки показывает Claude Code.")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                Button("Установить Claude Code") { ClaudeSignIn.openInstallPage() }
                    .controlSize(.small)
            }
        } else if usage.signedOut {
            signIn
        } else if let error = usage.lastError {
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

        if let outage = usage.outage {
            HStack(spacing: 6) {
                Label("Сбой у Anthropic: \(outage)", systemImage: "exclamationmark.icloud")
                    .scaledFont(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Link("Подробнее", destination: ServiceStatus.page)
                    .scaledFont(.caption)
            }
        }


        breakdown
    }

    private var isStale: Bool { usage.lastError != nil }

    /// The panel's own refresh (⌘R) updates the limits too; the age shows only while the figures are old.
    private var header: some View {
        HStack(spacing: 6) {
            BlockTitle(block: .limits, title: "Лимиты AI")
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

    @ViewBuilder
    private var breakdown: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(panelCalm ? nil : .snappy(duration: 0.2)) { showBreakdown.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(showBreakdown ? 90 : 0))
                            .flipsForRightToLeftLayoutDirection(true)
                    Text("Подробнее")
                    Spacer()
                }
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showBreakdown {
                if let week = usage.weekUsage, !week.days.isEmpty { WeekStrip(week: week) }
                Text("Расход по проектам")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                Picker("Период", selection: $period) {
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
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("История расхода…") {
                    NSApp.activate()
                    openWindow(.usageHistory)
                }
                .buttonStyle(.link)
                .scaledFont(.caption)
            }
        }
    }
}

/// One service's limits, the same for Claude and every other AI (SPEC-ai-services stage 2). The first limit is the
/// main one: a big number over a bar with the pace beside it, or rings for those who chose them. A forecast is shown
/// only when it is bad news; the week by day and the projects wait behind «Подробнее».
private struct ServiceCard: View {
    let usage: ServiceUsage
    var showsTitle = true
    /// False for Claude, whose details (with its own spend by project) are drawn by `LimitsView`.
    var showsDetails = true
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsTitle {
                Text(usage.title)
                    .scaledFont(.caption, weight: .semibold)
                    .foregroundStyle(.secondary)
            }
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(alignment: .leading, spacing: 8) {
                    if settings.limitsStyle == .rings {
                        if !usage.rings.isEmpty {
                            HStack(alignment: .top, spacing: 8) {
                                ForEach(usage.rings) { window in
                                    LimitRing(window: window, caption: UsageText.resetText(window.resetsAt, now: context.date, short: true))
                                }
                            }
                        }
                    } else {
                        // The big number is Claude's: the other services are a glance, two limits in a row.
                        if isMain, let main = usage.rings.first {
                            MainLimit(window: main, pace: usage.pace, now: context.date)
                        }
                        if !secondary.isEmpty {
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14, alignment: .top), GridItem(.flexible(), alignment: .top)],
                                      alignment: .leading, spacing: 8) {
                                ForEach(secondary) { SmallLimit(window: $0, now: context.date) }
                            }
                        }
                    }
                    ForEach(warnings, id: \.self) { line in
                        Text(line)
                            .scaledFont(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(rows) { window in
                        WindowRow(window: window, now: context.date)
                    }
                }
            }
            // Figures that could not be refreshed are not passed off as current.
            .opacity(usage.isStale ? 0.45 : 1)
            ForEach(usage.notes, id: \.self) { note in
                Label(note.text, systemImage: note.symbol)
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
            }
            if showsDetails, hasDetails {
                ServiceDetails(week: usage.week, projects: usage.projects, footnote: projectsFootnote)
            }
            if let error = usage.error {
                Label(usage.rings.isEmpty && usage.bars.isEmpty ? error : String(localized: "Не обновилось: \(error)"),
                      systemImage: "exclamationmark.triangle")
                    .scaledFont(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .help([usage.title, usage.error].compactMap { $0 }.joined(separator: " · "))
    }

    private var bars: Bool { settings.limitsStyle == .bars }
    /// Beside the main limit, two in a row: the other main limits and the bars that have a percentage.
    private var secondary: [LimitWindow] {
        Array(usage.rings.dropFirst(isMain ? 1 : 0)) + usage.bars.filter { $0.percent != nil }
    }
    private var isMain: Bool {
        switch usage.service {
        case .claude, .claudeAccount: true
        case .hub: false
        }
    }
    /// Full-width rows: everything that isn't a ring with rings, only plain spend with bars.
    private var rows: [LimitWindow] { bars ? usage.bars.filter { $0.percent == nil } : usage.bars }
    private var hasDetails: Bool { !(usage.week?.days.isEmpty ?? true) || !usage.projects.isEmpty }

    /// Only bad news: «хватит» says nothing a calm bar doesn't.
    private var warnings: [String] {
        var lines: [String] = []
        if case let .runsOutAt(date) = usage.forecast {
            lines.append(usage.service == .claude
                ? UsageText.forecast(usage.forecast) ?? ""
                : String(localized: "кончится \(date.formatted(.dateTime.weekday(.abbreviated).hour().minute())) при таком темпе"))
        }
        if case let .runsOutAt(date) = usage.week?.forecast {
            lines.append(String(localized: "неделя кончится \(date.formatted(.dateTime.weekday(.abbreviated).hour().minute())) при таком темпе"))
        }
        return lines.filter { !$0.isEmpty }
    }

    /// Where a service's tokens per project come from and what they count.
    private var projectsFootnote: String {
        switch usage.service {
        case .hub(.copilot): String(localized: "По записям Copilot CLI: токены запросов за неделю (ввод и вывод).")
        default: String(localized: "По записям Codex: токены бесед, обновлённых за неделю, — каждая беседа целиком.")
        }
    }
}

/// One colour while all is well: the accent below half, then orange and red as for every limit.
private func limitTint(_ percent: Double) -> Color {
    UsageLevel(percent) == .low ? .accentColor : UsageWindow.color(for: percent)
}

/// The main limit with bars: its name and the pace, a big number, the bar, when it resets.
private struct MainLimit: View {
    let window: LimitWindow
    let pace: Double?
    let now: Date

    private var percent: Double { window.percent ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.title)
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                if let pace {
                    Text(UsageText.pace(pace))
                        .scaledFont(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .help("Сколько процентов лимита уходит за час, по последним 30 минутам")
                }
            }
            Text(UsageText.percent(percent))
                .scaledFont(.title2, weight: .semibold)
                .monospacedDigit()
                .foregroundStyle(UsageLevel(percent) == .low ? Color.primary : UsageWindow.color(for: percent))
            ProgressView(value: min(max(percent, 0), 100), total: 100)
                .progressViewStyle(.linear)
                .tint(limitTint(percent))
            if let reset = UsageText.resetText(window.resetsAt, now: now) {
                Text(reset)
                    .scaledFont(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A limit beside the main one: name, number, bar, and its reset when it differs from what is already said.
private struct SmallLimit: View {
    let window: LimitWindow
    let now: Date

    private var percent: Double { window.percent ?? 0 }
    private var even: Double? { window.evenSpend(now: now) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(window.title)
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(UsageText.percent(percent))
                .scaledFont(.callout, weight: .semibold)
                .monospacedDigit()
                .foregroundStyle(UsageLevel(percent) == .low ? Color.primary : UsageWindow.color(for: percent))
            ProgressView(value: min(max(percent, 0), 100), total: 100)
                .progressViewStyle(.linear)
                .tint(limitTint(percent))
                .controlSize(.mini)
                // Where an even spend would be by now: the bar short of the mark is behind it, past it — ahead.
                .overlay(alignment: .leading) {
                    if let even {
                        GeometryReader { proxy in
                            Capsule()
                                .fill(Color.primary.opacity(0.55))
                                .frame(width: 1.5, height: 9)
                                .position(x: proxy.size.width * even / 100, y: proxy.size.height / 2)
                        }
                        .accessibilityHidden(true)
                    }
                }
                .help(even.map { String(localized: "Ровный расход к этому моменту: \(Int($0.rounded())) %") } ?? "")
            if window.runsOutAt == nil, let difference = EvenSpend.difference(percent: percent, expected: even) {
                Text(difference > 0 ? String(localized: "на \(difference) % быстрее ровного расхода") : String(localized: "на \(-difference) % медленнее ровного расхода"))
                    .scaledFont(.caption2)
                    .foregroundStyle(difference >= 10 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            if window.showsReset, let reset = UsageText.resetText(window.resetsAt, now: now, short: true) {
                Text(reset)
                    .scaledFont(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            if let runsOut = window.runsOutAt {
                Text("кончится \(runsOut.formatted(.dateTime.weekday(.abbreviated).hour().minute())) при таком темпе")
                    .scaledFont(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// «Подробнее» under a service: its week by day and its tokens per project, folded by default.
private struct ServiceDetails: View {
    @Environment(\.panelCalm) private var panelCalm
    let week: WeekUsage?
    let projects: [ProjectTokens]
    let footnote: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(panelCalm ? nil : .snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .flipsForRightToLeftLayoutDirection(true)
                    Text("Подробнее")
                    Spacer()
                }
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                if let week, !week.days.isEmpty { WeekStrip(week: week) }
                if !projects.isEmpty {
                    Text("Проекты за неделю")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                    let total = max(projects.reduce(0) { $0 + $1.tokens }, 1)
                    ForEach(projects.prefix(6)) { project in
                        HStack(spacing: 6) {
                            Text(project.name).lineLimit(1)
                            Spacer()
                            Text(TokenBreakdown.tokensText(project.tokens)).foregroundStyle(.secondary)
                            Text("\(Int((Double(project.tokens) / Double(total) * 100).rounded())) %")
                                .monospacedDigit()
                                .frame(width: 38, alignment: .trailing)
                        }
                        .scaledFont(.caption)
                        .help(project.path)
                    }
                    Text(footnote)
                        .scaledFont(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// A limit that isn't a ring: title, inline reset and percent on one line, then a thin bar; spend shows its amount.
private struct WindowRow: View {
    let window: LimitWindow
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(window.title)
                    .scaledFont(.caption)
                    .layoutPriority(1)
                if window.showsReset, let reset = UsageText.resetText(window.resetsAt, now: now) {
                    Text(verbatim: "· " + reset)
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
                if let detail = window.detail, !detail.isEmpty {
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
    @Environment(\.panelTextScale) private var scale
    let week: WeekUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Расход недели по дням, в процентах")
                .foregroundStyle(.secondary)
            let top = max(week.days.map(\.percent).max() ?? 0, 1)
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(week.days) { day in
                    VStack(spacing: 2) {
                        Spacer(minLength: 0)
                        if day.percent >= 0.5 {
                            Text(verbatim: "\(Int(day.percent.rounded()))")
                                .scaledFont(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        RoundedRectangle(cornerRadius: 3)
                            .fill(day.isToday ? Color.accentColor : Color.primary.opacity(0.35))
                            .frame(width: 16, height: max(2, 22 * day.percent / top))
                        // Two letters: one repeats in most languages (Russian П, В and С, English T and S).
                        Text(label(day))
                            .lineLimit(1)
                            .fixedSize()
                            .scaledFont(.caption2)
                            .foregroundStyle(day.isToday ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .help(String(localized: "\(day.date.formatted(.dateTime.weekday(.wide).day().month())): \(Int(day.percent.rounded())) % недельного лимита"))
                }
            }
            .frame(height: 56 * scale)
        }
        .scaledFont(.caption)
    }

    /// A week that resets in the middle of a day touches eight calendar days, so its first and last columns are the
    /// same weekday: those two say the date too («Пн 9» … «Пн 16»).
    private func label(_ day: WeekUsage.Day) -> String {
        let weekday = day.date.formatted(.dateTime.weekday(.short)).localizedCapitalized
        guard week.days.count > 7, day.id == week.days.first?.id || day.id == week.days.last?.id else { return weekday }
        return weekday + " " + day.date.formatted(.dateTime.day())
    }
}

/// A main limit (Claude's session or week, Codex's 5 h or week…): a ring in the level colour, the percentage, the
/// window and when it resets.
private struct LimitRing: View {
    let window: LimitWindow
    let caption: String?

    private var percent: Double { window.percent ?? 0 }
    private var color: Color { UsageWindow.color(for: percent) }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.12), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: min(max(percent, 0), 100) / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(UsageText.percent(percent))
                    .scaledFont(.title3, weight: .semibold)
                    .monospacedDigit()
                    .foregroundStyle(color)
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
        .help([window.title, UsageText.percent(percent), caption].compactMap { $0 }.joined(separator: " · "))
    }
}

struct QueuedRow: View {
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
    static func color(for value: Double) -> Color { UsageLevel(value).color }
}
