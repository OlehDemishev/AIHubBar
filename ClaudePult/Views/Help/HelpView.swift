import AppKit
import SwiftUI

/// The «Справка» window (docs/SPEC-help.md): topics in a sidebar with search, each a page with a moving picture, the
/// steps to set it up, what it can do, and a way into its settings.
struct HelpView: View {
    @AppStorage(StorageKey.helpTopic) private var topic: HelpTopic = .start
    @State private var query = ""

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { topic }, set: { if let new = $0 { topic = new } })) {
                ForEach(HelpTopic.groups, id: \.title) { group in
                    let found = group.topics.filter { $0.matches(query) }
                    if !found.isEmpty {
                        Section(group.title) {
                            ForEach(found) { topic in
                                HelpTopicRow(topic: topic)
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .sidebar, prompt: Text("Поиск по справке"))
            .navigationSplitViewColumnWidth(min: 210, ideal: 230)
            .safeAreaInset(edge: .bottom) { FeedbackFooter() }
            .onChange(of: query) {
                // The first match opens as you type, so search reads like «go to».
                if !topic.matches(query), let first = HelpTopic.allCases.first(where: { $0.matches(query) }) { topic = first }
            }
        } detail: {
            HelpPage(topic: topic, query: query)
                .id(topic)
                .navigationTitle(topic.title)
        }
        .frame(minWidth: 820, idealWidth: 960, minHeight: 600, idealHeight: 720)
    }
}

private struct HelpTopicRow: View {
    let topic: HelpTopic

    var body: some View {
        HStack(spacing: 9) {
            IconTile(symbol: topic.symbol, tint: topic.tint, size: 22)
            Text(topic.title).font(.system(size: 13.5)).lineLimit(1)
            if topic.isBeta { BetaBadge() }
        }
        .padding(.vertical, 1)
        .tag(topic)
    }
}

/// «Предложить идею» and «Сообщить о проблеме» under the topics.
private struct FeedbackFooter: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Button { Feedback.suggestIdea() } label: { Label("Предложить идею…", systemImage: "lightbulb") }
            Button { Feedback.reportProblem() } label: { Label("Сообщить о проблеме…", systemImage: "exclamationmark.bubble") }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}

/// One topic: header, picture, steps, facts, settings.
private struct HelpPage: View {
    let topic: HelpTopic
    let query: String

    @Environment(\.openSettingsPage) private var openSettings
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                    .reveal(appeared, step: 0, reduceMotion: reduceMotion)
                HelpIllustration(topic: topic)
                    .reveal(appeared, step: 1, reduceMotion: reduceMotion)
                if topic == .start {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Готовность", systemImage: "checklist").font(.system(size: 15, weight: .semibold))
                        ReadinessSection(collapsesWhenReady: true)
                    }
                    .reveal(appeared, step: 2, reduceMotion: reduceMotion)
                }
                if !topic.steps.isEmpty {
                    steps.reveal(appeared, step: 2, reduceMotion: reduceMotion)
                }
                ForEach(topic.sections) { section in
                    facts(section).reveal(appeared, step: 3, reduceMotion: reduceMotion)
                }
                if topic == .commandLine {
                    Text("Команды для скриптов вызываются так: \(HelpTopic.binary) --sessions")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 24)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear { appeared = true }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            IconTile(symbol: topic.symbol, tint: topic.tint, size: 54)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(topic.title).font(.system(size: 24, weight: .bold))
                    if topic.isBeta { BetaBadge() }
                }
                Text(topic.summary)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let pane = topic.settings {
                Button { open(pane) } label: { Label("Открыть в настройках", systemImage: "gearshape") }
                    .controlSize(.large)
            }
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Как начать").font(.system(size: 15, weight: .semibold))
            ForEach(Array(topic.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(verbatim: "\(index + 1)")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(topic.tint.gradient))
                    Text(step)
                        .font(.system(size: 14))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(topic.tint.opacity(0.07)))
    }

    private func facts(_ section: HelpSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.title ?? String(localized: "Что умеет")).font(.system(size: 15, weight: .semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: section.monospaced ? 520 : 300), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                ForEach(section.facts) { fact in
                    FactCard(fact: fact, tint: topic.tint, monospaced: section.monospaced, highlighted: matches(fact))
                }
            }
        }
    }

    private func matches(_ fact: HelpFact) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        return !query.isEmpty && (fact.name.localizedCaseInsensitiveContains(query) || fact.detail.localizedCaseInsensitiveContains(query))
    }

    private func open(_ pane: SettingsPane) { openSettings(pane) }
}

private struct FactCard: View {
    let fact: HelpFact
    let tint: Color
    let monospaced: Bool
    let highlighted: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            if let symbol = fact.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.12)))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: fact.name)
                    .font(monospaced ? .system(size: 12.5, weight: .semibold, design: .monospaced) : .system(size: 14, weight: .semibold))
                    .textSelection(.enabled)
                Text(fact.detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(highlighted ? Color.accentColor : Color.secondary.opacity(0.18), lineWidth: highlighted ? 1.5 : 0.5))
        .accessibilityElement(children: .combine)
    }
}

private extension View {
    /// Parts of a page fade and rise in one after another when it opens.
    func reveal(_ shown: Bool, step: Int, reduceMotion: Bool) -> some View {
        opacity(shown || reduceMotion ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 10)
            .animation(reduceMotion ? nil : .spring(duration: 0.5, bounce: 0.15).delay(Double(step) * 0.07), value: shown)
    }
}
