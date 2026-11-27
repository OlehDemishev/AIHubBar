import AppKit
import SwiftUI

/// «Экономика AI»: the models behind an API side by side — list prices, what one task would cost with each, and what
/// the person's own month of Claude Code tokens would cost. The prices come from models.dev (`ModelPriceStore`).
struct EconomicsWindow: View {
    @Environment(ModelPriceStore.self) private var prices
    @Environment(UsageStore.self) private var usage
    @State private var size = TaskSize.task
    @State private var provider = ""
    @State private var search = ""
    /// Off shows everything the providers still sell, a few years back.
    @State private var recentOnly = true
    @State private var sortOrder = [KeyPathComparator(\ModelPriceRow.taskCost)]

    private var month: TaskTokens { TaskTokens.of(UsageDays.recent(usage.days, count: 30)) }

    private var rows: [ModelPriceRow] {
        ModelPriceRow.rows(prices.list?.models ?? [], task: size.tokens, month: month,
                           provider: provider.isEmpty ? nil : provider, search: search,
                           since: recentOnly ? ModelPriceRow.yearAgo(from: .now) : nil)
            .sorted(using: sortOrder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            controls
            Toggle("Только за последний год", isOn: $recentOnly)
                .help("Скрыть модели, выпущенные больше года назад")
            Text(sizeNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if prices.list == nil {
                empty
            } else {
                table
                footer
            }
        }
        .padding(20)
        .frame(minWidth: 880, minHeight: 420)
        .task { await prices.refreshIfStale() }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("Размер задачи", selection: $size) {
                ForEach(TaskSize.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Picker("Провайдер", selection: $provider) {
                Text("Все провайдеры").tag("")
                Divider()
                ForEach(ModelPriceParser.sources, id: \.id) { Text(verbatim: $0.provider.title).tag($0.provider.rawValue) }
            }
            .labelsHidden()
            .fixedSize()
            TextField("Поиск модели", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)
            Spacer(minLength: 0)
            if prices.isLoading { ProgressView().controlSize(.small) }
            Button("Обновить цены") { Task { await prices.refresh() } }
                .disabled(prices.isLoading)
                .fixedSize()
        }
    }

    /// The tokens behind the chosen size, so the sum in the table can be checked by hand.
    private var sizeNote: String {
        let tokens = size.tokens
        let input = TokenBreakdown.tokensText(tokens.input)
        let output = TokenBreakdown.tokensText(tokens.output)
        guard tokens.cacheRead > 0 else {
            return String(localized: "«\(size.title)» — это \(input) токенов ввода и \(output) вывода. Оценка, а не замер.")
        }
        let read = TokenBreakdown.tokensText(tokens.cacheRead)
        let write = TokenBreakdown.tokensText(tokens.cacheWrite)
        return String(localized: "«\(size.title)» — это \(input) токенов нового ввода, \(read) чтения кэша, \(write) записи кэша и \(output) вывода. Оценка, а не замер: агент перечитывает контекст на каждом шаге.")
    }

    @ViewBuilder private var empty: some View {
        if prices.isLoading {
            ContentUnavailableView("Загружаю цены…", systemImage: "arrow.down.circle")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "Цены не загружены", systemImage: "wifi.exclamationmark",
                description: Text(verbatim: prices.failure ?? String(localized: "Проверьте соединение и нажмите «Обновить цены»."))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var table: some View {
        Table(rows, sortOrder: $sortOrder) {
            TableColumn("Модель", value: \.name) { row in
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: row.price.name)
                    Text(verbatim: row.price.model).font(.caption).monospaced().foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .help(row.price.model)
            }
            .width(min: 150, ideal: 180)
            TableColumn("Провайдер", value: \.providerTitle) { row in
                Text(verbatim: row.providerTitle)
            }
            .width(min: 90, ideal: 100, max: 150)
            TableColumn("Ввод, $/млн", value: \.input) { row in
                Text(verbatim: ModelPriceRow.perMillion(row.input)).monospacedDigit()
            }
            .width(min: 84, ideal: 84, max: 110)
            TableColumn("Вывод, $/млн", value: \.output) { row in
                Text(verbatim: ModelPriceRow.perMillion(row.output)).monospacedDigit()
            }
            .width(min: 88, ideal: 88, max: 110)
            TableColumn("Контекст", value: \.context) { row in
                Text(verbatim: ModelPriceRow.contextText(row.context)).monospacedDigit()
            }
            .width(min: 64, ideal: 64, max: 96)
            TableColumn("Цена задачи", value: \.taskCost) { row in
                Text(verbatim: ModelPriceRow.money(row.taskCost)).monospacedDigit().fontWeight(.semibold)
            }
            .width(min: 96, ideal: 96, max: 124)
            TableColumn("Ваши 30 дней", value: \.monthCost) { row in
                Text(verbatim: row.monthCost > 0 ? ModelPriceRow.money(row.monthCost) : "—").monospacedDigit()
            }
            .width(min: 108, ideal: 108, max: 130)
        }
        .overlay {
            if rows.isEmpty { ContentUnavailableView("Ничего не найдено", systemImage: "magnifyingglass") }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let failure = prices.failure {
                Text(verbatim: failure).font(.caption).foregroundStyle(.orange)
            }
            if let list = prices.list {
                let date = list.fetchedAt.formatted(date: .abbreviated, time: .shortened)
                Text("Цены — из открытого списка models.dev, загружены \(date). Это прейскурант прямого доступа к API провайдера: скидки, пакетный режим и наценка за длинный контекст не учтены.")
            }
            Text("«Ваши 30 дней» — ваши токены Claude Code за последние 30 дней по ценам каждой модели: сколько стоил бы тот же объём работы.")
            Link(destination: ModelPriceParser.sourcePage) { Text(verbatim: "models.dev") }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}
