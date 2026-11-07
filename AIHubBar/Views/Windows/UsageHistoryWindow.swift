import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

/// «История расхода»: Claude Code tokens by day for the last weeks, with a cost estimate at the person's own price
/// (prices are not shipped: DECISIONS, models by API).
struct UsageHistoryWindow: View {
    @Environment(UsageStore.self) private var usage
    @Environment(AppSettings.self) private var settings
    @Environment(\.openSettingsPage) private var openSettings
    @State private var period = 30
    @State private var exportError: String?

    private var days: [UsageDay] { UsageDays.recent(usage.days, count: period) }
    private var price: APIPrice? { settings.aiServices.prices[APIProvider.anthropic.rawValue] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker("Период", selection: $period) {
                    Text("7 дней").tag(7)
                    Text("30 дней").tag(30)
                    Text("90 дней").tag(90)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Button("Экспорт CSV…", action: export)
                    .disabled(usage.days.isEmpty)
            }
            if days.allSatisfy({ $0.tokens == 0 }) {
                ContentUnavailableView(
                    usage.isBackfilling ? "Считаю по журналам Claude Code…" : "За этот период расхода нет",
                    systemImage: "chart.bar",
                    description: Text("История собирается из журналов Claude Code на этом Маке.")
                )
            } else {
                summary
                chart
            }
            Text("Оценка по журналам Claude Code на этом Маке: токены без чтения кэша. Лимиты считает сама Anthropic, и чаты на claude.ai сюда не попадают.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let exportError {
                Text(exportError).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 420)
    }

    private var summary: some View {
        let used = days.filter { $0.tokens > 0 }
        let total = used.map(\.tokens).reduce(0, +)
        let busiest = used.max { $0.tokens < $1.tokens }
        return HStack(alignment: .top, spacing: 28) {
            figure("Всего токенов", TokenBreakdown.tokensText(total))
            figure("В среднем за рабочий день", TokenBreakdown.tokensText(used.isEmpty ? 0 : total / used.count))
            if let busiest {
                figure("Самый активный день", busiest.date.formatted(.dateTime.day().month(.abbreviated)))
            }
            if let price {
                figure("По цене API, примерно", used.map { $0.cost(price) }.reduce(0, +).formatted(.currency(code: "USD")))
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Стоимость").font(.caption).foregroundStyle(.secondary)
                    Button("Указать цену…") { openSettings(.service(.other)) }
                        .buttonStyle(.link)
                        .help("Цена токенов Anthropic: без неё стоимость не считается")
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func figure(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(verbatim: value).font(.title3.weight(.semibold)).monospacedDigit()
        }
    }

    private var chart: some View {
        Chart(days) { day in
            BarMark(x: .value("День", day.date, unit: .day), y: .value("Токены", day.tokens))
                .foregroundStyle(Color.accentColor)
                .cornerRadius(2)
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel { Text(verbatim: value.as(Int.self).map(TokenBreakdown.tokensText) ?? "") }
            }
        }
        .frame(minHeight: 220)
        .accessibilityLabel("График расхода токенов по дням")
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "AI Hub Bar usage.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try UsageDays.csv(days).write(to: url, atomically: true, encoding: .utf8)
            exportError = nil
        } catch {
            AppLog.error("Usage export: \(error.localizedDescription)")
            exportError = error.localizedDescription
        }
    }
}
