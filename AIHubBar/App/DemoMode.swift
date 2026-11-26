import Foundation

/// The demo copy, for recording news about a release: the app filled with sample data, with nothing of the person's
/// own on screen and nothing asked from any service.
///
/// Nobody can switch it on from the app. `scripts/demo.sh` makes a copy with its own bundle id and a throwaway home
/// folder and starts it; only that copy is a demo. The installed app, with its real id, never is. In the copy the
/// stores get `DemoData` instead of their refresh loops, and nothing that reaches outside starts: no limits requests,
/// no Keychain, no Telegram, no updates, no global keys, no clipboard or keyboard watching.
///
/// What it shows changes with each release: see `DemoData.version` and docs/RELEASE.md → «Demo».
enum DemoMode {
    static let bundleID = "com.demishev.claudepult.demo"
    static let sceneVariable = "AIHUBBAR_DEMO_SCENE"

    /// What the copy shows. `scripts/demo.sh <scene>` picks one.
    enum Scene: String, CaseIterable {
        /// Claude is the main service; Codex, Copilot and Antigravity are the others.
        case standard = "default"
        /// No Claude on this Mac: Codex leads the panel and the menu bar (0.11).
        case codexMain = "codex-main"
    }

    private static var isDemoCopy: Bool { Bundle.main.bundleIdentifier == bundleID }
    /// The copy's settings are its own through the bundle id; its files are only with a home folder of its own.
    private static var hasOwnHome: Bool { ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil }

    static let isActive = isDemoCopy && hasOwnHome && !TestHost.isActive
    /// The copy started by hand, without `scripts/demo.sh`: it would read and write the person's real files.
    static let isMisconfigured = isDemoCopy && !hasOwnHome && !TestHost.isActive

    static var scene: Scene {
        ProcessInfo.processInfo.environment[sceneVariable].flatMap(Scene.init(rawValue:)) ?? .standard
    }

    /// A window to open right after the start (`scripts/demo.sh --open limits`), for a recording of that window alone.
    static let windowVariable = "AIHUBBAR_DEMO_OPEN"
    static var windowToOpen: WindowID? {
        ProcessInfo.processInfo.environment[windowVariable].flatMap(WindowID.init(rawValue:))
    }

    /// A profile, so the panel has its blocks and the assistant stays closed: the «Developer (GitHub)» template.
    @MainActor
    static func addProfile(to modes: ProfileStore) {
        guard modes.modes.isEmpty else { return }
        let templates = ProfileTemplate.loadAll()
        guard let template = templates.first(where: { $0.id == "developer" }) ?? templates.first else {
            AppLog.error("Demo: no profile template")
            return
        }
        modes.addFromAssistant(template.makeMode(folder: DemoData.projectsDirectory))
        // 0.14: the Skills Catalog, on the sample skills below.
        modes.setOn(.skills, true)
    }

    /// Puts the sample data into the stores. They are not started in the copy, so it stays as shown.
    @MainActor
    static func show(in app: AppContainer) {
        let data = DemoData.make(scene: scene, now: .now)
        app.usage.showDemo(snapshot: data.snapshot, history: data.history, week: data.week, days: data.days,
                           breakdowns: data.breakdowns)
        app.hub.showDemo(data.hubLimits)
        app.sessions.showDemo(items: data.sessions, approvals: data.approvals)
        app.runs.runs = data.runs
        if let report = data.report { app.store.showDemo(report) }
        writeFiles(data)
        // The catalog reads the sample skills the copy's home now holds; the agents' logs there are empty.
        Task { await app.skills.refresh() }
        if let window = windowToOpen { app.requests.openWindow(window) }
        AppLog.info("Demo: scene «\(scene.rawValue)», \(data.sessions.count) sessions, \(data.runs.count) runs, \(data.hubLimits.count) other services")
    }

    /// What the app reads from files where it is shown: who is signed in to Claude, and the runs' logs.
    private static func writeFiles(_ data: DemoData) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let identity = data.claudeIdentity {
            try? identity.write(to: home.appending(path: ".claude.json"), options: .atomic)
        }
        for (path, text) in DemoData.skills {
            let file = home.appending(path: path)
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(text.utf8).write(to: file, options: .atomic)
        }
        try? FileManager.default.createDirectory(at: BackgroundRun.runsDirectory, withIntermediateDirectories: true)
        for run in data.runs {
            try? Data(DemoData.log(of: run).utf8).write(to: run.logURL, options: .atomic)
        }
    }
}
