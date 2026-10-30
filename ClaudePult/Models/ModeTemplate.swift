import Foundation

/// A built-in template (SPEC-modes §4): a ready mode as JSON in the app's resources (`template-*.json`), so its texts
/// change without touching code; a mode made from it is the person's own and is edited in Settings → «Режимы».
struct ModeTemplate: Decodable, Identifiable, Sendable {
    var id: String
    var title: String
    var description: String
    /// What the folder the person picks should hold.
    var folderHint: String
    var order: Int
    var mode: Mode

    static func loadAll(bundle: Bundle = .main) -> [ModeTemplate] {
        let urls = (bundle.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [])
            + (bundle.urls(forResourcesWithExtension: "json", subdirectory: "Templates") ?? [])
        var seen = Set<String>()
        return urls.filter { $0.lastPathComponent.hasPrefix("template-") }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? JSONDecoder().decode(ModeTemplate.self, from: $0) } }
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.order < $1.order }
    }

    /// The template's mode for this person: a fresh id and the folder they chose.
    func makeMode(folder: String, name: String? = nil) -> Mode {
        var mode = self.mode
        mode.id = UUID().uuidString.lowercased()
        if let name { mode.name = name }
        let path = PathText.tilde(folder)
        switch mode.source {
        case .gitReport(_, let dailyReport): mode.source = .gitReport(projects: path, dailyReport: dailyReport)
        case .gitBuiltin: mode.source = .gitBuiltin(projects: path)
        case .folders: mode.source = .folders(path)
        case .inbox: mode.source = .inbox(path)
        case .none: break
        }
        return mode
    }
}
