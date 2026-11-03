import SwiftUI

/// The island's content (docs/specs/SPEC-notch.md §3): the ears beside the notch at rest, the card under it when open.
/// Always black like the notch itself, with light text, in either appearance (SPEC-notch §7). One per screen:
/// `index` is its place in `NotchIsland.places`.
struct NotchIslandView: View {
    let index: Int

    @Environment(NotchIsland.self) private var island
    @Environment(AppSettings.self) private var settings
    @Environment(UsageStore.self) private var usage
    @Environment(SessionStore.self) private var sessions
    @Environment(RunStore.self) private var runs
    @Environment(HubLimitsStore.self) private var hub
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if island.places.indices.contains(index) {
            let geometry = island.places[index].geometry
            let window = geometry.windowFrame
            let open = island.openIndex == index
            let dropping = island.dropTarget == index
            let banner = dropping ? nil : island.banner(on: index)
            let wide = open || banner != nil || dropping
            let earsShown = island.showsSummary(on: index) && (hasEar(settings.notch.leftEar) || hasEar(settings.notch.rightEar))
            let restWidth = earsShown ? geometry.restFrame.width : geometry.notch.width
            // At rest the island is centred on the notch; open or with a banner, it fills the window.
            let restOffset = geometry.notch.midX - window.midX
            let height = open ? island.cardHeight : dropping ? NotchIsland.dropHeight : banner != nil ? island.bannerHeight : 0

            ZStack(alignment: .top) {
                // The pill hangs under the menu bar on its own: rounded all round, nothing at rest.
                IslandShape(isPill: geometry.isPill, bottomRadius: wide ? 18 : 9)
                    .fill(.black)
                    .overlay {
                        if wide, contrast == .increased || geometry.isPill {
                            IslandShape(isPill: geometry.isPill, bottomRadius: 18).stroke(.white.opacity(geometry.isPill && contrast != .increased ? 0.15 : 0.5), lineWidth: 1)
                        }
                    }
                    .frame(width: wide ? window.width : restWidth, height: geometry.notch.height + height)
                    .offset(x: wide ? 0 : restOffset)

                if open {
                    Group {
                        if let dropped = island.dropped { NotchDropCard(url: dropped) } else { NotchCard() }
                    }
                    .modifier(MeasuredUnderNotch(notchHeight: geometry.notch.height, width: window.width))
                    .transition(.opacity)
                } else if dropping {
                    Label("Отпустите — AI-команды для файла", systemImage: "sparkles")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white)
                        .frame(width: window.width, height: NotchIsland.dropHeight)
                        .padding(.top, geometry.notch.height)
                        .transition(.opacity)
                } else if let banner {
                    NotchBanner(event: banner)
                        .id(banner.id)
                        .modifier(MeasuredUnderNotch(notchHeight: geometry.notch.height, width: window.width))
                        .transition(.opacity)
                } else if earsShown {
                    HStack(spacing: 0) {
                        NotchEarView(ear: settings.notch.leftEar)
                            .frame(width: NotchGeometry.earWidth)
                        Color.clear.frame(width: geometry.notch.width)
                        NotchEarView(ear: settings.notch.rightEar)
                            .frame(width: NotchGeometry.earWidth)
                    }
                    .frame(height: geometry.notch.height)
                    .offset(x: restOffset)
                    .transition(.opacity)
                }
            }
            .frame(width: window.width, height: window.height, alignment: .top)
            .environment(\.colorScheme, .dark)
            .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.35, dampingFraction: 0.78), value: open)
            .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.35, dampingFraction: 0.8), value: banner?.id)
            .animation(.easeInOut(duration: 0.2), value: height)
            .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.8), value: dropping)
            .onPreferenceChange(ContentHeightKey.self) { measured in
                guard measured > 0 else { return }
                if open {
                    if abs(measured - island.cardHeight) > 0.5 { island.cardHeight = measured }
                } else if banner != nil, abs(measured - island.bannerHeight) > 0.5 {
                    island.bannerHeight = measured
                }
            }
        }
    }

    private func hasEar(_ ear: NotchEar) -> Bool {
        switch ear {
        case .sessionLimit: usage.snapshot?.session != nil
        case .weekLimit: usage.snapshot?.week != nil
        case .otherAI: NotchText.fullestOther(hub.percents) != nil
        case .sessions: sessions.items.contains { $0.state == .waiting || $0.state == .running }
        case .background: !runs.running.isEmpty
        case .none: false
        }
    }
}

/// Content under the notch, as wide as the window, reporting how tall it is so the black shape can follow.
private struct MeasuredUnderNotch: ViewModifier {
    let notchHeight: CGFloat
    let width: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(.top, notchHeight)
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height - notchHeight)
            })
    }
}

/// One ear at rest (SPEC-notch §3.1): a small ring for a limit, a dot and a count for sessions or background runs.
/// With the live activity (§3.4) a working session's task list shows as a ring and «3/7», or — without a list —
/// the minutes since its request.
private struct NotchEarView: View {
    let ear: NotchEar
    @Environment(UsageStore.self) private var usage
    @Environment(SessionStore.self) private var sessions
    @Environment(RunStore.self) private var runs
    @Environment(HubLimitsStore.self) private var hub
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch ear {
            case .sessionLimit: limit(usage.snapshot?.session?.utilization)
            case .weekLimit: limit(usage.snapshot?.week?.utilization)
            case .otherAI: limit(NotchText.fullestOther(hub.percents)?.percent)
            case .sessions: sessionDot
            case .background:
                if !runs.running.isEmpty { dot(.purple, count: runs.running.count) }
            case .none: EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .help(summary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary)
    }

    private var summary: String {
        NotchText.earSummary(ear, usage: usage.snapshot, sessions: sessions.items, background: runs.running.count, otherAI: hub.percents,
                             liveActivity: settings.notch.liveActivity)
    }

    @ViewBuilder
    private func limit(_ percent: Double?) -> some View {
        if let percent {
            let color = UsageWindow.color(for: percent)
            HStack(spacing: 3) {
                ZStack {
                    Circle().stroke(.white.opacity(0.2), lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: min(max(percent, 0), 100) / 100)
                        .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 13, height: 13)
                // Near the limit the number matters more than the ring.
                if percent >= 80 {
                    Text("\(Int(percent.rounded()))")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(color)
                }
            }
        }
    }

    @ViewBuilder
    private var sessionDot: some View {
        let waiting = sessions.items.filter { $0.state == .waiting }.count
        let running = sessions.items.filter { $0.state == .running }.count
        let featured = settings.notch.liveActivity ? NotchText.featured(sessions.items) : nil
        if waiting > 0 {
            dot(Session.State.waiting.color, count: waiting + running)
        } else if let progress = featured?.session.progress {
            progressRing(progress)
        } else if running == 1, let start = featured?.session.promptAt {
            TimelineView(.everyMinute) { context in
                // The schedule's dates are minute boundaries, the first one before now.
                minutesDot(NotchText.minutes(from: start, to: max(context.date, .now)))
            }
        } else if running > 0 {
            dot(Session.State.running.color, count: running)
        }
    }

    /// «3/7» beside a ring that fills as steps get done.
    private func progressRing(_ progress: (done: Int, total: Int)) -> some View {
        let color = Session.State.running.color
        return HStack(spacing: 3) {
            ZStack {
                Circle().stroke(.white.opacity(0.2), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: CGFloat(progress.done) / CGFloat(max(progress.total, 1)))
                    .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 11, height: 11)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: progress.done)
            Text("\(progress.done)/\(progress.total)")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    /// The «working» dot and «4′»: minutes since the request, when there is no task list to show.
    private func minutesDot(_ minutes: Int) -> some View {
        HStack(spacing: 3) {
            Circle().fill(Session.State.running.color).frame(width: 7, height: 7)
            if minutes > 0 {
                Text("\(minutes)′")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }

    private func dot(_ color: Color, count: Int) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 7, height: 7)
            if count > 1 {
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
    }
}

/// The open card (SPEC-notch §3.3): both limits with the forecast, then up to four sessions and what each is doing.
private struct NotchCard: View {
    @Environment(NotchIsland.self) private var island
    @Environment(UsageStore.self) private var usage
    @Environment(SessionStore.self) private var sessions
    @Environment(RunStore.self) private var runs
    @Environment(AppSettings.self) private var settings

    static let sessionLimit = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !island.requests.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(island.requests) { request in NotchRequestView(event: request) }
                }
                Divider().overlay(.white.opacity(0.15))
            }
            if usage.snapshot?.session != nil || usage.snapshot?.week != nil {
                HStack(spacing: 14) {
                    if let session = usage.snapshot?.session { ring(session) }
                    if let week = usage.snapshot?.week { ring(week) }
                    Spacer(minLength: 0)
                }
                if let forecast = UsageText.forecast(usage.forecast) {
                    Text(forecast)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Divider().overlay(.white.opacity(0.15))
            }
            let shown = Array(sessions.items.prefix(Self.sessionLimit))
            if shown.isEmpty {
                Text("Сессий Claude Code сейчас нет")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                let live = settings.notch.liveActivity
                let featured = live ? NotchText.featured(sessions.items)?.id : nil
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(shown) { item in
                        NotchSessionRow(item: item, showsTime: live)
                        if item.id == featured, !item.session.todos.isEmpty {
                            NotchSteps(todos: item.session.todos)
                        }
                    }
                }
            }
            HStack {
                if sessions.items.count > shown.count {
                    Text("Ещё \(sessions.items.count - shown.count) — в панели ✦")
                } else if !runs.running.isEmpty {
                    Text("Фоновых задач: \(runs.running.count)")
                }
                Spacer()
                Button("Поиск и запуск…") { QuickSearch.show() }
                    .buttonStyle(.borderless)
                    .help("Окно поиска: проекты, команды, сессии")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Остров у чёлки"))
    }

    private func ring(_ window: UsageWindow) -> some View {
        HStack(spacing: 7) {
            ZStack {
                Circle().stroke(.white.opacity(0.18), lineWidth: 3.5)
                Circle()
                    .trim(from: 0, to: min(max(window.utilization, 0), 100) / 100)
                    .stroke(window.levelColor, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text(UsageText.percent(window.utilization))
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(window.levelColor)
                Text(window.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A banner (SPEC-notch §3.2): a request with its buttons, or one line for anything else; a click leads where the
/// notification would.
private struct NotchBanner: View {
    let event: NotchEvent
    @Environment(NotchIsland.self) private var island

    var body: some View {
        Group {
            if event.kind == .request {
                NotchRequestView(event: event)
            } else {
                Button { island.openTarget(of: event) } label: {
                    HStack(spacing: 9) {
                        Image(systemName: event.kind.symbol)
                            .foregroundStyle(event.kind == .waiting ? Session.State.waiting.color
                                : event.kind == .done ? Session.State.done.color : .white.opacity(0.8))
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(event.title)
                                .fontWeight(.medium)
                                .lineLimit(1)
                            if !event.body.isEmpty {
                                Text(event.body)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.callout)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help([event.title, event.body].filter { !$0.isEmpty }.joined(separator: "\n"))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(event.kind.title)
    }
}

/// A permission Claude asked for (SPEC-notch §4): project and tool, the command, and the answers. The answers wake
/// up only after the guard allows (`NotchIsland.armed`).
private struct NotchRequestView: View {
    let event: NotchEvent
    @Environment(NotchIsland.self) private var island

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: NotchEventKind.request.symbol)
                    .foregroundStyle(Session.State.waiting.color)
                Text(event.title)
                    .fontWeight(.medium)
                    .lineLimit(1)
            }
            .font(.callout)
            if !event.body.isEmpty {
                Text(event.body)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .help(event.body)
            }
            HStack(spacing: 8) {
                Group {
                    Button("Разрешить") { island.answer(event, allow: true) }
                        .buttonStyle(NotchButtonStyle(fill: .green))
                    Button("Отклонить") { island.answer(event, allow: false) }
                        .buttonStyle(NotchButtonStyle(fill: .white.opacity(0.18)))
                }
                .disabled(!island.armed)
                Spacer()
                Button("Открыть") { island.openTarget(of: event) }
                    .buttonStyle(.borderless)
                    .help("Перейти к сессии")
            }
            .controlSize(.small)
        }
        .accessibilityElement(children: .contain)
        .onAppear {
            AccessibilityNotification.Announcement(String(localized: "Claude просит разрешение: \(event.title)")).post()
        }
    }
}

/// The island's window never becomes key, and AppKit draws key-window button styles grey there; these keep their colour.
private struct NotchButtonStyle: ButtonStyle {
    let fill: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(fill.opacity(configuration.isPressed ? 0.7 : 1), in: Capsule())
            .foregroundStyle(.white)
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Capsule())
    }
}

private struct NotchSessionRow: View {
    let item: SessionStore.Item
    /// Minutes since the request while it works (SPEC-notch §3.4).
    var showsTime = false

    var body: some View {
        Button { SessionActions.show(item.session) } label: {
            HStack(spacing: 7) {
                Image(systemName: item.state.symbol)
                    .foregroundStyle(item.state.color)
                    .frame(width: 14)
                Text(item.session.displayProject)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(item.session.actionText ?? item.state.title)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if showsTime, item.state == .running, let start = item.session.promptAt {
                    TimelineView(.everyMinute) { context in
                        Text(DurationText.short(from: start, to: max(context.date, .now)))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            .font(.callout)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(NotchText.sessionHelp(item))
    }
}

/// A working session's task list in the card (SPEC-notch §3.4): ✓ done, ● in progress, ○ ahead; up to seven,
/// chosen so the step in progress shows, then «ещё N».
private struct NotchSteps: View {
    let todos: [SessionTodo]

    var body: some View {
        let range = NotchText.visibleSteps(todos)
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(todos[range].enumerated()), id: \.offset) { _, todo in
                HStack(spacing: 6) {
                    Image(systemName: symbol(todo.status))
                        .font(.system(size: todo.status == .inProgress ? 7 : 9, weight: .semibold))
                        .foregroundStyle(todo.status == .inProgress ? Session.State.running.color : .secondary)
                        .frame(width: 12)
                    Text(todo.text)
                        .foregroundStyle(todo.status == .pending ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(NotchText.stepLabel(todo))
            }
            if todos.count > range.count {
                Text("ещё \(todos.count - range.count)")
                    .foregroundStyle(.secondary)
                    .padding(.leading, 18)
            }
        }
        .font(.caption)
        .padding(.leading, 21)
    }

    private func symbol(_ status: SessionTodo.Status) -> String {
        switch status {
        case .completed: "checkmark"
        case .inProgress: "circle.fill"
        case .pending: "circle"
        }
    }
}

/// A file or folder dropped on the island (SPEC-notch §9, stage 5): the current profile's AI commands and «Своя
/// задача» for it, run by the profile's service the way a folder project's commands are; the result is a new file
/// next to it.
private struct NotchDropCard: View {
    let url: URL
    @Environment(NotchIsland.self) private var island
    @Environment(ProfileStore.self) private var modes
    @Environment(CommandEngine.self) private var engine
    @Environment(AppSettings.self) private var settings
    @State private var asking: CommandTemplate?
    @State private var text = ""
    @FocusState private var focused: Bool

    private var mode: Profile { modes.current ?? Profile(name: String(localized: "Профиль")) }
    private var project: FolderProject { .dropped(url) }

    private func service(for command: CommandTemplate) -> AIService {
        (command.service ?? mode.service).flatMap(AIService.init(id:)) ?? .claudeCode
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 30, height: 30)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(PathText.tilde(url.deletingLastPathComponent().path))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 0)
                Button("Отмена") { island.close() }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
            }
            Text("Команды профиля «\(mode.name)» · \(service(for: .customTask).shortName(compatibleName: settings.aiServices.compatibleName))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            FlowLayout(spacing: 6) {
                ForEach(mode.commands + [.customTask]) { command in
                    Button(command.title) { start(command) }
                        .buttonStyle(NotchButtonStyle(fill: asking == command ? .accentColor : .white.opacity(0.16)))
                        .help(command.hint)
                }
            }
            if let asking {
                HStack(spacing: 6) {
                    TextField(asking.asks ?? String(localized: "Текст"), text: $text)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused)
                        .onSubmit { perform(asking) }
                    Button("Выполнить") { perform(asking) }
                        .buttonStyle(NotchButtonStyle(fill: .accentColor))
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Text("Результат — новый файл рядом; существующие файлы не меняются.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "AI-команды для \(url.lastPathComponent)"))
    }

    private func start(_ command: CommandTemplate) {
        if command.asks != nil {
            asking = command
            text = ""
            focused = true
        } else {
            perform(command)
        }
    }

    private func perform(_ command: CommandTemplate) {
        let input = command.asks == nil ? nil : text
        if command.asks != nil, input?.trimmingCharacters(in: .whitespaces).isEmpty != false { return }
        let result = engine.run(command, project: project, mode: mode, service: service(for: command), text: input)
        island.started(command.title, file: "\(url.lastPathComponent) → \((result as NSString).lastPathComponent)")
    }
}
