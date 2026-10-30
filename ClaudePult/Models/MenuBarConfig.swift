import Foundation

/// The menu bar item, assembled from elements (SPEC-modes §7). Stored as JSON in UserDefaults and in exports.
struct MenuBarConfig: Codable, Equatable, Hashable, Sendable {
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

    /// Always contains every kind once; the order is the order in the menu bar.
    var elements: [MenuBarElement]
    var separator: Separator
    var smallText: Bool
    /// Percentages coloured by level (green / orange / red) or in the menu bar's own colour.
    var colored: Bool
    var preset: Preset

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

    /// The single menu bar setting ClaudePult had before the builder.
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

    enum CodingKeys: String, CodingKey { case elements, separator, smallText, colored, preset }

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
            case .mode: String(localized: "Текущий режим")
            }
        }

        var isGauge: Bool { self == .session || self == .week || self == .modelWeek }
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
    /// Model week: the window key, e.g. `seven_day_fable`; nil = the first one available.
    var model: String?
    /// Icon: an SF Symbol, `mode` for the current mode's icon.
    var symbol: String = "sparkle"
    /// Reset countdown: «2 ч 14 мин» instead of «2:14».
    var longFormat: Bool = false
    /// Disk: show only below this many GB.
    var diskBelowGB: Int = 20
    /// Mode: its name instead of its icon.
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
    /// Countdowns are drawn for this minute.
    var now: Date = .now

    static let sample = MenuBarData(
        showsAlert: true, waiting: 1, running: 2, background: 1, queued: 1, session: 34, week: 58,
        modelWeeks: ["seven_day_fable": 12], sessionResetsAt: Date.now.addingTimeInterval(2 * 3600 + 14 * 60),
        forecastRunsOut: Date.now.addingTimeInterval(90 * 60), diskFreeBytes: 12_000_000_000,
        deadline: String(localized: "Ролик · 2 дн"), modeName: String(localized: "Видео"), modeIcon: "video"
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

/// Config + data → what to draw. Pure, so it is tested without drawing.
enum MenuBarComposer {
    /// Groups are joined with the separator; inside a group pieces touch.
    static func groups(_ config: MenuBarConfig, _ data: MenuBarData) -> [[MenuBarSegment]] {
        var groups: [[MenuBarSegment]] = []
        func level(_ value: Double) -> MenuBarSegment.Tint { config.colored ? .level(value) : .label }

        for element in config.elements where element.enabled {
            switch element.kind {
            case .icon:
                let name = element.symbol == "mode" ? (data.modeIcon ?? "sparkle") : element.symbol
                if name != "none" { groups.append([.symbol(name)]) }
            case .projectsAlert:
                guard data.showsAlert else { continue }
                // The dot sits on the icon when it comes right after it.
                if case .symbol? = groups.last?.last, groups.last?.count == 1 {
                    groups[groups.count - 1].append(.dot)
                } else {
                    groups.append([.dot])
                }
            case .session, .week, .modelWeek:
                let value: Double? = switch element.kind {
                case .session: data.session
                case .week: data.week
                default: element.model.flatMap { data.modelWeeks[$0] } ?? data.modelWeeks.sorted { $0.key < $1.key }.first?.value
                }
                guard let value, value >= Double(element.showAbove) else { continue }
                switch element.style {
                case .number: groups.append([.text("\(Int(value.rounded()))%", level(value))])
                case .ring: groups.append([.ring(value, level(value))])
                case .bar: groups.append([.bar(value, level(value))])
                }
            case .resetCountdown:
                guard let resets = data.sessionResetsAt, resets > data.now else { continue }
                groups.append([.labeled(symbol: "arrow.clockwise", text: countdown(to: resets, now: data.now, long: element.longFormat), .secondary)])
            case .forecast:
                guard let runsOut = data.forecastRunsOut else { continue }
                groups.append([.text(String(localized: "до ") + runsOut.formatted(date: .omitted, time: .shortened), .warning)])
            case .waiting:
                if data.waiting > 0 { groups.append([.labeled(symbol: "hand.raised.fill", text: "\(data.waiting)", .label)]) }
            case .running:
                if data.running > 0 { groups.append([.labeled(symbol: "bolt.fill", text: "\(data.running)", .label)]) }
            case .background:
                if data.background > 0 { groups.append([.labeled(symbol: "moon.zzz.fill", text: "\(data.background)", .label)]) }
            case .queued:
                if data.queued > 0 { groups.append([.labeled(symbol: "clock", text: "\(data.queued)", .label)]) }
            case .deadline:
                if let deadline = data.deadline { groups.append([.labeled(symbol: "calendar", text: deadline, .label)]) }
            case .disk:
                guard let bytes = data.diskFreeBytes, bytes < Int64(element.diskBelowGB) * 1_000_000_000 else { continue }
                groups.append([.labeled(symbol: "internaldrive", text: String(localized: "\(bytes / 1_000_000_000) ГБ"), .warning)])
            case .mode:
                if element.showName, let name = data.modeName {
                    groups.append([.text(name, .secondary)])
                } else if let icon = data.modeIcon {
                    groups.append([.symbol(icon)])
                }
            }
        }
        // An empty item could not be clicked at all.
        return groups.isEmpty ? [[.symbol("sparkle")]] : groups
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
        var parts = ["ClaudePult"]
        let on = Set(config.elements.filter(\.enabled).map(\.kind))
        if on.contains(.session), let session = data.session { parts.append(String(localized: "сессия \(Int(session.rounded())) %")) }
        if on.contains(.week), let week = data.week { parts.append(String(localized: "неделя \(Int(week.rounded())) %")) }
        if on.contains(.projectsAlert), data.showsAlert { parts.append(String(localized: "есть проекты с проблемами")) }
        if on.contains(.waiting), data.waiting > 0 { parts.append(String(localized: "ждут ответа: \(data.waiting)")) }
        if on.contains(.background), data.background > 0 { parts.append(String(localized: "фоновых задач: \(data.background)")) }
        return parts.joined(separator: ", ")
    }
}
