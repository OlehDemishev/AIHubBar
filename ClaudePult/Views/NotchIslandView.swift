import SwiftUI

/// The island's content (docs/SPEC-notch.md §3): the ears beside the notch at rest, the card under it when open.
/// Always black like the notch itself, with light text, in either appearance (SPEC-notch §7).
struct NotchIslandView: View {
    @Environment(NotchIsland.self) private var island
    @Environment(AppSettings.self) private var settings
    @Environment(UsageStore.self) private var usage
    @Environment(SessionStore.self) private var sessions
    @Environment(RunStore.self) private var runs
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if let geometry = island.geometry {
            let window = geometry.windowFrame
            let open = island.isOpen
            let banner = island.banner
            let wide = open || banner != nil
            let earsShown = hasEar(settings.notch.leftEar) || hasEar(settings.notch.rightEar)
            let restWidth = earsShown ? geometry.restFrame.width : geometry.notch.width
            // At rest the island is centred on the notch; open or with a banner, it fills the window.
            let restOffset = geometry.notch.midX - window.midX
            let height = open ? island.cardHeight : banner != nil ? island.bannerHeight : 0

            ZStack(alignment: .top) {
                NotchShape(bottomRadius: wide ? 18 : 9)
                    .fill(.black)
                    .overlay {
                        if wide, contrast == .increased {
                            NotchShape(bottomRadius: 18).stroke(.white.opacity(0.5), lineWidth: 1)
                        }
                    }
                    .frame(width: wide ? window.width : restWidth, height: geometry.notch.height + height)
                    .offset(x: wide ? 0 : restOffset)

                if open {
                    NotchCard()
                        .modifier(MeasuredUnderNotch(notchHeight: geometry.notch.height, width: window.width))
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
        case .sessions: sessions.items.contains { $0.state == .waiting || $0.state == .running }
        case .background: !runs.running.isEmpty
        case .none: false
        }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
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

/// The notch's own outline: flat top that flares into the menu bar, rounded bottom corners.
struct NotchShape: Shape {
    var bottomRadius: CGFloat
    var topRadius: CGFloat = 6

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let top = min(topRadius, rect.width / 4)
        let bottom = min(bottomRadius, rect.height / 2, (rect.width - 2 * top) / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + top, y: rect.minY + top), control: CGPoint(x: rect.minX + top, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
        path.addQuadCurve(to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY), control: CGPoint(x: rect.minX + top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom), control: CGPoint(x: rect.maxX - top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - top, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// One ear at rest (SPEC-notch §3.1): a small ring for a limit, a dot and a count for sessions or background runs.
private struct NotchEarView: View {
    let ear: NotchEar
    @Environment(UsageStore.self) private var usage
    @Environment(SessionStore.self) private var sessions
    @Environment(RunStore.self) private var runs

    var body: some View {
        Group {
            switch ear {
            case .sessionLimit: limit(usage.snapshot?.session)
            case .weekLimit: limit(usage.snapshot?.week)
            case .sessions: sessionDot
            case .background:
                if !runs.running.isEmpty { dot(.purple, count: runs.running.count) }
            case .none: EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .help(NotchText.earSummary(ear, usage: usage.snapshot, sessions: sessions.items, background: runs.running.count))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(NotchText.earSummary(ear, usage: usage.snapshot, sessions: sessions.items, background: runs.running.count))
    }

    @ViewBuilder
    private func limit(_ window: UsageWindow?) -> some View {
        if let window {
            HStack(spacing: 3) {
                ZStack {
                    Circle().stroke(.white.opacity(0.2), lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: min(max(window.utilization, 0), 100) / 100)
                        .stroke(window.levelColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 13, height: 13)
                // Near the limit the number matters more than the ring.
                if window.utilization >= 80 {
                    Text("\(Int(window.utilization.rounded()))")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(window.levelColor)
                }
            }
        }
    }

    @ViewBuilder
    private var sessionDot: some View {
        let waiting = sessions.items.filter { $0.state == .waiting }.count
        let running = sessions.items.filter { $0.state == .running }.count
        if waiting > 0 {
            dot(Session.State.waiting.color, count: waiting + running)
        } else if running > 0 {
            dot(Session.State.running.color, count: running)
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
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(shown) { item in NotchSessionRow(item: item) }
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
            }
            .font(.callout)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(NotchText.sessionHelp(item))
    }
}

/// Words for the ears' hints and VoiceOver.
enum NotchText {
    static func earSummary(_ ear: NotchEar, usage: UsageSnapshot?, sessions: [SessionStore.Item], background: Int) -> String {
        switch ear {
        case .sessionLimit, .weekLimit:
            guard let window = ear == .sessionLimit ? usage?.session : usage?.week else { return ear.title }
            return "\(window.title): \(UsageText.percent(window.utilization))"
        case .sessions:
            let waiting = sessions.filter { $0.state == .waiting }.count
            let running = sessions.filter { $0.state == .running }.count
            return String(localized: "Ждут ответа: \(waiting), работают: \(running)")
        case .background:
            return String(localized: "Фоновых задач: \(background)")
        case .none:
            return ""
        }
    }

    static func sessionHelp(_ item: SessionStore.Item) -> String {
        [item.session.displayProject, item.state.title, item.session.actionText].compactMap { $0 }.joined(separator: " · ")
    }
}
