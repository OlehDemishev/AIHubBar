import Foundation

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
    /// The «Не спать» switch is on (a manual hold); the rules alone don't count.
    var keepAwakeSwitchedOn = false
    /// Other AI services: source raw value → its fullest limit, in percent.
    var otherAI: [String: Double] = [:]
    /// Countdowns are drawn for this minute.
    var now: Date = .now

    static let sample = MenuBarData(
        showsAlert: true, waiting: 1, running: 2, background: 1, queued: 1, session: 34, week: 58,
        modelWeeks: ["seven_day_fable": 12], sessionResetsAt: Date.now.addingTimeInterval(2 * 3600 + 14 * 60),
        forecastRunsOut: Date.now.addingTimeInterval(90 * 60), diskFreeBytes: 12_000_000_000,
        deadline: String(localized: "Ролик · 2 дн"), modeName: String(localized: "Видео"), modeIcon: "video",
        cpu: 23, memory: 71, keepingAwake: true, keepAwakeSwitchedOn: true, otherAI: ["codex": 42]
    )
}

/// One drawable piece of the menu bar item.
enum MenuBarSegment: Hashable, Sendable {
    enum Tint: Hashable, Sendable {
        case label, secondary, level(Double), warning
    }

    case symbol(String)
    /// A full-size symbol in a colour: the orange ☕.
    case tintedSymbol(String, Tint)
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
            // Follows the switch only: a rule such as «Пока работает Claude» would keep it lit all day.
            return data.keepAwakeSwitchedOn ? [.tintedSymbol("cup.and.saucer.fill", config.colored ? .warning : .label)] : nil
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
