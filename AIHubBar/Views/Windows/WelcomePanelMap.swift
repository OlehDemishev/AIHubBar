import SwiftUI

/// The right side of the assistant: the map of the panel on its first screen, the live preview after that.
struct AssistantSidePane: View {
    let draft: AssistantDraft
    var animated = true

    var body: some View {
        if draft.step == .welcome {
            WelcomePanelMap(menuBar: draft.menuBar, animated: animated)
        } else {
            AssistantPreview(draft: draft)
        }
    }
}

/// What a new person sees first (SPEC-modes §9.8): the panel on sample data, with arrows from short notes to what
/// matters. The arrows follow the pieces' real positions, so longer languages and right-to-left text keep them right.
struct WelcomePanelMap: View {
    let menuBar: MenuBarConfig
    private let animated: Bool
    @State private var shown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(menuBar: MenuBarConfig, animated: Bool = true) {
        self.menuBar = menuBar
        self.animated = animated
        _shown = State(initialValue: !animated)
    }

    fileprivate enum Spot: Int, CaseIterable, Identifiable {
        case menuBar, limits, sessions, answer, modules

        var id: Int { rawValue }

        var note: String {
            switch self {
            case .menuBar: String(localized: "Панель открывается из строки меню")
            case .limits: String(localized: "Лимиты Claude и прогноз по вашему темпу")
            case .sessions: String(localized: "Все сессии агентов и что они делают")
            case .answer: String(localized: "Запрос разрешения: ответьте прямо отсюда")
            case .modules: String(localized: "Остальное — модули: включите только нужное")
            }
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            notes
            VStack(alignment: .trailing, spacing: 10) {
                menuBarItem
                panel
            }
            .accessibilityHidden(true)
        }
        // The notes spread over the panel's height, each near what it points at.
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlayPreferenceValue(SpotAnchors.self) { anchors in
            GeometryReader { proxy in
                ForEach(Spot.allCases) { spot in
                    if let note = anchors[.note(spot)], let target = anchors[.target(spot)] {
                        arrow(from: proxy[note], to: proxy[target], spot: spot)
                    }
                }
            }
            // Anchors come measured from the leading edge, but a drawn path stays left to right.
            .flipsForRightToLeftLayoutDirection(true)
            .accessibilityHidden(true)
        }
        .onAppear {
            guard animated, !shown else { return }
            if reduceMotion { shown = true } else { withAnimation { shown = true } }
        }
    }

    // MARK: - Notes

    private var notes: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Spot.allCases) { spot in
                Text(spot.note)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .anchorPreference(key: SpotAnchors.self, value: .bounds) { [.note(spot): $0] }
                    .opacity(shown ? 1 : 0)
                    .animation(entrance(spot), value: shown)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if spot != Spot.allCases.last { Spacer(minLength: 12) }
            }
        }
        .frame(width: 164, alignment: .topLeading)
    }

    /// The note, then its arrow; one after another, top to bottom. Seen once, so it can take half a second.
    private func entrance(_ spot: Spot, afterNote: Bool = false) -> Animation? {
        guard !reduceMotion else { return nil }
        return .easeOut(duration: 0.35).delay(Double(spot.rawValue) * 0.09 + (afterNote ? 0.12 : 0))
    }

    // MARK: - Arrows

    private func arrow(from note: CGRect, to target: CGRect, spot: Spot) -> some View {
        // Whichever side the notes are on: the arrow leaves the note's near edge for the target's near edge.
        let rightward = note.midX < target.midX
        let start = CGPoint(x: rightward ? note.maxX + 4 : note.minX - 4, y: note.minY + 9)
        let end = CGPoint(x: rightward ? target.minX - 3 : target.maxX + 3, y: target.midY)
        let curve = ArrowCurve(start: start, end: end)
        return ZStack {
            curve
                .trim(from: 0, to: shown ? 1 : 0)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.25, lineCap: .round))
            ArrowHead(tip: end, pointsRight: rightward)
                .fill(Color.accentColor)
                .opacity(shown ? 1 : 0)
        }
        .animation(entrance(spot, afterNote: true), value: shown)
    }

    // MARK: - The panel on sample data

    private var menuBarItem: some View {
        MenuBarItemImage(config: menuBar, data: .sample)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))
            .anchorPreference(key: SpotAnchors.self, value: .bounds) { [.target(.menuBar): $0] }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 8) {
            card { limits }
                .anchorPreference(key: SpotAnchors.self, value: .bounds) { [.target(.limits): $0] }
            card {
                VStack(alignment: .leading, spacing: 10) {
                    session(name: "my-app", state: String(localized: "работает"), detail: "npm test", color: Session.State.running.color)
                        .anchorPreference(key: SpotAnchors.self, value: .bounds) { [.target(.sessions): $0] }
                    session(name: "website", state: String(localized: "ждёт ответа"), detail: "git push", color: Session.State.waiting.color)
                    answerButtons
                        .anchorPreference(key: SpotAnchors.self, value: .bounds) { [.target(.answer): $0] }
                        .padding(.leading, 13)
                }
            }
            card { modules }
                .anchorPreference(key: SpotAnchors.self, value: .bounds) { [.target(.modules): $0] }
        }
        .font(.caption)
        .padding(8)
        .frame(width: 216, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background).shadow(color: .black.opacity(0.15), radius: 8, y: 3))
    }

    private func card(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private var limits: some View {
        VStack(alignment: .leading, spacing: 6) {
            limit(String(localized: "Сессия"), 34)
            limit(String(localized: "Неделя"), 58)
            Text("при текущем темпе хватит до ~\("16:40")")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func limit(_ title: String, _ value: Double) -> some View {
        HStack {
            Text(title).lineLimit(1)
            Spacer(minLength: 6)
            MiniRing(value: value)
        }
    }

    private func session(name: String, state: String, detail: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(verbatim: name).fontWeight(.medium).lineLimit(1)
                Spacer(minLength: 6)
                Text(state).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.8)
            }
            Text(verbatim: detail).font(.caption2.monospaced()).foregroundStyle(.secondary).padding(.leading, 13)
        }
    }

    private var answerButtons: some View {
        HStack(spacing: 6) {
            Text("Разрешить")
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color.accentColor))
            Text("Отклонить")
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(0.1)))
        }
        .font(.caption2.weight(.medium))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private var modules: some View {
        HStack(spacing: 0) {
            ForEach(["doc.on.clipboard", "note.text", "cup.and.saucer", "gauge.with.dots.needle.33percent", "keyboard", "paperplane"], id: \.self) { symbol in
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

/// Where each note and each thing it points at is.
private struct SpotAnchors: PreferenceKey {
    enum Key: Hashable {
        case note(WelcomePanelMap.Spot)
        case target(WelcomePanelMap.Spot)
    }

    static let defaultValue: [Key: Anchor<CGRect>] = [:]

    static func reduce(value: inout [Key: Anchor<CGRect>], nextValue: () -> [Key: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Leaves and arrives horizontally, so it reads as a line from the note to the thing and never crosses the text.
private struct ArrowCurve: Shape {
    let start: CGPoint
    let end: CGPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let reach = (end.x - start.x) * 0.55
        path.move(to: start)
        path.addCurve(to: end, control1: CGPoint(x: start.x + reach, y: start.y), control2: CGPoint(x: end.x - reach, y: end.y))
        return path
    }
}

private struct ArrowHead: Shape {
    let tip: CGPoint
    let pointsRight: Bool

    func path(in rect: CGRect) -> Path {
        let back = pointsRight ? -6.0 : 6.0
        var path = Path()
        path.move(to: tip)
        path.addLine(to: CGPoint(x: tip.x + back, y: tip.y - 3.2))
        path.addLine(to: CGPoint(x: tip.x + back, y: tip.y + 3.2))
        path.closeSubpath()
        return path
    }
}
