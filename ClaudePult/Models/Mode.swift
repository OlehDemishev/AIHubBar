import Foundation

/// A way of working with ClaudePult, assembled from blocks (docs/SPEC-modes.md §1, §3). Stored as JSON in
/// `~/Library/Application Support/ClaudePult/modes/<id>.json`; exported and imported as `*.claudepult` files.
/// Decoding is tolerant: unknown or missing blocks fall back to defaults, so files from newer versions still open.
/// Paths are stored with `~` (portable between Macs) and expanded when a mode is applied.
struct Mode: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    /// SF Symbol shown in the switcher.
    var icon: String
    /// Built-in template the mode started from (`developer`, `video`, …); `custom` for a hand-made one.
    var template: String
    var source: ProjectSource
    var card: ProjectCard
    var stages: [String]
    var metrics: [String]
    /// Speech pace for «Хронометраж».
    var wordsPerMinute: Int
    /// nil = ask «Терминал / Фон» every time.
    var launchMode: LaunchMode?
    /// The service the mode's commands use by default (`AIService.id`); nil = Claude Code.
    var service: String?
    var permissions: PermissionProfile
    var calendar: CalendarMode
    var showProjects: Bool
    var commonCommands: CommonCommandsKind
    var showCommonCommands: Bool
    /// Commands of a folder mode; «Своя задача» is always there besides these.
    var commands: [CommandTemplate]

    init(
        id: String = UUID().uuidString.lowercased(), name: String, icon: String = "sparkle", template: String = "custom",
        source: ProjectSource = .none, card: ProjectCard = .none, stages: [String] = [], metrics: [String] = [], wordsPerMinute: Int = 150,
        launchMode: LaunchMode? = nil, service: String? = nil, permissions: PermissionProfile = .filesOnly, calendar: CalendarMode = .off,
        showProjects: Bool = true, commonCommands: CommonCommandsKind = .none, showCommonCommands: Bool = true, commands: [CommandTemplate] = []
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.template = template
        self.source = source
        self.card = card
        self.stages = stages
        self.metrics = metrics
        self.wordsPerMinute = wordsPerMinute
        self.launchMode = launchMode
        self.service = service
        self.permissions = permissions
        self.calendar = calendar
        self.showProjects = showProjects
        self.commonCommands = commonCommands
        self.showCommonCommands = showCommonCommands
        self.commands = commands
    }

    enum CodingKeys: String, CodingKey {
        case id, name, icon, template, source, card, stages, metrics, wordsPerMinute, launchMode, service, permissions, calendar
        case showProjects, commonCommands, showCommonCommands, commands
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? UUID().uuidString.lowercased()
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Режим"
        icon = (try? c.decodeIfPresent(String.self, forKey: .icon)) ?? "sparkle"
        template = (try? c.decodeIfPresent(String.self, forKey: .template)) ?? "custom"
        source = (try? c.decodeIfPresent(ProjectSource.self, forKey: .source)) ?? .none
        card = (try? c.decodeIfPresent(ProjectCard.self, forKey: .card)) ?? .none
        stages = (try? c.decodeIfPresent([String].self, forKey: .stages)) ?? []
        metrics = (try? c.decodeIfPresent([String].self, forKey: .metrics)) ?? []
        wordsPerMinute = (try? c.decodeIfPresent(Int.self, forKey: .wordsPerMinute)) ?? 150
        launchMode = try? c.decodeIfPresent(LaunchMode.self, forKey: .launchMode)
        service = try? c.decodeIfPresent(String.self, forKey: .service)
        permissions = (try? c.decodeIfPresent(PermissionProfile.self, forKey: .permissions)) ?? .filesOnly
        calendar = (try? c.decodeIfPresent(CalendarMode.self, forKey: .calendar)) ?? .off
        showProjects = (try? c.decodeIfPresent(Bool.self, forKey: .showProjects)) ?? true
        commonCommands = (try? c.decodeIfPresent(CommonCommandsKind.self, forKey: .commonCommands)) ?? .none
        showCommonCommands = (try? c.decodeIfPresent(Bool.self, forKey: .showCommonCommands)) ?? true
        commands = (try? c.decodeIfPresent([CommandTemplate].self, forKey: .commands)) ?? []
    }

    /// Stages without the empty items a half-typed list may have.
    var stageList: [String] { stages.filter { !$0.isEmpty } }

    /// The developer setup ClaudePult had before modes (report.py, `_daily-report`), as a mode.
    static func developerWithReport(
        projectsDirectory: String, dailyReportDirectory: String, launchMode: LaunchMode?,
        showProjects: Bool, showCommonCommands: Bool
    ) -> Mode {
        Mode(
            name: "Разработчик (мой)",
            icon: "chevron.left.forwardslash.chevron.right",
            template: "developer-report",
            source: .gitReport(projects: PathText.tilde(projectsDirectory), dailyReport: PathText.tilde(dailyReportDirectory)),
            card: .statusMD,
            metrics: ["branch", "dirty", "pullRequests", "lastActivity"],
            launchMode: launchMode,
            permissions: .code,
            showProjects: showProjects,
            commonCommands: .dailyReport,
            showCommonCommands: showCommonCommands
        )
    }
}

/// Where a mode's projects come from (§3).
enum ProjectSource: Codable, Equatable, Sendable {
    /// Git repositories as reported by `_daily-report/report.py --json` (Oleh's setup).
    case gitReport(projects: String, dailyReport: String)
    /// Git repositories scanned by ClaudePult itself (stage 6).
    case gitBuiltin(projects: String)
    /// Every subfolder is a project (stage 4).
    case folders(String)
    /// One inbox folder (stage 4).
    case inbox(String)
    case none

    var title: String {
        switch self {
        case .gitReport: "git-репозитории через report.py"
        case .gitBuiltin: "git-репозитории"
        case .folders: "папки"
        case .inbox: "папка «входящие»"
        case .none: "без проектов"
        }
    }

    var isFolders: Bool {
        switch self {
        case .folders, .inbox: true
        default: false
        }
    }

    var isGit: Bool {
        switch self {
        case .gitReport, .gitBuiltin: true
        default: false
        }
    }

    /// Sources the panel can list.
    var isShownInPanel: Bool { self != .none }

    /// The projects folder, `~`-form.
    var folder: String? {
        switch self {
        case let .gitReport(projects, _), let .gitBuiltin(projects): projects
        case let .folders(path), let .inbox(path): path
        case .none: nil
        }
    }
}

enum ProjectCard: String, Codable, Sendable {
    case statusMD, projectMD, none
}

enum PermissionProfile: String, Codable, CaseIterable, Sendable {
    case code, filesOnly, filesAndWeb

    var title: String {
        switch self {
        case .code: "Код: git, сборки, PR"
        case .filesOnly: "Только файлы проекта"
        case .filesAndWeb: "Файлы + поиск в интернете"
        }
    }
}

enum CalendarMode: String, Codable, CaseIterable, Sendable {
    case off, dates, contentPlan
}

enum CommonCommandsKind: String, Codable, Sendable {
    /// Report, summary, latest report, cleanup from `_daily-report`.
    case dailyReport
    case custom
    case none
}

extension LaunchMode: Codable {}

/// `~/…` for paths inside the home folder, so files can move between Macs.
enum PathText {
    static func tilde(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}
