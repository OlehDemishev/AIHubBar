import Foundation

/// The menu bar item, assembled from elements (SPEC-modes §7). Stored as JSON in UserDefaults and in exports.
struct MenuBarConfig: Codable, Equatable, Hashable, Sendable {
    /// While the notch island's ears show the summary («только в острове»): the icon and the projects' red dot only.
    var iconOnly: MenuBarConfig {
        var config = self
        for index in config.elements.indices where ![.icon, .projectsAlert].contains(config.elements[index].kind) {
            config.elements[index].enabled = false
        }
        if !config.elements.contains(where: { $0.kind == .icon && $0.enabled }), let icon = config.elements.firstIndex(where: { $0.kind == .icon }) {
            config.elements[icon].enabled = true
        }
        return config
    }

    /// Modules switched off with their main switch (SPEC-settings §1) draw nothing: their elements, from the module
    /// registry, are off.
    func without(_ off: [ModuleKind]) -> MenuBarConfig {
        var config = self
        for index in config.elements.indices where config.elements[index].kind.module.map(off.contains) == true {
            config.elements[index].enabled = false
        }
        return config
    }

    enum Separator: String, Codable, CaseIterable, Sendable {
        case space, dot, bar

        var text: String {
            switch self {
            case .space: " "
            case .dot: " · "
            case .bar: " | "
            }
        }

        var title: String {
            switch self {
            case .space: String(localized: "Пробел")
            case .dot: String(localized: "Точка «·»")
            case .bar: String(localized: "Черта «|»")
            }
        }
    }

    enum Preset: String, Codable, CaseIterable, Sendable {
        case minimum, limits, everything, custom

        var title: String {
            switch self {
            case .minimum: String(localized: "Минимум")
            case .limits: String(localized: "Лимиты")
            case .everything: String(localized: "Всё")
            case .custom: String(localized: "Свой")
            }
        }
    }

    /// A divider placed by hand between elements (SPEC-settings §5); any number of them, anywhere.
    struct Divider: Codable, Equatable, Hashable, Identifiable, Sendable {
        enum Style: String, Codable, CaseIterable, Sendable {
            case space, wideSpace, dot, bar, line, slash, chevron, group

            var title: String {
                switch self {
                case .space: String(localized: "Пробел")
                case .wideSpace: String(localized: "Широкий пробел")
                case .dot: String(localized: "Точка «·»")
                case .bar: String(localized: "Черта «|»")
                case .line: String(localized: "Тонкая линия")
                case .slash: String(localized: "Косая «/»")
                case .chevron: String(localized: "Стрелка «›»")
                case .group: String(localized: "Новая группа")
                }
            }

            /// What the chips in Settings show: the divider itself.
            var glyph: String {
                switch self {
                case .space: "␣"
                case .wideSpace: "␣␣"
                case .dot: "·"
                case .bar: "|"
                case .line: "│"
                case .slash: "/"
                case .chevron: "›"
                case .group: "[ ]"
                }
            }
        }

        var id: String
        /// The element it follows; nil — before the first one.
        var after: MenuBarElement.Kind?
        var style: Style

        init(after: MenuBarElement.Kind?, style: Style, id: String = UUID().uuidString) {
            self.id = id
            self.after = after
            self.style = style
        }
    }

    /// «Плоско» or «Капсулы по группам»: groups between «Новая группа» dividers on a shared rounded backing.
    enum Look: String, Codable, CaseIterable, Sendable {
        case plain, capsules

        var title: String {
            switch self {
            case .plain: String(localized: "Плоско")
            case .capsules: String(localized: "Капсулы по группам")
            }
        }
    }

    /// Always contains every kind once; the order is the order in the menu bar.
    var elements: [MenuBarElement]
    /// The automatic separator between two numbers where no divider is placed by hand.
    var separator: Separator
    var smallText: Bool
    /// Percentages coloured by level (green / orange / red) or in the menu bar's own colour.
    var colored: Bool
    var preset: Preset
    /// After their element, in order (SPEC-settings §5); older versions don't know them and draw as before.
    var dividers: [Divider] = []
    var look: Look = .plain

    static func make(_ preset: Preset) -> MenuBarConfig {
        let on: Set<MenuBarElement.Kind>
        switch preset {
        case .minimum: on = [.icon, .projectsAlert, .waiting]
        case .limits, .custom: on = [.icon, .projectsAlert, .session, .week, .waiting]
        case .everything: on = Set(MenuBarElement.Kind.allCases)
        }
        return MenuBarConfig(
            elements: MenuBarElement.Kind.allCases.map { MenuBarElement(kind: $0, enabled: on.contains($0)) },
            separator: .dot, smallText: false, colored: true, preset: preset
        )
    }

    /// The single menu bar setting AI Hub Bar had before the builder.
    static func migrated(from mode: MenuBarUsageMode) -> MenuBarConfig {
        var config = make(mode == .iconOnly ? .minimum : .limits)
        switch mode {
        case .session: config.set(.week) { $0.enabled = false }
        case .ring:
            config.set(.week) { $0.enabled = false }
            config.set(.session) { $0.style = .ring }
        case .iconOnly, .sessionAndWeek: break
        }
        return config
    }

    /// The closest pre-builder setting, written into exports for older versions.
    var legacyMode: MenuBarUsageMode {
        let session = element(.session), week = element(.week)
        guard session.enabled else { return .iconOnly }
        if session.style == .ring { return .ring }
        return week.enabled ? .sessionAndWeek : .session
    }

    func element(_ kind: MenuBarElement.Kind) -> MenuBarElement {
        elements.first { $0.kind == kind } ?? MenuBarElement(kind: kind, enabled: false)
    }

    mutating func set(_ kind: MenuBarElement.Kind, _ change: (inout MenuBarElement) -> Void) {
        if let index = elements.firstIndex(where: { $0.kind == kind }) { change(&elements[index]) }
    }

    /// Drag and drop: `kind` takes `target`'s place — dropped on an element to its right it lands after it, to its
    /// left before it, so any element reaches any position.
    mutating func move(_ kind: MenuBarElement.Kind, onto target: MenuBarElement.Kind) {
        guard kind != target,
              let from = elements.firstIndex(where: { $0.kind == kind }),
              let to = elements.firstIndex(where: { $0.kind == target }) else { return }
        elements.insert(elements.remove(at: from), at: to)
    }

    /// Puts `style` right after `kind` (nil — at the start), behind the dividers already there.
    mutating func addDivider(_ style: Divider.Style, after kind: MenuBarElement.Kind?) {
        dividers.append(Divider(after: kind, style: style))
    }

    /// Moves a placed divider behind `kind`, last among the ones there.
    mutating func moveDivider(_ id: String, after kind: MenuBarElement.Kind?) {
        guard let index = dividers.firstIndex(where: { $0.id == id }) else { return }
        var divider = dividers.remove(at: index)
        divider.after = kind
        dividers.append(divider)
    }

    mutating func removeDivider(_ id: String) {
        dividers.removeAll { $0.id == id }
    }

    /// A switched-on element or a divider, as the order chips show them.
    enum Arranged: Equatable {
        case element(MenuBarElement.Kind)
        case divider(Divider)
    }

    /// Takes the order of the chips: switched-on elements fill their slots in that order (switched-off ones keep
    /// theirs), each divider follows the element before it.
    mutating func arrange(_ order: [Arranged]) {
        var shown = order.compactMap { if case let .element(kind) = $0 { kind } else { nil } }.makeIterator()
        elements = elements.map { element in
            guard element.enabled, let kind = shown.next() else { return element }
            return self.element(kind)
        }
        var after: MenuBarElement.Kind?
        var placed: [Divider] = []
        for item in order {
            switch item {
            case let .element(kind): after = kind
            case var .divider(divider):
                divider.after = after
                placed.append(divider)
            }
        }
        dividers = placed
    }

    enum CodingKeys: String, CodingKey { case elements, separator, smallText, colored, preset, dividers, look }

    init(elements: [MenuBarElement], separator: Separator, smallText: Bool, colored: Bool, preset: Preset) {
        self.elements = elements
        self.separator = separator
        self.smallText = smallText
        self.colored = colored
        self.preset = preset
    }

    /// Tolerant: unknown elements are dropped, missing kinds are added switched off.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = (try? c.decodeIfPresent([Lossy<MenuBarElement>].self, forKey: .elements))?.compactMap(\.value) ?? []
        var elements: [MenuBarElement] = []
        for element in decoded where !elements.contains(where: { $0.kind == element.kind }) { elements.append(element) }
        for kind in MenuBarElement.Kind.allCases where !elements.contains(where: { $0.kind == kind }) {
            elements.append(MenuBarElement(kind: kind, enabled: false))
        }
        self.elements = elements
        separator = (try? c.decodeIfPresent(Separator.self, forKey: .separator)) ?? .dot
        smallText = (try? c.decodeIfPresent(Bool.self, forKey: .smallText)) ?? false
        colored = (try? c.decodeIfPresent(Bool.self, forKey: .colored)) ?? true
        preset = (try? c.decodeIfPresent(Preset.self, forKey: .preset)) ?? .custom
        dividers = (try? c.decodeIfPresent([Lossy<Divider>].self, forKey: .dividers))?.compactMap(\.value) ?? []
        look = (try? c.decodeIfPresent(Look.self, forKey: .look)) ?? .plain
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(elements, forKey: .elements)
        try c.encode(separator, forKey: .separator)
        try c.encode(smallText, forKey: .smallText)
        try c.encode(colored, forKey: .colored)
        try c.encode(preset, forKey: .preset)
        if !dividers.isEmpty { try c.encode(dividers, forKey: .dividers) }
        if look != .plain { try c.encode(look, forKey: .look) }
    }
}

private struct Lossy<Value: Decodable>: Decodable {
    var value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

struct MenuBarElement: Codable, Equatable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case icon, projectsAlert, session, week, modelWeek, resetCountdown, forecast
        case waiting, running, background, queued, deadline, disk, mode
        /// From «Ресурсы Mac» (SPEC-profiles §4.1).
        case cpu, memory
        /// ☕ while «Не спать» holds the Mac awake.
        case keepAwake
        /// The fullest limit of the other AI services, or the chosen one (SPEC-hub).
        case otherAI

        var title: String {
            switch self {
            case .icon: String(localized: "Значок")
            case .projectsAlert: String(localized: "Проблемы проектов (красная точка)")
            case .session: String(localized: "Сессия (5 ч)")
            case .week: String(localized: "Неделя")
            case .modelWeek: String(localized: "Неделя по модели")
            case .resetCountdown: String(localized: "До сброса сессии")
            case .forecast: String(localized: "Прогноз (если не хватит до сброса)")
            case .waiting: String(localized: "Ждут ответа")
            case .running: String(localized: "Работают сессии")
            case .background: String(localized: "Фоновые задачи")
            case .queued: String(localized: "Отложенные запуски")
            case .deadline: String(localized: "Ближайшая дата календаря")
            case .disk: String(localized: "Свободное место (если мало)")
            case .mode: String(localized: "Текущий профиль")
            case .cpu: String(localized: "Процессор (модуль «Ресурсы Mac»)")
            case .memory: String(localized: "Память (модуль «Ресурсы Mac»)")
            case .keepAwake: String(localized: "☕, когда Mac не засыпает (модуль «Не спать»)")
            case .otherAI: String(localized: "Другие AI: Codex, Copilot, Gemini…")
            }
        }

        var isGauge: Bool { [.session, .week, .modelWeek, .cpu, .memory, .otherAI].contains(self) }

        /// For the order chips in Settings.
        var shortTitle: String {
            switch self {
            case .icon: String(localized: "Значок")
            case .projectsAlert: String(localized: "Проблемы")
            case .session: String(localized: "Сессия")
            case .week: String(localized: "Неделя")
            case .modelWeek: String(localized: "Модель")
            case .resetCountdown: String(localized: "Сброс")
            case .forecast: String(localized: "Прогноз")
            case .waiting: String(localized: "Ждут")
            case .running: String(localized: "Работают")
            case .background: String(localized: "Фон")
            case .queued: String(localized: "Очередь")
            case .deadline: String(localized: "Дата")
            case .disk: String(localized: "Диск")
            case .mode: String(localized: "Профиль")
            case .cpu: String(localized: "Процессор")
            case .memory: String(localized: "Память")
            case .keepAwake: String(localized: "Не спать")
            case .otherAI: String(localized: "Другие AI")
            }
        }
    }

    enum GaugeStyle: String, Codable, CaseIterable, Sendable {
        case number, ring, bar

        var title: String {
            switch self {
            case .number: String(localized: "Число %")
            case .ring: String(localized: "Кольцо")
            case .bar: String(localized: "Полоска")
            }
        }
    }

    var kind: Kind
    var enabled: Bool
    var style: GaugeStyle = .number
    /// Gauges: show only from this percentage (0 = always).
    var showAbove: Int = 0
    /// Model week: the window key, e.g. `seven_day_fable`; nil = the first one available. Other AI: the service
    /// (`HubLimit.Source` raw value); nil = the fullest one.
    var model: String?
    /// Icon: an SF Symbol, `mode` for the current mode's icon.
    var symbol: String = "sparkle"
    /// Reset countdown: «2 ч 14 мин» instead of «2:14».
    var longFormat: Bool = false
    /// Disk: show only below this many GB.
    var diskBelowGB: Int = 20
    /// Profile: its name instead of its icon.
    var showName: Bool = false

    var id: String { kind.rawValue }

    init(kind: Kind, enabled: Bool) {
        self.kind = kind
        self.enabled = enabled
    }

    enum CodingKeys: String, CodingKey { case kind, enabled, style, showAbove, model, symbol, longFormat, diskBelowGB, showName }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        style = (try? c.decodeIfPresent(GaugeStyle.self, forKey: .style)) ?? .number
        showAbove = (try? c.decodeIfPresent(Int.self, forKey: .showAbove)) ?? 0
        model = try? c.decodeIfPresent(String.self, forKey: .model)
        symbol = (try? c.decodeIfPresent(String.self, forKey: .symbol)) ?? "sparkle"
        longFormat = (try? c.decodeIfPresent(Bool.self, forKey: .longFormat)) ?? false
        diskBelowGB = (try? c.decodeIfPresent(Int.self, forKey: .diskBelowGB)) ?? 20
        showName = (try? c.decodeIfPresent(Bool.self, forKey: .showName)) ?? false
    }
}

/// What the menu bar can show right now.
struct MenuBarData: Equatable, Hashable, Sendable {
    var showsAlert = false
    var waiting = 0
    var running = 0
    var background = 0
    var queued = 0
    var session: Double?
    var week: Double?
    /// Per-model weeks: window key → percent.
    var modelWeeks: [String: Double] = [:]
    var sessionResetsAt: Date?
    var forecastRunsOut: Date?
    var diskFreeBytes: Int64?
    var deadline: String?
    var modeName: String?
    var modeIcon: String?
    /// «Ресурсы Mac», when installed.
    var cpu: Double?
    var memory: Double?
    var keepingAwake = false
    /// Other AI services: source raw value → its fullest limit, in percent.
    var otherAI: [String: Double] = [:]
    /// Countdowns are drawn for this minute.
    var now: Date = .now

    static let sample = MenuBarData(
        showsAlert: true, waiting: 1, running: 2, background: 1, queued: 1, session: 34, week: 58,
        modelWeeks: ["seven_day_fable": 12], sessionResetsAt: Date.now.addingTimeInterval(2 * 3600 + 14 * 60),
        forecastRunsOut: Date.now.addingTimeInterval(90 * 60), diskFreeBytes: 12_000_000_000,
        deadline: String(localized: "Ролик · 2 дн"), modeName: String(localized: "Видео"), modeIcon: "video",
        cpu: 23, memory: 71, keepingAwake: true, otherAI: ["codex": 42]
    )
}

/// One drawable piece of the menu bar item.
enum MenuBarSegment: Hashable, Sendable {
    enum Tint: Hashable, Sendable {
        case label, secondary, level(Double), warning
    }

    case symbol(String)
    /// Red dot over the preceding symbol.
    case dot
    case text(String, Tint)
    /// A small symbol followed by text: ✋ 2, 🌙 1 …
    case labeled(symbol: String, text: String, Tint)
    case ring(Double, Tint)
    case bar(Double, Tint)
}

/// One piece of the item, left to right: a group of segments or what stands between two groups.
enum MenuBarPiece: Hashable, Sendable {
    case group([MenuBarSegment])
    /// Placed by hand (SPEC-settings §5).
    case divider(MenuBarConfig.Divider.Style)
    /// The automatic separator between two numbers.
    case separator
    /// The small gap next to symbols and counters.
    case gap
}

/// Config + data → what to draw. Pure, so it is tested without drawing.
enum MenuBarComposer {
    /// The groups alone; between them the separator or the dividers of `strip`.
    static func groups(_ config: MenuBarConfig, _ data: MenuBarData) -> [[MenuBarSegment]] {
        strip(config, data).compactMap { piece in
            if case let .group(group) = piece { group } else { nil }
        }
    }

    /// Everything in order. Dividers stand only between two groups that are drawn now: an element with nothing to show
    /// leaves no divider hanging at an edge. Where none is placed, numbers get the separator and the rest a gap.
    static func strip(_ config: MenuBarConfig, _ data: MenuBarData) -> [MenuBarPiece] {
        var pieces: [MenuBarPiece] = []
        var pending = config.dividers.filter { $0.after == nil }.map(\.style)
        var lastGroup: [MenuBarSegment]?

        func add(_ group: [MenuBarSegment]) {
            if let lastGroup {
                if !pending.isEmpty {
                    pieces += pending.map(MenuBarPiece.divider)
                } else {
                    pieces.append(usesSeparator(between: lastGroup, and: group) ? .separator : .gap)
                }
            }
            pending = []
            pieces.append(.group(group))
            lastGroup = group
        }

        for element in config.elements {
            if element.enabled {
                if element.kind == .projectsAlert, data.showsAlert, pending.isEmpty,
                   let last = lastGroup, last.count == 1, case .symbol = last[0] {
                    // The dot sits on the icon when it comes right after it.
                    pieces[pieces.count - 1] = .group(last + [.dot])
                    lastGroup = last + [.dot]
                } else if let group = segments(element, config, data) {
                    add(group)
                }
            }
            pending += config.dividers.filter { $0.after == element.kind }.map(\.style)
        }
        // An empty item could not be clicked at all.
        return lastGroup == nil ? [.group([.symbol("sparkle")])] : pieces
    }

    /// What one element draws now; nil when it has nothing to show.
    static func segments(_ element: MenuBarElement, _ config: MenuBarConfig, _ data: MenuBarData) -> [MenuBarSegment]? {
        func level(_ value: Double) -> MenuBarSegment.Tint { config.colored ? .level(value) : .label }

        switch element.kind {
        case .icon:
            let name = element.symbol == "mode" ? (data.modeIcon ?? "sparkle") : element.symbol
            return name == "none" ? nil : [.symbol(name)]
        case .projectsAlert:
            return data.showsAlert ? [.dot] : nil
        case .session, .week, .modelWeek:
            let value: Double? = switch element.kind {
            case .session: data.session
            case .week: data.week
            default: element.model.flatMap { data.modelWeeks[$0] } ?? data.modelWeeks.sorted { $0.key < $1.key }.first?.value
            }
            guard let value, value >= Double(element.showAbove) else { return nil }
            return switch element.style {
            case .number: [.text("\(Int(value.rounded()))%", level(value))]
            case .ring: [.ring(value, level(value))]
            case .bar: [.bar(value, level(value))]
            }
        case .resetCountdown:
            guard let resets = data.sessionResetsAt, resets > data.now else { return nil }
            return [.labeled(symbol: "arrow.clockwise", text: countdown(to: resets, now: data.now, long: element.longFormat), .secondary)]
        case .forecast:
            guard let runsOut = data.forecastRunsOut else { return nil }
            return [.text(String(localized: "до ") + runsOut.formatted(date: .omitted, time: .shortened), .warning)]
        case .waiting:
            return data.waiting > 0 ? [.labeled(symbol: "hand.raised.fill", text: "\(data.waiting)", .label)] : nil
        case .running:
            return data.running > 0 ? [.labeled(symbol: "bolt.fill", text: "\(data.running)", .label)] : nil
        case .background:
            return data.background > 0 ? [.labeled(symbol: "moon.zzz.fill", text: "\(data.background)", .label)] : nil
        case .queued:
            return data.queued > 0 ? [.labeled(symbol: "clock", text: "\(data.queued)", .label)] : nil
        case .deadline:
            return data.deadline.map { [.labeled(symbol: "calendar", text: $0, .label)] }
        case .disk:
            guard let bytes = data.diskFreeBytes, bytes < Int64(element.diskBelowGB) * 1_000_000_000 else { return nil }
            return [.labeled(symbol: "internaldrive", text: String(localized: "\(bytes / 1_000_000_000) ГБ"), .warning)]
        case .cpu, .memory:
            // A small chip symbol says which number it is: the gauges look like the limits otherwise.
            guard let value = element.kind == .cpu ? data.cpu : data.memory, value >= Double(element.showAbove) else { return nil }
            let symbol = element.kind == .cpu ? "cpu" : "memorychip"
            return switch element.style {
            case .number: [.labeled(symbol: symbol, text: "\(Int(value.rounded()))%", level(value))]
            case .ring: [.symbol(symbol), .ring(value, level(value))]
            case .bar: [.symbol(symbol), .bar(value, level(value))]
            }
        case .keepAwake:
            return data.keepingAwake ? [.symbol("cup.and.saucer.fill")] : nil
        case .otherAI:
            guard let (source, value) = otherAI(element, data), value >= Double(element.showAbove) else { return nil }
            let name = HubLimit.Source(rawValue: source)?.shortTitle ?? source
            return switch element.style {
            case .number: [.text("\(name) \(Int(value.rounded()))%", level(value))]
            case .ring: [.text(name, .secondary), .ring(value, level(value))]
            case .bar: [.text(name, .secondary), .bar(value, level(value))]
            }
        case .mode:
            if element.showName, let name = data.modeName { return [.text(name, .secondary)] }
            return data.modeIcon.map { [.symbol($0)] }
        }
    }

    /// The chosen service, or the fullest one when none is chosen (or the chosen one has no limit now).
    static func otherAI(_ element: MenuBarElement, _ data: MenuBarData) -> (String, Double)? {
        if let source = element.model, let value = data.otherAI[source] { return (source, value) }
        guard element.model == nil else { return nil }
        return data.otherAI.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }.map { ($0.key, $0.value) }
    }

    /// «2:14» or «2 ч 14 мин».
    static func countdown(to date: Date, now: Date, long: Bool) -> String {
        let minutes = max(0, Int(date.timeIntervalSince(now) / 60))
        if long {
            return minutes >= 60 ? String(localized: "\(minutes / 60) ч \(minutes % 60) мин") : String(localized: "\(minutes) мин")
        }
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    /// A lone symbol is shown as a template image, exactly like a system menu bar item.
    static func plainSymbol(_ groups: [[MenuBarSegment]]) -> String? {
        if groups.count == 1, groups[0].count == 1, case let .symbol(name) = groups[0][0] { return name }
        return nil
    }

    /// The same for a whole strip: capsules always need drawing.
    static func plainSymbol(_ strip: [MenuBarPiece], look: MenuBarConfig.Look) -> String? {
        guard look == .plain, strip.count == 1, case let .group(group) = strip[0] else { return nil }
        return plainSymbol([group])
    }

    /// Numbers are split by the chosen separator; symbols and counters (✋ 2) only by a small gap.
    static func usesSeparator(between left: [MenuBarSegment], and right: [MenuBarSegment]) -> Bool {
        func isValue(_ group: [MenuBarSegment]) -> Bool {
            switch group.first {
            case .text?, .ring?, .bar?: true
            default: false
            }
        }
        return isValue(left) && isValue(right)
    }

    static func accessibilityText(_ config: MenuBarConfig, _ data: MenuBarData) -> String {
        var parts = ["AI Hub Bar"]
        let on = Set(config.elements.filter(\.enabled).map(\.kind))
        if on.contains(.session), let session = data.session { parts.append(String(localized: "сессия \(Int(session.rounded())) %")) }
        if on.contains(.week), let week = data.week { parts.append(String(localized: "неделя \(Int(week.rounded())) %")) }
        if on.contains(.projectsAlert), data.showsAlert { parts.append(String(localized: "есть проекты с проблемами")) }
        if on.contains(.waiting), data.waiting > 0 { parts.append(String(localized: "ждут ответа: \(data.waiting)")) }
        if on.contains(.background), data.background > 0 { parts.append(String(localized: "фоновых задач: \(data.background)")) }
        // Also the menu bar item's tooltip: every element it can draw gets its words.
        if on.contains(.running), data.running > 0 { parts.append(String(localized: "работают сессии: \(data.running)")) }
        if on.contains(.queued), data.queued > 0 { parts.append(String(localized: "отложенных запусков: \(data.queued)")) }
        if on.contains(.resetCountdown), let resets = data.sessionResetsAt, resets > data.now {
            parts.append(String(localized: "сброс сессии через \(countdown(to: resets, now: data.now, long: true))"))
        }
        if on.contains(.forecast), let runsOut = data.forecastRunsOut {
            parts.append(String(localized: "лимит кончится в \(runsOut.formatted(date: .omitted, time: .shortened))"))
        }
        if on.contains(.deadline), let deadline = data.deadline { parts.append(String(localized: "ближайшее: \(deadline)")) }
        if on.contains(.disk), let bytes = data.diskFreeBytes,
           let element = config.elements.first(where: { $0.kind == .disk }), bytes < Int64(element.diskBelowGB) * 1_000_000_000 {
            parts.append(String(localized: "свободно \(bytes / 1_000_000_000) ГБ"))
        }
        if on.contains(.cpu), let cpu = data.cpu { parts.append(String(localized: "процессор \(Int(cpu.rounded())) %")) }
        if on.contains(.memory), let memory = data.memory { parts.append(String(localized: "память \(Int(memory.rounded())) %")) }
        if on.contains(.keepAwake), data.keepingAwake { parts.append(String(localized: "Mac не засыпает")) }
        if on.contains(.otherAI), let element = config.elements.first(where: { $0.kind == .otherAI }), let (source, value) = otherAI(element, data) {
            parts.append("\(HubLimit.Source(rawValue: source)?.title ?? source) \(Int(value.rounded())) %")
        }
        if on.contains(.mode), let name = data.modeName { parts.append(String(localized: "профиль «\(name)»")) }
        return parts.joined(separator: ", ")
    }
}
