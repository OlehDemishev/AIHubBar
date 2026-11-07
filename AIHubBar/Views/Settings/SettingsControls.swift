import AppKit
import SwiftUI

/// A page's form: grouped, filling the page and scrolling.
struct SettingsPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
    }
}

/// One column for the icons of every row in Settings: a plain `Label` starts its title where the symbol ends, so the
/// titles in a card did not line up. Set once on the page; `.iconOnly` buttons keep their own style.
struct SettingsRowLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon
                .frame(width: 22)
            configuration.title
        }
    }
}

/// A field on a line of its own. A grouped `Form` would put the title beside it and align the text to the right, which
/// reads badly for anything longer than a word; the title is the placeholder here.
struct FormField: View {
    let title: Text
    @Binding var text: String
    var axis: Axis = .horizontal

    init(_ title: Text, text: Binding<String>, axis: Axis = .horizontal) {
        self.title = title
        _text = text
        self.axis = axis
    }

    var body: some View {
        TextField(text: $text, prompt: title, axis: axis) { title }
            .labelsHidden()
            .multilineTextAlignment(.leading)
            .textFieldStyle(.roundedBorder)
    }
}

/// A settings row with an icon in front of its title, like the toggles and pickers that take `systemImage:`.
struct IconRow<Content: View>: View {
    let title: LocalizedStringKey
    let symbol: String
    let content: Content

    init(_ title: LocalizedStringKey, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        symbol = systemImage
        self.content = content()
    }

    var body: some View {
        LabeledContent {
            content
        } label: {
            Label(title, systemImage: symbol)
        }
    }
}

extension IconRow where Content == Text {
    init(_ title: LocalizedStringKey, systemImage: String, value: String) {
        self.init(title, systemImage: systemImage) { Text(value) }
    }
}

/// The small text under a section. A long one shows its first sentence and «Подробнее» (SPEC-settings §2): the
/// pages read as settings, not as manuals.
struct Footnote: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        let short = Self.firstSentence(text)
        VStack(alignment: .leading, spacing: 2) {
            Text(expanded || short == nil ? text : short ?? text)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if short != nil {
                Button(expanded ? String(localized: "Свернуть") : String(localized: "Подробнее")) {
                    withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
                }
                .buttonStyle(.link)
                .font(.system(size: 11.5))
            }
        }
    }

    /// The first sentence when the text is long and has more after it; nil — show it whole.
    nonisolated static func firstSentence(_ text: String) -> String? {
        guard text.count > 140 else { return nil }
        let ends = [". ", "。", "! ", "? "]
        let found = ends.compactMap { text.range(of: $0) }.filter { text.distance(from: text.startIndex, to: $0.lowerBound) >= 12 }
        guard let end = found.min(by: { $0.lowerBound < $1.lowerBound }) else { return nil }
        let sentence = String(text[..<end.upperBound]).trimmingCharacters(in: .whitespaces)
        return text.count - sentence.count > 30 ? sentence : nil
    }
}

/// «бета» next to a module still in beta testing.
struct BetaBadge: View {
    var body: some View {
        Text("бета")
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(.orange)
            .background(.orange.opacity(0.15), in: Capsule())
    }
}

enum SettingsParsing {
    /// Percentages between 1 and 100 from free text, sorted and de-duplicated.
    static func thresholds(_ text: String) -> [Int] {
        Array(Set(text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.filter { (1...100).contains($0) })).sorted()
    }
}
