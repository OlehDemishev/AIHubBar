import Foundation

/// The setup assistant's work in progress (SPEC-modes §5): a mode being assembled block by block, plus the global
/// settings the assistant also asks about (menu bar, panel blocks, reminders). Nothing is saved until «Готово».
struct AssistantDraft: Equatable, Sendable {
    enum Step: String, CaseIterable, Sendable {
        case importSettings, template, folder, stages, metrics, calendar, service, commands, launch, panel, menuBar, name

        var title: String {
            switch self {
            case .importSettings: String(localized: "Перенести настройки?")
            case .template: String(localized: "Чем вы занимаетесь?")
            case .folder: String(localized: "Где лежат проекты?")
            case .stages: String(localized: "Этапы")
            case .metrics: String(localized: "Что показывать в строке проекта")
            case .calendar: String(localized: "Календарь")
            case .service: String(localized: "Сервис AI")
            case .commands: String(localized: "Команды")
            case .launch: String(localized: "Где запускать и что разрешить")
            case .panel: String(localized: "Блоки панели")
            case .menuBar: String(localized: "Строка меню")
            case .name: String(localized: "Название и значок")
            }
        }
    }

    /// What the chosen folder holds, for suggesting the source.
    struct FolderAnalysis: Equatable, Sendable {
        var repositories = 0
        var folders = 0
        var files = 0

        var suggestsGit: Bool { repositories > 0 && repositories * 2 >= folders }

        var text: String {
            if folders == 0, files == 0 { return String(localized: "Папка пуста — проекты появятся, когда вы их создадите.") }
            var parts: [String] = []
            if repositories > 0 { parts.append(String(localized: "git-репозиториев: \(repositories)")) }
            if folders - repositories > 0 { parts.append(String(localized: "обычных папок: \(folders - repositories)")) }
            if files > 0 { parts.append(String(localized: "файлов: \(files)")) }
            return String(localized: "Внутри ") + parts.joined(separator: ", ") + "."
        }

        static func of(_ path: String) -> FolderAnalysis {
            let fm = FileManager.default
            let children = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles])) ?? []
            var analysis = FolderAnalysis()
            for child in children {
                if (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    analysis.folders += 1
                    if fm.fileExists(atPath: child.appending(path: ".git").path) { analysis.repositories += 1 }
                } else {
                    analysis.files += 1
                }
            }
            return analysis
        }
    }

    var firstLaunch: Bool
    /// nil = «С нуля».
    var templateID: String?
    var mode: Mode
    var menuBar: MenuBarConfig
    var hiddenBlocks: Set<PanelBlock>
    var reminderHours: [Int]
    var analysis: FolderAnalysis?
    var step: Step

    init(firstLaunch: Bool, menuBar: MenuBarConfig, hiddenBlocks: Set<PanelBlock>, reminderHours: [Int]) {
        self.firstLaunch = firstLaunch
        mode = Self.blank
        self.menuBar = menuBar
        self.hiddenBlocks = hiddenBlocks
        self.reminderHours = reminderHours
        step = firstLaunch ? .importSettings : .template
    }

    static let blank = Mode(
        name: String(localized: "Новый режим"), icon: "sparkle", template: "custom", source: .folders(String(localized: "~/Documents/Проекты")), card: .projectMD,
        stages: [String(localized: "в работе"), String(localized: "готово")], metrics: ["words", "lastActivity"], launchMode: .background, permissions: .filesOnly,
        calendar: .dates, commonCommands: .none, showCommonCommands: false
    )

    /// The steps that apply: cards, stages, metrics, calendar and commands only for folder projects.
    var steps: [Step] {
        Step.allCases.filter { step in
            switch step {
            case .importSettings: firstLaunch
            case .stages, .metrics, .calendar, .commands: mode.source.isFolders
            default: true
            }
        }
    }

    var index: Int { steps.firstIndex(of: step) ?? 0 }
    var isFirst: Bool { index == 0 }
    var isLast: Bool { step == steps.last }

    mutating func next() {
        let all = steps
        if let i = all.firstIndex(of: step), i + 1 < all.count { step = all[i + 1] }
    }

    mutating func back() {
        let all = steps
        if let i = all.firstIndex(of: step), i > 0 { step = all[i - 1] }
    }

    /// A template replaces the mode but keeps a folder already chosen.
    mutating func choose(_ template: ModeTemplate?) {
        let folder = mode.source.folder
        templateID = template?.id
        mode = template?.mode ?? Self.blank
        mode.id = UUID().uuidString.lowercased()
        if let folder, analysis != nil { setFolder(folder, analysis: analysis) }
        if template?.id == "developer" { menuBar = .make(.limits) }
    }

    /// The folder and the source it suggests: git repositories → the built-in scanner, otherwise folder projects.
    mutating func setFolder(_ path: String, analysis: FolderAnalysis?) {
        self.analysis = analysis
        let folder = PathText.tilde(path)
        if let analysis, analysis.suggestsGit {
            mode.source = .gitBuiltin(projects: folder)
            if mode.card == .projectMD { mode.card = .statusMD }
            mode.permissions = .code
        } else if case .inbox = mode.source {
            mode.source = .inbox(folder)
        } else {
            mode.source = .folders(folder)
            if mode.card == .statusMD { mode.card = .projectMD }
            if mode.permissions == .code { mode.permissions = .filesOnly }
        }
    }
}
