import AppKit
import SwiftUI

// The Skills Catalog in the panel (docs/specs/SPEC-skills.md): the «Скиллы» block on the main panel, and the
// «Скиллы» section that the header's button opens in the same panel — a list, filters and a skill's card.
// Everything a skill says about itself — its name, description, files, the lines the scanner quotes — is shown as
// plain text, never as Markdown or a link.

/// A section of the panel that takes the place of the blocks.
enum PanelSection: Equatable {
    /// The Skills Catalog; with a skill's id, its card.
    case skills(Int?)
}

// MARK: - Words

extension SkillVerdict {
    var title: String {
        switch self {
        case .safe: String(localized: "Безопасно")
        case .review: String(localized: "Проверить")
        case .dangerous: String(localized: "Опасно")
        }
    }

    var hint: String {
        switch self {
        case .safe: String(localized: "Только инструкции: без скриптов и обращений в сеть")
        case .review: String(localized: "Есть скрипты, обращения в сеть или настройки. Прочитайте находки, прежде чем полагаться на скилл")
        case .dangerous: String(localized: "Похоже на атаку: отправка данных наружу, скрытый код или инструкции, закрепление в системе")
        }
    }

    var color: Color {
        switch self {
        case .safe: .green
        case .review: .orange
        case .dangerous: .red
        }
    }
}

extension SkillSeverity {
    var title: String {
        switch self {
        case .critical: String(localized: "Критично")
        case .high: String(localized: "Серьёзно")
        case .medium: String(localized: "Средне")
        case .low: String(localized: "Слабо")
        case .info: String(localized: "Заметка")
        }
    }

    var color: Color {
        switch self {
        case .critical: .red
        case .high: .orange
        case .medium: .yellow
        case .low, .info: .secondary
        }
    }
}

extension SkillAgent {
    var title: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .gemini: "Gemini CLI"
        }
    }
}

extension SkillCategory {
    var title: String {
        switch self {
        case .scripts: String(localized: "Скрипты и файлы")
        case .network: String(localized: "Сеть")
        case .execution: String(localized: "Запуск кода")
        case .secrets: String(localized: "Ключи и пароли")
        case .system: String(localized: "Изменения в системе")
        case .dependencies: String(localized: "Пакеты")
        case .obfuscation: String(localized: "Скрытый код")
        case .injection: String(localized: "Инструкции против вас")
        case .plugin: String(localized: "Hooks, MCP и разрешения")
        case .metadata: String(localized: "О скилле")
        }
    }
}

extension SkillAssessment.Capability {
    var title: String {
        switch self {
        case .network: String(localized: "Сеть")
        case .sendsData: String(localized: "Отправляет данные")
        case .runsCode: String(localized: "Запускает код")
        case .readsSecrets: String(localized: "Читает ключи")
        case .changesSystem: String(localized: "Меняет систему")
        case .changesAgent: String(localized: "Меняет агента")
        case .installsPackages: String(localized: "Ставит пакеты")
        case .hooks: String(localized: "Hooks")
        case .mcp: String(localized: "MCP")
        case .hidden: String(localized: "Скрытое")
        case .againstUser: String(localized: "Против вас")
        }
    }

    var symbol: String {
        switch self {
        case .network: "network"
        case .sendsData: "arrow.up.forward.app"
        case .runsCode: "terminal"
        case .readsSecrets: "key"
        case .changesSystem: "gearshape.2"
        case .changesAgent: "lock.open"
        case .installsPackages: "shippingbox"
        case .hooks: "bolt"
        case .mcp: "point.3.connected.trianglepath.dotted"
        case .hidden: "eye.slash"
        case .againstUser: "exclamationmark.bubble"
        }
    }
}

extension SkillAssessment.Advice {
    var text: String {
        switch self {
        case .doNotInstall: String(localized: "Не устанавливайте: это похоже на атаку, и никакая правка не делает такой скилл безопасным.")
        case .reviewScriptsFirst: String(localized: "Прочитайте скрипты, прежде чем агент их запустит.")
        case .downloadThenReview: String(localized: "Не запускайте скачанное сразу: сначала сохраните файл и прочитайте его.")
        case .pinVersion: String(localized: "Закрепите версию MCP-сервера, чтобы при каждом запуске не скачивалось новое.")
        case .pinPackages: String(localized: "Закрепите версии пакетов или проверьте их отдельно.")
        case .checkPackageName: String(localized: "Проверьте название пакета: оно похоже на опечатку в популярном.")
        case .narrowTools: String(localized: "Сузьте разрешённые инструменты: не давайте скиллу любые команды оболочки.")
        case .noPermissionChanges: String(localized: "Скиллу не нужно менять разрешения агента — уберите эти настройки.")
        case .useHTTPS: String(localized: "Используйте адрес с именем и https вместо голого IP или http.")
        case .shipReadableSource: String(localized: "Нужен читаемый исходный код вместо сжатого, закодированного или скомпилированного.")
        case .scopeKeys: String(localized: "Убедитесь, что ключ уходит только своему сервису.")
        case .noLinks: String(localized: "Ссылки внутри скилла не нужны: их не копируют и не открывают.")
        case .readHooks: String(localized: "Прочитайте, что запускают hooks: они срабатывают сами, без вопросов.")
        case .addLicense: String(localized: "Нет лицензии: неясно, на каких условиях скилл можно использовать.")
        case .fixFrontmatter: String(localized: "SKILL.md не по стандарту: некоторые агенты такой скилл не загрузят.")
        }
    }
}

// MARK: - Small parts

struct SkillVerdictBadge: View {
    let verdict: SkillVerdict

    var body: some View {
        Text(verdict.title)
            .scaledFont(.caption2, weight: .semibold)
            .foregroundStyle(verdict.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(verdict.color.opacity(0.14)))
            .fixedSize()
            .help(verdict.hint)
    }
}

/// How many findings of each severity, as small coloured numbers.
private struct SkillCounts: View {
    let counts: [Int]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(zip([SkillSeverity.critical, .high, .medium, .low], counts)), id: \.0) { severity, count in
                if count > 0 {
                    Text(verbatim: "\(count)")
                        .scaledFont(.caption2, weight: .semibold)
                        .monospacedDigit()
                        .foregroundStyle(severity.color)
                        .padding(.horizontal, 5)
                        .background(Capsule().fill(severity.color.opacity(0.14)))
                        .help(severity.title)
                }
            }
        }
    }
}

// MARK: - The block on the main panel

/// «Скиллы»: what needs attention first, then which skills the agents used this week.
struct SkillsBlockView: View {
    @Environment(SkillStore.self) private var skills
    @AppStorage(StorageKey.collapsedBlocks) private var collapsedRaw = ""
    let openSection: (Int?) -> Void

    var body: some View {
        let summary = skills.summary
        let collapsed = PanelBlock.collapsed(in: collapsedRaw).contains(.skills)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                BlockTitle(block: .skills, title: "Скиллы")
                Spacer(minLength: 4)
                if skills.isRefreshing { ProgressView().controlSize(.mini) }
                ForEach(SkillVerdict.allCases.reversed(), id: \.self) { verdict in
                    if let count = summary.byVerdict[verdict], count > 0 {
                        Text(verbatim: "\(count)")
                            .scaledFont(.caption2, weight: .semibold)
                            .monospacedDigit()
                            .foregroundStyle(verdict.color)
                            .padding(.horizontal, 6)
                            .background(Capsule().fill(verdict.color.opacity(0.14)))
                            .help(verdict.title)
                    }
                }
            }
            // An alert stays in sight even when the block is folded.
            ForEach(summary.dangerous.prefix(3)) { alert in
                Button { openSection(alert.row.id) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(verbatim: alert.row.name).fontWeight(.semibold)
                        Text(alert.rule.map(SkillRuleText.title) ?? SkillVerdict.dangerous.hint).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .scaledFont(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.red.opacity(0.1)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "Открыть скилл"))
            }
            if !collapsed {
                if summary.total == 0 {
                    Text(skills.lastUpdated == nil ? "Ищу скиллы агентов…" : "Скиллов для Claude Code, Codex, Cursor и Gemini CLI не найдено.")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    if !summary.mostUsed.isEmpty {
                        Text("Используются за 7 дней")
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(summary.mostUsed) { used in
                            Button { openSection(used.skillID) } label: {
                                HStack(spacing: 6) {
                                    if let verdict = used.verdict { SkillVerdictBadge(verdict: verdict) }
                                    Text(verbatim: used.name).lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text(Self.usedLine(used))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .scaledFont(.caption)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Button { openSection(nil) } label: {
                        HStack(spacing: 4) {
                            Text(summary.unused > 0 ? String(localized: "Не использовались 30 дней: \(summary.unused)") : String(localized: "Все скиллы"))
                            Image(systemName: "chevron.right").scaledFont(.caption2, weight: .semibold)
                        }
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    static func usedLine(_ used: SkillCatalog.Used) -> String {
        let agents = used.agents.map(\.title).joined(separator: ", ")
        return String(localized: "запусков: \(used.count) · \(agents)")
    }
}

// MARK: - The section

/// The «Скиллы» section in place of the blocks: a search, filters and the list; a skill's card above it all.
struct SkillsSectionView: View {
    @Environment(SkillStore.self) private var skills
    @Binding var section: PanelSection?
    @State private var filters = SkillCatalog.Filters()
    @State private var result = SkillCatalog.Result()
    @State private var card: SkillCatalog.Card?
    @State private var facets = SkillCatalog.Facets()
    @State private var saved: [SkillCatalog.SavedFilter] = []
    @State private var showsFilters = false
    /// The name being typed for «Сохранить фильтр»; nil while the field is hidden.
    @State private var savingName: String?

    private var chosen: Int? {
        if case .skills(let id) = section { return id }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let chosen {
                if let card, card.row.id == chosen {
                    SkillCardView(card: card)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            } else {
                filtersBar
                list
            }
            Text("Проверка снижает риск, но не гарантирует безопасность. При проверке ничего из скилла не запускается.")
                .scaledFont(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .task(id: filters) { result = await skills.search(filters) }
        .task(id: chosen) {
            card = nil
            if let chosen { card = await skills.card(chosen) }
        }
        .task(id: skills.lastUpdated) {
            facets = await skills.facets()
            saved = await skills.savedFilters()
        }
        .onChange(of: skills.lastUpdated) { reload() }
        .onChange(of: skills.marksVersion) { reload() }
    }

    private func reload() {
        Task {
            result = await skills.search(filters)
            saved = await skills.savedFilters()
            if let chosen { card = await skills.card(chosen) }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button {
                section = chosen == nil ? nil : .skills(nil)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").scaledFont(.caption, weight: .semibold)
                    Text(chosen == nil ? "Назад" : "Все скиллы")
                }
                .scaledFont(.callout)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            Spacer(minLength: 4)
            Text("Скиллы").scaledFont(.callout, weight: .semibold)
            Spacer(minLength: 4)
            Button {
                Task { await skills.refresh() }
            } label: {
                if skills.isRefreshing { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
            }
            .buttonStyle(.borderless)
            .frame(width: 18, height: 18)
            .disabled(skills.isRefreshing)
            .help(String(localized: "Проверить заново"))
        }
    }

    private var filtersBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Поиск по названию, описанию и заметке", text: $filters.query)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 4) {
                verdictChip(nil, title: String(localized: "Все \(result.total)"))
                ForEach(SkillVerdict.allCases.reversed(), id: \.self) { verdict in
                    verdictChip(verdict, title: "\(verdict.title) \(result.byVerdict[verdict] ?? 0)")
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                SkillChip(title: String(localized: "Избранное"), symbol: filters.favoritesOnly ? "star.fill" : "star", isOn: filters.favoritesOnly) {
                    filters.favoritesOnly.toggle()
                }
                Menu {
                    Picker("Порядок", selection: $filters.sort) {
                        ForEach(SkillCatalog.Filters.Sort.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(filters.sort.title, systemImage: "arrow.up.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .scaledFont(.caption)
                .fixedSize()
                .help(String(localized: "Порядок"))
                Spacer(minLength: 4)
                savedMenu
                Button { withAnimation(.snappy(duration: 0.2)) { showsFilters.toggle() } } label: {
                    HStack(spacing: 3) {
                        Image(systemName: filters.activeCount > 0 ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        Text("Фильтры")
                        if filters.activeCount > 0 { Text(verbatim: "\(filters.activeCount)").monospacedDigit().fontWeight(.semibold) }
                    }
                    .scaledFont(.caption)
                    .foregroundStyle(filters.activeCount > 0 || showsFilters ? Color.accentColor : Color.primary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if let name = savingName {
                HStack(spacing: 6) {
                    TextField("Название фильтра", text: Binding(get: { name }, set: { savingName = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveCurrent)
                    Button("Сохранить", action: saveCurrent).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Отмена") { savingName = nil }
                }
                .scaledFont(.caption)
            }
            if showsFilters { SkillFilterPanel(filters: $filters, facets: facets) }
        }
    }

    private var savedMenu: some View {
        Menu {
            if saved.isEmpty {
                Text("Сохранённых фильтров пока нет")
            } else {
                ForEach(saved) { item in
                    Button { filters = item.filters } label: { Text(verbatim: item.name) }
                }
            }
            Divider()
            Button("Сохранить текущий фильтр…") { savingName = "" }
            if !saved.isEmpty {
                Menu("Удалить") {
                    ForEach(saved) { item in
                        Button { Task { await skills.deleteFilter(item.id) } } label: { Text(verbatim: item.name) }
                    }
                }
            }
        } label: {
            Image(systemName: "bookmark")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(String(localized: "Сохранённые фильтры"))
    }

    private func saveCurrent() {
        guard let name = savingName?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return }
        savingName = nil
        let current = filters
        Task { await skills.saveFilter(name, current) }
    }

    private func verdictChip(_ verdict: SkillVerdict?, title: String) -> some View {
        let on = filters.verdict == verdict
        return Button { filters.verdict = verdict } label: {
            Text(verbatim: title)
                .scaledFont(.caption2, weight: on ? .semibold : .regular)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(on ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var list: some View {
        if result.rows.isEmpty {
            Text(result.total == 0 && filters == SkillCatalog.Filters() ? "Скиллов для Claude Code, Codex, Cursor и Gemini CLI не найдено." : "Ничего не подходит.")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(result.rows) { row in
                    SkillRowView(row: row, showsUses: filters.sort == .mostUsed) { section = .skills(row.id) }
                }
            }
        }
    }
}

private struct SkillRowView: View {
    @Environment(SkillStore.self) private var skills
    let row: SkillCatalog.Row
    var showsUses = false
    let open: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        SkillVerdictBadge(verdict: row.verdict)
                        Text(verbatim: row.name).scaledFont(.callout, weight: .medium).lineLimit(1)
                        if row.kind == "plugin" { Text("плагин").scaledFont(.caption2).foregroundStyle(.secondary) }
                        if row.isOff { Text("выключен").scaledFont(.caption2).foregroundStyle(.orange) }
                        if !row.note.isEmpty {
                            Image(systemName: "note.text").scaledFont(.caption2).foregroundStyle(.secondary).help(Text(verbatim: row.note))
                        }
                        Spacer(minLength: 4)
                        if showsUses, row.uses > 0 {
                            Text("запусков: \(row.uses)").scaledFont(.caption2).foregroundStyle(.secondary)
                        }
                        SkillCounts(counts: row.counts)
                    }
                    if !row.description.isEmpty {
                        Text(verbatim: row.description)
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            SkillStarButton(id: row.id, isFavorite: row.isFavorite)
                // Faint until the row is hovered, never hidden: VoiceOver and the keyboard must reach it.
                .opacity(row.isFavorite || hovered ? 1 : 0.35)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovered ? Color.primary.opacity(0.06) : .clear))
        .onHover { hovered = $0 }
    }
}

/// The star that adds a skill to the favourites or takes it out.
private struct SkillStarButton: View {
    @Environment(SkillStore.self) private var skills
    let id: Int
    let isFavorite: Bool

    var body: some View {
        Button { Task { await skills.setFavorite(id, !isFavorite) } } label: {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .foregroundStyle(isFavorite ? Color.yellow : Color.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isFavorite ? String(localized: "Убрать из избранного") : String(localized: "В избранное"))
    }
}

/// A small switch in the filters: a word with an optional icon, highlighted while on.
private struct SkillChip: View {
    let title: String
    var symbol: String?
    var isOn: Bool
    /// Shown struck through in red: «не может».
    var isExcluded = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let symbol { Image(systemName: symbol) }
                Text(verbatim: title).strikethrough(isExcluded)
            }
            .scaledFont(.caption2, weight: isOn || isExcluded ? .semibold : .regular)
            .foregroundStyle(isExcluded ? Color.red : isOn ? Color.accentColor : Color.primary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(isExcluded ? Color.red.opacity(0.12) : isOn ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Every filter the catalog knows, in groups of chips.
private struct SkillFilterPanel: View {
    @Binding var filters: SkillCatalog.Filters
    let facets: SkillCatalog.Facets

    /// The risk bands offered, matching the verdict thresholds' feel: low, middling, high.
    private static let riskBands: [(Int, Int)] = [(0, 100), (0, 19), (20, 59), (60, 100)]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            group("Риск") {
                ForEach(Array(Self.riskBands.enumerated()), id: \.offset) { _, band in
                    SkillChip(title: Self.riskTitle(band), isOn: filters.minRisk == band.0 && filters.maxRisk == band.1) {
                        filters.minRisk = band.0
                        filters.maxRisk = band.1
                    }
                }
            }
            group("Агент") {
                ForEach(SkillAgent.allCases, id: \.self) { agent in
                    SkillChip(title: agent.title, isOn: filters.agents.contains(agent)) { filters.agents.toggle(agent) }
                }
            }
            if facets.scopes.count > 1 {
                group("Где установлен") {
                    ForEach(facets.scopes, id: \.self) { scope in
                        SkillChip(title: Self.scopeTitle(scope), isOn: filters.scopes.contains(scope)) { filters.scopes.toggle(scope) }
                    }
                }
            }
            group("Тип и состояние") {
                SkillChip(title: String(localized: "Скиллы"), isOn: filters.kind == "skill") { filters.kind = filters.kind == "skill" ? nil : "skill" }
                SkillChip(title: String(localized: "Плагины"), isOn: filters.kind == "plugin") { filters.kind = filters.kind == "plugin" ? nil : "plugin" }
                SkillChip(title: String(localized: "Включены"), isOn: filters.state == .on) { filters.state = filters.state == .on ? .any : .on }
                SkillChip(title: String(localized: "Выключены"), isOn: filters.state == .off) { filters.state = filters.state == .off ? .any : .off }
                SkillChip(title: String(localized: "Без скриптов"), isOn: filters.noScripts) { filters.noScripts.toggle() }
                SkillChip(title: String(localized: "С заметкой"), symbol: "note.text", isOn: filters.withNote) { filters.withNote.toggle() }
            }
            group("Использование") {
                SkillChip(title: String(localized: "Запускались за 30 дней"), isOn: filters.usage == .used) { filters.usage = filters.usage == .used ? .any : .used }
                SkillChip(title: String(localized: "Не запускались 30 дней"), isOn: filters.usage == .unused) { filters.usage = filters.usage == .unused ? .any : .unused }
                SkillChip(title: String(localized: "Новые за 7 дней"), isOn: filters.newWithinDays == 7) { filters.newWithinDays = filters.newWithinDays == 7 ? nil : 7 }
                SkillChip(title: String(localized: "Новые за 30 дней"), isOn: filters.newWithinDays == 30) { filters.newWithinDays = filters.newWithinDays == 30 ? nil : 30 }
            }
            group("Находки") {
                ForEach(SkillCategory.allCases.filter { $0 != .metadata }, id: \.self) { category in
                    SkillChip(title: category.title, isOn: filters.findings.contains(category)) { filters.findings.toggle(category) }
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                group("Что может скилл") {
                    ForEach(SkillAssessment.Capability.allCases, id: \.self) { capability in
                        SkillChip(title: capability.title, symbol: capability.symbol, isOn: filters.can.contains(capability), isExcluded: filters.cannot.contains(capability)) {
                            // Off → can → can't → off.
                            if filters.can.contains(capability) {
                                filters.can.remove(capability)
                                filters.cannot.insert(capability)
                            } else if filters.cannot.contains(capability) {
                                filters.cannot.remove(capability)
                            } else {
                                filters.can.insert(capability)
                            }
                        }
                    }
                }
                Text("Нажмите раз — может, ещё раз — не может.").scaledFont(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Menu {
                    Picker("Лицензия", selection: $filters.license) {
                        Text("Любая лицензия").tag(String?.none)
                        if facets.hasUnlicensed { Text("Без лицензии").tag(String?.some("")) }
                        ForEach(facets.licenses, id: \.self) { Text(verbatim: $0).tag(String?.some($0)) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text(Self.licenseTitle(filters.license))
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .scaledFont(.caption)
                .fixedSize()
                if !facets.authors.isEmpty {
                    Menu {
                        Picker("Автор", selection: $filters.author) {
                            Text("Любой автор").tag(String?.none)
                            ForEach(facets.authors, id: \.self) { Text(verbatim: $0).tag(String?.some($0)) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Text(filters.author.map { String(localized: "Автор: \($0)") } ?? String(localized: "Любой автор"))
                    }
                    .menuStyle(.borderlessButton)
                    .controlSize(.small)
                    .scaledFont(.caption)
                    .fixedSize()
                }
                Spacer(minLength: 4)
                if filters.activeCount > 0 {
                    Button("Сбросить") {
                        var plain = SkillCatalog.Filters()
                        plain.query = filters.query
                        plain.verdict = filters.verdict
                        plain.sort = filters.sort
                        plain.favoritesOnly = filters.favoritesOnly
                        filters = plain
                    }
                    .buttonStyle(.borderless)
                    .scaledFont(.caption)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    private func group(_ title: LocalizedStringKey, @ViewBuilder _ chips: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).scaledFont(.caption2, weight: .semibold).foregroundStyle(.secondary)
            FlowRow(spacing: 4) { chips() }
        }
    }

    static func riskTitle(_ band: (Int, Int)) -> String {
        switch band {
        case (0, 100): String(localized: "Любой")
        case (0, _): String(localized: "до \(band.1 + 1)")
        case (_, 100): String(localized: "от \(band.0)")
        default: String(localized: "\(band.0)–\(band.1)")
        }
    }

    static func scopeTitle(_ scope: String) -> String {
        scope == "project" ? String(localized: "в проекте") : SkillCardView.scope(scope)
    }

    static func licenseTitle(_ license: String?) -> String {
        switch license {
        case nil: String(localized: "Любая лицензия")
        case ""?: String(localized: "Без лицензии")
        case let name?: String(localized: "Лицензия: \(name)")
        }
    }
}

extension SkillCatalog.Filters.Sort {
    var title: String {
        switch self {
        case .risk: String(localized: "Сначала опасные")
        case .name: String(localized: "По названию")
        case .mostUsed: String(localized: "Чаще запускаемые")
        case .newest: String(localized: "Новые и изменённые")
        }
    }
}

extension Set {
    mutating func toggle(_ member: Element) {
        if contains(member) { remove(member) } else { insert(member) }
    }
}

// MARK: - A skill's card

struct SkillCardView: View {
    @Environment(SkillStore.self) private var skills
    let card: SkillCatalog.Card
    @State private var preview: SkillCatalog.Preview?
    /// The line a finding pointed at: the preview scrolls to it.
    @State private var focusLine: Int?
    @State private var showsAllFindings = false
    @State private var note = ""
    /// The note as last saved: typing is saved a moment after it stops.
    @State private var savedNote = ""

    var body: some View {
        let assessment = card.assessment
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(verbatim: card.row.name).scaledFont(.headline).lineLimit(2)
                    SkillVerdictBadge(verdict: assessment.verdict)
                    SkillStarButton(id: card.row.id, isFavorite: card.row.isFavorite)
                    Spacer(minLength: 0)
                    Text("Риск \(assessment.riskScore) из 100").scaledFont(.caption).foregroundStyle(.secondary)
                }
                if !card.row.description.isEmpty {
                    Text(verbatim: card.row.description).scaledFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let about = Self.about(card.row) {
                    Text(verbatim: about).scaledFont(.caption2).foregroundStyle(.secondary)
                }
                if card.isMissing {
                    Text("Папки нет или её не удаётся прочитать.").scaledFont(.caption).foregroundStyle(.red)
                } else if card.isChanged {
                    Text("Папка изменилась после проверки. Вердикт относится к прежней версии.").scaledFont(.caption).foregroundStyle(.orange)
                }
            }
            why(assessment)
            noteEditor
            capabilities(assessment)
            if !assessment.advice.isEmpty { advice(assessment) }
            places
            findings
            files
            if let preview { SkillPreviewView(preview: preview, focusLine: focusLine) }
        }
        .task(id: card.row.id) {
            note = card.row.note
            savedNote = card.row.note
            preview = nil
            if card.files.contains(where: { $0.path == "SKILL.md" && $0.isReadable }) { preview = await skills.preview(card.row.id, file: "SKILL.md") }
        }
    }

    /// Who made it and under which license, when the skill says.
    static func about(_ row: SkillCatalog.Row) -> String? {
        let parts = [row.author.map { String(localized: "Автор: \($0)") }, row.license.map { String(localized: "Лицензия: \($0)") }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var noteEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            section("Заметка")
            TextField("Только для вас: зачем скилл, что проверили…", text: $note, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...6)
                .scaledFont(.caption)
                .onSubmit { saveNote() }
        }
        .task(id: note) {
            guard note != savedNote else { return }
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            saveNote()
        }
        .onDisappear { saveNote() }
    }

    private func saveNote() {
        guard note != savedNote else { return }
        savedNote = note
        let (id, text) = (card.row.id, note)
        Task { await skills.setNote(id, text) }
    }

    private func section(_ title: LocalizedStringKey) -> some View {
        Text(title).scaledFont(.caption, weight: .semibold).foregroundStyle(.secondary).textCase(.uppercase)
    }

    /// «Почему такая оценка»: the verdict in a sentence, the findings that decided it, the rest counted.
    private func why(_ assessment: SkillAssessment) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(Self.headline(assessment)).scaledFont(.callout, weight: .medium)
            ForEach(Array(assessment.reasons.enumerated()), id: \.offset) { _, reason in
                Button { Task { await show(reason.finding.file, line: reason.finding.line) } } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Circle().fill(reason.finding.severity.color).frame(width: 6, height: 6)
                            Text(SkillRuleText.title(reason.finding.rule)).scaledFont(.caption, weight: .semibold)
                            if reason.alsoFound > 0 { Text("и ещё \(reason.alsoFound)").scaledFont(.caption2).foregroundStyle(.secondary) }
                        }
                        Text(SkillRuleText.why(reason.finding.rule)).scaledFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if !reason.finding.file.isEmpty {
                            Text(verbatim: Self.place(reason.finding)).scaledFont(.caption2).monospaced().foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if assessment.otherFindings > 0 {
                Text("Ещё находок: \(assessment.otherFindings) — ниже").scaledFont(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(assessment.verdict.color.opacity(0.1)))
    }

    static func headline(_ assessment: SkillAssessment) -> String {
        switch assessment.verdict {
        case .safe: String(localized: "Безопасно: только инструкции, ничего не найдено.")
        case .review: String(localized: "Проверить, потому что:")
        case .dangerous: String(localized: "Опасно, потому что:")
        }
    }

    static func place(_ finding: SkillFinding) -> String {
        finding.line > 0 ? String(localized: "\(finding.file), строка \(finding.line)") : finding.file
    }

    /// What the skill can do, as icons: a quiet one for present, a coloured one for risky.
    private func capabilities(_ assessment: SkillAssessment) -> some View {
        let present = SkillAssessment.Capability.allCases.filter { assessment.level($0) != .none }
        return VStack(alignment: .leading, spacing: 4) {
            section("Что может скилл")
            if present.isEmpty {
                Text("Только читает инструкции: ни сети, ни команд, ни настроек.").scaledFont(.caption).foregroundStyle(.secondary)
            } else {
                FlowRow(spacing: 6) {
                    ForEach(present, id: \.self) { capability in
                        let risky = assessment.level(capability) == .risky
                        Label(capability.title, systemImage: capability.symbol)
                            .scaledFont(.caption2, weight: risky ? .semibold : .regular)
                            .foregroundStyle(risky ? Color.red : Color.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill((risky ? Color.red : Color.primary).opacity(0.08)))
                    }
                }
            }
        }
    }

    private func advice(_ assessment: SkillAssessment) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            section("Что сделало бы безопаснее")
            ForEach(assessment.advice, id: \.self) { item in
                Text(verbatim: "• " + item.text).scaledFont(.caption).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var places: some View {
        if !card.places.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                section("Где установлен")
                ForEach(Array(card.places.enumerated()), id: \.offset) { _, place in
                    HStack(spacing: 6) {
                        Text(verbatim: place.agent.title).scaledFont(.caption, weight: .medium)
                        Text(place.scope == "project" ? String(localized: "проект \(place.project ?? "")") : Self.scope(place.scope))
                            .scaledFont(.caption2).foregroundStyle(.secondary)
                        if !place.isEnabled { Text("выключен").scaledFont(.caption2).foregroundStyle(.orange) }
                        Spacer(minLength: 4)
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: place.installPath)])
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.borderless)
                        .help(String(localized: "Показать в Finder"))
                    }
                }
            }
        }
    }

    static func scope(_ scope: String) -> String {
        switch scope {
        case "plugin": String(localized: "плагин")
        case "extension": String(localized: "расширение")
        default: String(localized: "для вас")
        }
    }

    @ViewBuilder
    private var findings: some View {
        let worth = card.report.findings.filter { $0.severity >= .low }
        if !worth.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Button {
                    showsAllFindings.toggle()
                } label: {
                    HStack(spacing: 4) {
                        section("Все находки")
                        Text(verbatim: "\(worth.count)").scaledFont(.caption2).foregroundStyle(.secondary)
                        Image(systemName: showsAllFindings ? "chevron.up" : "chevron.down").scaledFont(.caption2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showsAllFindings {
                    ForEach(Array(worth.enumerated()), id: \.offset) { _, finding in
                        Button { Task { await show(finding.file, line: finding.line) } } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 4) {
                                    Text(finding.severity.title).scaledFont(.caption2, weight: .semibold).foregroundStyle(finding.severity.color)
                                    Text(SkillRuleText.title(finding.rule)).scaledFont(.caption, weight: .medium)
                                }
                                if !finding.file.isEmpty { Text(verbatim: Self.place(finding)).scaledFont(.caption2).monospaced().foregroundStyle(.secondary) }
                                Text(verbatim: finding.excerpt)
                                    .scaledFont(.caption2)
                                    .monospaced()
                                    .lineLimit(3)
                                    .padding(4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06)))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var files: some View {
        if !card.files.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                section("Файлы")
                ForEach(card.files) { file in
                    Button { Task { await show(file.path, line: 0) } } label: {
                        HStack(spacing: 6) {
                            Text(verbatim: file.path).scaledFont(.caption).monospaced().lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            if file.findings > 0 {
                                Text(verbatim: "\(file.findings)").scaledFont(.caption2, weight: .semibold).foregroundStyle(.orange)
                            }
                            Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)).scaledFont(.caption2).foregroundStyle(.secondary)
                        }
                        .foregroundStyle(preview?.path == file.path ? Color.accentColor : Color.primary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!file.isReadable)
                }
            }
        }
    }

    private func show(_ file: String, line: Int) async {
        guard card.files.contains(where: { $0.path == file && $0.isReadable }) else { return }
        if preview?.path != file { preview = await skills.preview(card.row.id, file: file) }
        focusLine = line > 0 ? line : nil
    }
}

/// A file's text with line numbers, the lines the scanner pointed at marked by the finding's colour.
private struct SkillPreviewView: View {
    let preview: SkillCatalog.Preview
    var focusLine: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: preview.path)
                .scaledFont(.caption, weight: .semibold)
                .monospaced()
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.08))
            ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(preview.lines.enumerated()), id: \.offset) { index, line in
                        let mark = preview.marks[index + 1]
                        HStack(alignment: .top, spacing: 6) {
                            Text(verbatim: "\(index + 1)").foregroundStyle(.secondary).frame(width: 28, alignment: .trailing)
                            Text(verbatim: line.isEmpty ? " " : line).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .scaledFont(.caption2)
                        .monospaced()
                        .padding(.vertical, 1)
                        .background(mark.map { $0.severity.color.opacity(0.15) } ?? .clear)
                        .help(mark.map { SkillRuleText.title($0.rule) } ?? "")
                        .id(index + 1)
                    }
                }
                .textSelection(.enabled)
            }
            .frame(maxHeight: 260)
            .onAppear { if let focusLine { reader.scrollTo(focusLine, anchor: .center) } }
            .onChange(of: focusLine) { if let focusLine { withAnimation { reader.scrollTo(focusLine, anchor: .center) } } }
            }
            if preview.isCut {
                Text("Файл длиннее: показано только начало.").scaledFont(.caption2).foregroundStyle(.secondary).padding(4)
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
    }
}

/// Views in a row that wraps to the next line when the width runs out.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var (x, y, line) = (CGFloat(0), CGFloat(0), CGFloat(0))
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                y += line + spacing
                x = 0
                line = 0
            }
            x += size.width + spacing
            line = max(line, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var (x, y, line) = (bounds.minX, bounds.minY, CGFloat(0))
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += line + spacing
                x = bounds.minX
                line = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}
