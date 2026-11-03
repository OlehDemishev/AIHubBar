import AppKit
import SwiftUI

// «Лимиты AI» (docs/specs/SPEC-refactor.md §3): what the module is, its Settings sections and its «Панель сейчас» line.

extension ModuleDefinition {
    static let limits = ModuleDefinition(
        kind: .limits,
        group: .ai,
        symbol: "gauge.with.dots.needle.33percent",
        title: String(localized: "Лимиты AI"),
        summary: String(localized: "Сессия и неделя подписки Claude, прогноз, расход по проектам и по API."),
        tagline: String(localized: "Сессия, неделя, прогноз, другие AI"),
        isBuiltIn: true,
        places: ModulePlace.allCases,
        menuBarKinds: [.session, .week, .modelWeek, .resetCountdown, .forecast, .otherAI],
        primaryMenuBarKinds: [.session, .week],
        notifications: [.limits],
        island: IslandSlot(ears: [.sessionLimit, .weekLimit, .otherAI], left: true),
        telegram: .limitAlerts,
        keywords: [String(localized: "Уведомлять на, %"), String(localized: "Ставить фоновые задачи на паузу"),
            String(localized: "Сводка за неделю в Telegram"), String(localized: "Продлевать вход Claude Code сам"),
            String(localized: "Другие AI")]
    )
}

extension ModuleUI {
    static let limits = ModuleUI(
        settings: {
            AnyView(Group {
                LimitSection()
                HubSection()
            })
        },
        sketch: { AnyView(LimitsSketch()) }
    )
}

/// «Панель сейчас»: the session and week bars, else its tagline.
private struct LimitsSketch: View {
    @Environment(UsageStore.self) private var usage

    var body: some View {
        if let session = usage.snapshot?.session?.utilization {
            HStack(spacing: 6) {
                MiniBar(value: session)
                if let week = usage.snapshot?.week?.utilization { MiniBar(value: week) }
            }
        } else {
            SketchLine(ModuleKind.limits.tagline)
        }
    }
}

struct LimitSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(UsageStore.self) private var usage
    @Environment(WeeklySummarySender.self) private var weeklySummary
    @State private var thresholdsText = ""
    @State private var summarySent: Bool?

    var body: some View {
        @Bindable var settings = settings
        Section {
            IconRow("Уведомлять на, %", systemImage: "bell.badge") {
                // No title: in a Form a titled field also shows its title as a label next to it.
                TextField("", text: $thresholdsText, prompt: Text(verbatim: "50, 80, 95"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                    .onSubmit(applyThresholds)
            }
            Toggle("Уведомления о лимитах ещё и в Telegram", systemImage: "paperplane", isOn: $settings.limitAlertsToTelegram)
            VStack(alignment: .leading, spacing: 2) {
                Picker("Ставить фоновые задачи на паузу", systemImage: "pause.circle", selection: $settings.runGuardPercent) {
                    ForEach(RunGuard.thresholds, id: \.self) { value in
                        Text(value == 0 ? String(localized: "никогда") : String(localized: "с \(value) %")).tag(value)
                    }
                }
                Text("Когда сессия или неделя дошла до порога, фоновые задачи замирают там, где были, а запланированные ждут. После сброса лимита работа продолжается сама. Так задача не обрывается на полпути из-за лимита.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Сводка за неделю в Telegram", systemImage: "calendar.badge.clock", isOn: $settings.weeklySummary)
                if settings.weeklySummary {
                    HStack {
                        Picker("День", selection: $settings.weeklySummaryWeekday) {
                            ForEach(1...7, id: \.self) { day in
                                Text(Calendar.current.standaloneWeekdaySymbols[day - 1].capitalized).tag(day)
                            }
                        }
                        Picker("Час", selection: $settings.weeklySummaryHour) {
                            ForEach(6...23, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
                        }
                        .frame(width: 140)
                    }
                }
                HStack {
                    Button("Отправить сейчас") {
                        Task { summarySent = await weeklySummary.send() }
                    }
                    .controlSize(.small)
                    if let summarySent {
                        Text(summarySent ? String(localized: "Отправлено") : String(localized: "Не отправилось: Telegram не настроен (Основные → Telegram) или нет связи"))
                            .font(.caption)
                            .foregroundStyle(summarySent ? Color.secondary : Color.orange)
                    }
                }
                Text("Своим сообщением, через бота ежедневного отчёта: расход недели по проектам, самые тяжёлые сессии, сколько раз упирался в лимит, итоги фоновых задач.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Продлевать вход Claude Code сам", systemImage: "key", isOn: $settings.renewClaudeLogin)
                Text("Когда вход истёк (claude давно не запускался, а работа идёт в приложении Claude), AI Hub Bar отправляет через claude запрос из одного слова — самая маленькая модель, без инструментов, не чаще раза в час. Вход продлевается примерно на 8 часов.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = usage.error {
                Text(error).font(.callout).foregroundStyle(.orange)
            }
        } header: {
            Text("Лимиты подписки")
        } footer: {
            Footnote(text: String(localized: "Данные — с того же адреса, что использует Claude Code (токен читается из связки ключей «Claude Code-credentials» и нигде не сохраняется). Уведомление — один раз на окно сессии/недели при пересечении порога и когда лимит восстановился. Значения пишутся в ~/Library/Application Support/ClaudePult/usage.json. Что показывать в строке меню — во вкладке «Строка меню»."))
        }
        .onAppear { thresholdsText = settings.limitThresholds.map(String.init).joined(separator: ", ") }
        .onDisappear(perform: applyThresholds)
    }

    /// «50, 80, 95» → [50, 80, 95]; invalid input keeps the previous thresholds.
    private func applyThresholds() {
        let values = SettingsParsing.thresholds(thresholdsText)
        if !values.isEmpty { settings.limitThresholds = values }
        thresholdsText = settings.limitThresholds.map(String.init).joined(separator: ", ")
    }
}
