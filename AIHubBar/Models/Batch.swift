import Foundation

/// One command over several folder projects, one project after another (docs/specs/SPEC-content.md §5): «описания
/// для 10 роликов» now, at night or after the limit resets.
struct Batch: Codable, Identifiable, Equatable, Sendable {
    enum When: String, Codable, CaseIterable, Sendable {
        case now, night, afterReset
    }

    struct Item: Codable, Equatable, Identifiable, Sendable {
        enum State: String, Codable, Sendable {
            case waiting, running, done, failed
        }

        var projectPath: String
        var name: String
        var state: State = .waiting
        /// The file the command writes, known once it started.
        var resultFile: String?
        /// Why it failed.
        var note: String?

        var id: String { projectPath }
        var isFinished: Bool { state == .done || state == .failed }
    }

    var id: String
    var template: CommandTemplate
    var profileID: String
    /// `AIService.id`.
    var serviceID: String
    /// What the command asks for («Тон»), asked once for the whole batch.
    var text: String?
    var when: When
    var startAt: Date
    var items: [Item]
    /// The summary went out.
    var announced = false

    var isFinished: Bool { items.allSatisfy(\.isFinished) }
    var finishedCount: Int { items.filter(\.isFinished).count }
    var doneCount: Int { items.filter { $0.state == .done }.count }
    var runningIndex: Int? { items.firstIndex { $0.state == .running } }
    var nextIndex: Int? { items.firstIndex { $0.state == .waiting } }

    /// A batch runs unattended, so only where background runs exist: Claude Code in the background and models by
    /// API. Other agents open in Terminal and wait for a paste.
    static func canRun(_ service: AIService, mode: Profile) -> Bool {
        switch service {
        case .api: true
        case .agent(.claudeCode): mode.launchMode != .terminal
        case .agent: false
        }
    }

    /// Near a limit only Claude Code's runs wait: a model by API has its own budget.
    var waitsForLimit: Bool { serviceID == AIService.claudeCode.id }

    /// «Редактура: 3 из 10», or when it starts.
    func status(now: Date = .now) -> String {
        if isFinished {
            return doneCount == items.count
                ? String(localized: "готово: \(doneCount) из \(items.count)")
                : String(localized: "готово: \(doneCount) из \(items.count), не получилось: \(items.count - doneCount)")
        }
        if startAt > now, finishedCount == 0, runningIndex == nil {
            return String(localized: "начнётся в \(startAt.formatted(date: .omitted, time: .shortened)), проектов: \(items.count)")
        }
        return String(localized: "\(finishedCount) из \(items.count)")
    }

    /// One notification for the whole batch.
    var summary: (title: String, body: String) {
        let title = String(localized: "Пакет «\(template.title)»: ✅ \(doneCount), ❌ \(items.count - doneCount)")
        let body = items.map { item in
            item.state == .done ? "✅ \(item.name)" : "❌ \(item.name)" + (item.note.map { ": \($0)" } ?? "")
        }.joined(separator: "\n")
        return (title, body)
    }
}
