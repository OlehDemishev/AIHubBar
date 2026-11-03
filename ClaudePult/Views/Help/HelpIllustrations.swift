import SwiftUI

/// The moving picture on top of a help topic (docs/SPEC-help.md §3): a short loop drawn from the app's own pieces —
/// the real menu bar renderer, module icons, the panel's colours. With Reduce Motion it shows its last frame, still.
struct HelpIllustration: View {
    let topic: HelpTopic
    @State private var replay = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            stage
                .id(replay)
                .frame(maxWidth: .infinity)
                .frame(height: 210)
                .clipped()
            if !reduceMotion {
                Button { replay += 1 } label: {
                    Label("Ещё раз", systemImage: "arrow.counterclockwise")
                        .labelStyle(.iconOnly)
                        .padding(7)
                        .background(.regularMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Показать ещё раз")
                .padding(10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [topic.tint.opacity(0.16), topic.tint.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(topic.tint.opacity(0.18), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityHidden(true)
    }

    @ViewBuilder private var stage: some View {
        switch topic {
        case .start: StartScene()
        case .menuBar: MenuBarScene()
        case .panel: PanelScene()
        case .modules: ModulesScene()
        case .limits: LimitsScene()
        case .sessions: SessionsScene()
        case .services: ServicesScene()
        case .projects: ProjectsScene()
        case .calendar: CalendarScene()
        case .reports: ReportsScene()
        case .notch: NotchScene()
        case .layout: LayoutScene()
        case .utilities: UtilitiesScene()
        case .alerts: AlertsScene()
        case .commandLine: TerminalScene()
        }
    }
}

/// Steps through `count` frames every `interval` seconds while on screen, springing between them; Reduce Motion —
/// the last frame only.
private struct HelpLoop<Content: View>: View {
    let count: Int
    var interval: Double = 1.3
    @ViewBuilder let content: (Int) -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = 0

    var body: some View {
        content(reduceMotion ? count - 1 : phase)
            .task(id: reduceMotion) {
                guard !reduceMotion else { return }
                phase = 0
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(interval))
                    guard !Task.isCancelled else { return }
                    withAnimation(.spring(duration: 0.55, bounce: 0.22)) { phase = (phase + 1) % count }
                }
            }
    }
}

// MARK: - Pieces

/// A strip like the top of the screen: what's given on the right, then the clock.
private struct FakeMenuBar<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 14) {
            Spacer()
            content
            Text(verbatim: "12:04").font(.system(size: 13, weight: .medium)).monospacedDigit()
        }
        .padding(.horizontal, 16)
        .frame(height: 30)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// A block of the panel in miniature.
private struct MiniCard: View {
    let symbol: String
    let title: String
    let tint: Color
    var trailing: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 16)
            Text(title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 4)
            if let trailing { Text(verbatim: trailing).font(.system(size: 10.5)).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.background.opacity(0.9)))
        .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
    }
}

/// The caption under a scene: which state it shows.
private struct SceneCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(.regularMaterial))
            .contentTransition(.opacity)
            .id(text)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }
}

private func moduleCard(_ kind: ModuleKind, _ trailing: String? = nil) -> MiniCard {
    MiniCard(symbol: kind.symbol, title: kind.title, tint: kind.group.tint, trailing: trailing)
}

// MARK: - Scenes

/// ✦ in the menu bar, a click, the panel drops down.
private struct StartScene: View {
    var body: some View {
        HelpLoop(count: 4, interval: 1.2) { phase in
            VStack(spacing: 0) {
                FakeMenuBar {
                    Image(systemName: "sparkle")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(5)
                        .background(Circle().fill(Color.accentColor.opacity(phase >= 1 ? 0.25 : 0)))
                        .scaleEffect(phase == 1 ? 1.2 : 1)
                }
                HStack {
                    Spacer()
                    if phase >= 2 {
                        VStack(spacing: 6) {
                            moduleCard(.limits, "34 %")
                            moduleCard(.sessions, "✋ 1")
                            moduleCard(.projects, "6")
                        }
                        .padding(8)
                        .frame(width: 230)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.regularMaterial))
                        .transition(.scale(scale: 0.6, anchor: .topTrailing).combined(with: .opacity))
                    }
                }
                .padding(.trailing, 46)
                .padding(.top, 6)
                Spacer(minLength: 0)
            }
        }
    }
}

/// The real menu bar item, from a few icons to dividers to capsules.
private struct MenuBarScene: View {
    private var frames: [(MenuBarConfig, String)] {
        let minimum = MenuBarConfig.make(.minimum)
        let limits = MenuBarConfig.make(.limits)
        var dividers = limits
        dividers.addDivider(.line, after: .projectsAlert)
        dividers.addDivider(.slash, after: .session)
        var capsules = dividers
        capsules.dividers = []
        capsules.addDivider(.group, after: .projectsAlert)
        capsules.addDivider(.group, after: .week)
        capsules.look = .capsules
        return [(minimum, MenuBarConfig.Preset.minimum.title), (limits, MenuBarConfig.Preset.limits.title),
                (dividers, String(localized: "Разделители")), (capsules, MenuBarConfig.Look.capsules.title)]
    }

    var body: some View {
        HelpLoop(count: 4, interval: 1.6) { phase in
            let frame = frames[phase]
            VStack(spacing: 22) {
                FakeMenuBar {
                    MenuBarItemImage(config: frame.0, data: .sample)
                        .scaleEffect(1.6, anchor: .trailing)
                        .id(phase)
                        .transition(.opacity)
                }
                .padding(.top, 40)
                SceneCaption(text: frame.1)
                Spacer(minLength: 0)
            }
        }
    }
}

/// Blocks of the panel changing places.
private struct PanelScene: View {
    private let orders: [[ModuleKind]] = [
        [.limits, .sessions, .projects, .resources],
        [.sessions, .limits, .projects, .resources],
        [.sessions, .limits, .resources, .projects],
        [.limits, .sessions, .projects, .resources],
    ]

    var body: some View {
        HelpLoop(count: 4, interval: 1.4) { phase in
            VStack(spacing: 6) {
                ForEach(orders[phase], id: \.self) { kind in
                    moduleCard(kind)
                }
            }
            .padding(10)
            .frame(width: 250)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Module tiles switching with the ready-made sets.
private struct ModulesScene: View {
    private let kinds: [ModuleKind] = [.limits, .sessions, .projects, .resources, .keepAwake, .notch]
    private let frames: [ModuleCatalog.Preset] = [.everything, .ai, .mac, .everything]

    var body: some View {
        HelpLoop(count: 4, interval: 1.5) { phase in
            VStack(spacing: 14) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(96), spacing: 10), count: 3), spacing: 10) {
                    ForEach(kinds, id: \.self) { kind in
                        let on = frames[phase].includes(kind)
                        VStack(spacing: 6) {
                            HStack {
                                PaneIcon(pane: .module(kind), size: 26)
                                Spacer()
                                Capsule().fill(on ? Color.accentColor : Color.secondary.opacity(0.35))
                                    .frame(width: 22, height: 13)
                                    .overlay(alignment: on ? .trailing : .leading) { Circle().fill(.white).padding(2) }
                            }
                            Text(kind.title).font(.system(size: 10, weight: .semibold)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.background.opacity(0.9)))
                        .opacity(on ? 1 : 0.4)
                    }
                }
                SceneCaption(text: frames[phase].title)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Session and week rings filling up; past 80 % a notification comes.
private struct LimitsScene: View {
    private let frames: [(Double, Double)] = [(0, 0), (34, 58), (62, 71), (86, 74)]

    var body: some View {
        HelpLoop(count: 4, interval: 1.4) { phase in
            let (session, week) = frames[phase]
            ZStack(alignment: .topTrailing) {
                HStack(spacing: 40) {
                    ring(session, String(localized: "Сессия"))
                    ring(week, String(localized: "Неделя"))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if phase == 3 {
                    HStack(spacing: 8) {
                        Image(systemName: "bell.badge.fill").foregroundStyle(.orange)
                        Text("Сессия").font(.system(size: 11.5, weight: .semibold))
                        Text(verbatim: "86 %").font(.system(size: 11.5)).monospacedDigit()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.regularMaterial))
                    .padding(14)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
    }

    private func ring(_ value: Double, _ title: String) -> some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: value / 100)
                    .stroke(UsageLevel(value).color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(verbatim: "\(Int(value)) %").font(.system(size: 17, weight: .semibold)).monospacedDigit()
                    .contentTransition(.numericText(value: value))
            }
            .frame(width: 92, height: 92)
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
        }
    }
}

/// Sessions working, one asking for permission, «Разрешить» — back to work.
private struct SessionsScene: View {
    private enum State { case running, waiting, done }

    var body: some View {
        HelpLoop(count: 4, interval: 1.4) { phase in
            VStack(spacing: 6) {
                row("Cantero", phase == 1 || phase == 2 ? .waiting : .running, asks: phase == 2)
                row("AIHubBar", .running, asks: false)
                row("site", .done, asks: false)
            }
            .padding(10)
            .frame(width: 330)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func row(_ name: String, _ state: State, asks: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: symbol(state))
                    .foregroundStyle(color(state))
                    .symbolEffect(.pulse, isActive: state == .waiting)
                    .frame(width: 16)
                Text(verbatim: name).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(state == .done ? "✓" : String(localized: "\(12) мин")).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            if asks {
                HStack(spacing: 6) {
                    Spacer()
                    Text("Отклонить").font(.system(size: 11)).padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    Text("Разрешить").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white).padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(Color.accentColor))
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(state == .waiting ? Color.orange.opacity(0.14) : Color.clear))
    }

    private func symbol(_ state: State) -> String {
        switch state {
        case .running: "bolt.fill"
        case .waiting: "hand.raised.fill"
        case .done: "checkmark.circle.fill"
        }
    }

    private func color(_ state: State) -> Color {
        switch state {
        // The panel's own colours (SessionsView): running is blue there.
        case .running: .blue
        case .waiting: .orange
        case .done: .secondary
        }
    }
}

/// AI services found one by one.
private struct ServicesScene: View {
    var body: some View {
        HelpLoop(count: ServiceTab.allCases.count + 2, interval: 0.7) { phase in
            HStack(spacing: 18) {
                ForEach(Array(ServiceTab.allCases.enumerated()), id: \.element) { index, service in
                    VStack(spacing: 8) {
                        PaneIcon(pane: .service(service), size: 44)
                            .overlay(alignment: .bottomTrailing) {
                                if phase > index {
                                    Circle().fill(.green).frame(width: 11, height: 11)
                                        .overlay(Circle().stroke(.background, lineWidth: 2))
                                        .offset(x: 3, y: 3)
                                        .transition(.scale)
                                }
                            }
                            .scaleEffect(phase == index + 1 ? 1.12 : 1)
                        Text(service.title).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                    }
                    .frame(width: 70)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Projects with their health; one opens to show the branch and its PR.
private struct ProjectsScene: View {
    private let projects: [(String, Color)] = [("Cantero", .green), ("AIHubBar", .orange), ("site", .green), ("_daily-report", .red)]

    var body: some View {
        HelpLoop(count: 3, interval: 1.6) { phase in
            VStack(spacing: 5) {
                ForEach(Array(projects.enumerated()), id: \.offset) { index, project in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Circle().fill(project.1).frame(width: 8, height: 8)
                            Text(verbatim: project.0).font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(index == 1 && phase >= 1 ? 90 : 0))
                        }
                        if index == 1, phase >= 1 {
                            HStack(spacing: 6) {
                                chip("arrow.triangle.branch", "feat/help")
                                chip("checkmark.seal.fill", "PR #206", tint: .green)
                                chip("doc", "3")
                            }
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.background.opacity(0.9)))
                }
            }
            .padding(10)
            .frame(width: 300)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func chip(_ symbol: String, _ text: String, tint: Color = .secondary) -> some View {
        Label { Text(verbatim: text) } icon: { Image(systemName: symbol).foregroundStyle(tint) }
            .font(.system(size: 10.5))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
    }
}

/// A week; a deadline dragged to another day, then its reminder.
private struct CalendarScene: View {
    private var days: [String] {
        let symbols = Calendar.current.veryShortWeekdaySymbols
        let first = Calendar.current.firstWeekday - 1
        return (0..<7).map { symbols[(first + $0) % 7] }
    }

    var body: some View {
        HelpLoop(count: 3, interval: 1.5) { phase in
            VStack(spacing: 16) {
                HStack(spacing: 6) {
                    ForEach(0..<7, id: \.self) { day in
                        VStack(spacing: 6) {
                            Text(verbatim: days[day]).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                            ZStack(alignment: .top) {
                                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.background.opacity(0.9)).frame(width: 46, height: 64)
                                if day == (phase == 0 ? 2 : 4) {
                                    RoundedRectangle(cornerRadius: 5).fill(Color.teal.opacity(0.85)).frame(width: 38, height: 16)
                                        .overlay(Image(systemName: "film").font(.system(size: 9)).foregroundStyle(.white))
                                        .padding(.top, 6)
                                        .matchedGeometryEffect(id: "event", in: namespace)
                                }
                            }
                        }
                    }
                }
                HStack(spacing: 8) {
                    Image(systemName: "alarm.fill").foregroundStyle(.teal)
                    Text("Напоминания").font(.system(size: 11.5, weight: .semibold))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(.regularMaterial))
                .opacity(phase == 2 ? 1 : 0)
                .scaleEffect(phase == 2 ? 1 : 0.8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @Namespace private var namespace
}

/// A report being written, then sent to Telegram.
private struct ReportsScene: View {
    private let widths: [CGFloat] = [180, 140, 200, 120, 160]

    var body: some View {
        HelpLoop(count: widths.count + 2, interval: 0.6) { phase in
            HStack(spacing: 28) {
                VStack(alignment: .leading, spacing: 7) {
                    Image(systemName: "doc.text.magnifyingglass").font(.system(size: 18)).foregroundStyle(.teal)
                    ForEach(0..<widths.count, id: \.self) { line in
                        Capsule().fill(Color.secondary.opacity(0.35)).frame(width: phase > line ? widths[line] : 0, height: 7)
                    }
                }
                .padding(14)
                .frame(width: 230, height: 150, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.background.opacity(0.9)))
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.blue)
                    .offset(x: phase >= widths.count ? 0 : -40, y: phase >= widths.count ? 0 : 20)
                    .opacity(phase >= widths.count ? 1 : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The notch grows ears, opens its card, shows a request.
private struct NotchScene: View {
    var body: some View {
        HelpLoop(count: 4, interval: 1.4) { phase in
            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    UnevenRoundedRectangle(bottomLeadingRadius: phase >= 2 ? 22 : 12, bottomTrailingRadius: phase >= 2 ? 22 : 12)
                        .fill(.black)
                        .frame(width: phase >= 2 ? 330 : (phase >= 1 ? 250 : 150), height: phase >= 2 ? 128 : 30)
                    HStack {
                        Text(verbatim: "34%").foregroundStyle(.green)
                        Spacer()
                        Label { Text(verbatim: "2") } icon: { Image(systemName: "hand.raised.fill") }.foregroundStyle(.orange)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: phase >= 2 ? 300 : 222, height: 30)
                    .opacity(phase >= 1 ? 1 : 0)
                    if phase >= 2 {
                        VStack(spacing: 8) {
                            if phase == 3 {
                                HStack(spacing: 6) {
                                    Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                                    Text(verbatim: "Cantero · Bash").foregroundStyle(.white)
                                    Spacer()
                                    Text("Разрешить").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                                        .padding(.horizontal, 9).padding(.vertical, 3).background(Capsule().fill(Color.accentColor))
                                }
                            } else {
                                bar(34, String(localized: "Сессия"))
                                bar(58, String(localized: "Неделя"))
                            }
                        }
                        .font(.system(size: 11))
                        .frame(width: 290)
                        .padding(.top, 44)
                        .transition(.opacity)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func bar(_ value: Double, _ title: String) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(.white.opacity(0.8)).frame(width: 64, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18))
                    Capsule().fill(UsageLevel(value).color).frame(width: geometry.size.width * value / 100)
                }
            }
            .frame(height: 6)
            Text(verbatim: "\(Int(value)) %").foregroundStyle(.white).monospacedDigit()
        }
    }
}

/// «ghbdtn» typed in the wrong layout turns into «привет», the layout switches.
private struct LayoutScene: View {
    private let typed = Array("ghbdtn")

    var body: some View {
        HelpLoop(count: typed.count + 3, interval: 0.45) { phase in
            let fixed = phase > typed.count
            VStack(spacing: 18) {
                HStack(spacing: 0) {
                    Text(verbatim: fixed ? "привет" : String(typed.prefix(phase)))
                        .font(.system(size: 26, weight: .medium, design: .rounded))
                        .foregroundStyle(fixed ? Color.accentColor : .primary)
                        .contentTransition(.interpolate)
                    Rectangle().fill(Color.accentColor).frame(width: 2, height: 30).opacity(phase % 2 == 0 ? 1 : 0.3)
                }
                .padding(.horizontal, 18)
                .frame(width: 280, height: 56, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.background.opacity(0.9)))
                Text(verbatim: fixed ? "RU" : "EN")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(lineWidth: 1.5))
                    .foregroundStyle(fixed ? Color.orange : .secondary)
                    .scaleEffect(fixed ? 1.15 : 1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Quick toggles switching on, the CPU gauge moving.
private struct UtilitiesScene: View {
    private let symbols = ["moon.fill", "lock.fill", "cup.and.saucer.fill", "doc.on.clipboard.fill"]
    private let cpu: [Double] = [18, 46, 72, 31, 24]

    var body: some View {
        HelpLoop(count: symbols.count + 1, interval: 0.9) { phase in
            VStack(spacing: 20) {
                HStack(spacing: 12) {
                    ForEach(Array(symbols.enumerated()), id: \.offset) { index, symbol in
                        let on = phase > index
                        Image(systemName: symbol)
                            .font(.system(size: 20))
                            .foregroundStyle(on ? .white : .secondary)
                            .frame(width: 52, height: 52)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(on ? Color.orange : Color.secondary.opacity(0.15)))
                            .scaleEffect(phase == index + 1 ? 1.1 : 1)
                    }
                }
                HStack(spacing: 8) {
                    Image(systemName: "cpu").foregroundStyle(.orange)
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.2))
                            Capsule().fill(UsageLevel(cpu[phase]).color).frame(width: geometry.size.width * cpu[phase] / 100)
                        }
                    }
                    .frame(width: 180, height: 7)
                    Text(verbatim: "\(Int(cpu[phase])) %").font(.system(size: 12, weight: .medium)).monospacedDigit().frame(width: 40, alignment: .trailing)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// A notification slides in, then the same in Telegram.
private struct AlertsScene: View {
    var body: some View {
        HelpLoop(count: 3, interval: 1.6) { phase in
            ZStack {
                if phase >= 1 {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "sparkle").font(.system(size: 16, weight: .semibold)).frame(width: 30, height: 30)
                            .background(RoundedRectangle(cornerRadius: 7).fill(.orange.gradient)).foregroundStyle(.white)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: "AI Hub Bar").font(.system(size: 11.5, weight: .semibold))
                            Text(NotificationKind.waiting.title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .padding(10)
                    .frame(width: 280, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial))
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(16)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                if phase >= 2 {
                    HStack(spacing: 8) {
                        Image(systemName: "paperplane.fill").foregroundStyle(.white).frame(width: 26, height: 26).background(Circle().fill(.blue))
                        Text(NotificationKind.waiting.title).font(.system(size: 11))
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.blue.opacity(0.14)))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }
}

/// A command typed in Terminal and its answer.
private struct TerminalScene: View {
    private let command = Array("AIHubBar --sessions")
    private let output = ["● Cantero    running   12 min", "✋ AIHubBar  waiting    3 min", "✓ site       done"]

    var body: some View {
        HelpLoop(count: 6, interval: 0.8) { phase in
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.8)).frame(width: 9, height: 9) }
                }
                .padding(.bottom, 6)
                Text(verbatim: "$ " + String(command.prefix(min(command.count, phase * 7))))
                    .foregroundStyle(.green)
                ForEach(Array(output.enumerated()), id: \.offset) { index, line in
                    Text(verbatim: line).foregroundStyle(.white.opacity(0.85)).opacity(phase > index + 2 ? 1 : 0)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 12, design: .monospaced))
            .padding(14)
            .frame(width: 340, height: 150, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.85)))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
