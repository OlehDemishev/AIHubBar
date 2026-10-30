import AppKit
import Foundation
import SwiftUI
import UserNotifications

/// Headless commands for scripts and checks, run instead of the UI:
/// - `ClaudePult --login-item [status|on|off]`
/// - `ClaudePult --claude next|finish|task <project-path> [task text] [--claude-path <path>] [--print] [--background]`
/// - `ClaudePult --hooks [status|install|uninstall]`
/// - `ClaudePult --sessions`, `ClaudePult --show-session <id>`, `ClaudePult --background-settings [code|filesOnly|filesAndWeb]`
/// - `ClaudePult --command report|summary|cleanup-check|cleanup` (in this process)
/// - `ClaudePult --app-command <command>|help|cleanup-output` (asks the running app)
/// - `ClaudePult --usage`, `ClaudePult --usage-raw` (subscription limits; the token is never printed), `--token-usage`
/// - `ClaudePult --notifications-status`
/// - `ClaudePult --modes`, `ClaudePult --export-settings <file.claudepult>` (import: open the file in Finder)
/// - `ClaudePult --assistant-preview <file.png> [template]` (the assistant's preview pane for a template, sample data)
/// - `ClaudePult --git-scan <folder>` (the built-in git scanner: health, branch, changes, PRs, attention)
/// - `ClaudePult --calendar [folder]` (calendar dates of the enabled modes, or of a folder read as «папки» + контент-план)
/// - `ClaudePult --folder-projects <folder>` (folder projects as the panel would list them)
/// - `ClaudePult --api-complete <provider> <prompt> [base-url]` (one request to a model by API, prints reply and tokens)
/// - `ClaudePult --services [check]` (installed agents, stored API keys; `check` lists each provider's models)
/// - `ClaudePult --menubar-preview <file.png> [minimum|limits|everything]` (the menu bar item with sample data)
/// - `ClaudePult --readiness [file.png]` (what this Mac still needs, as on the assistant's first screen; exit 1 if something is left)
@MainActor
enum CommandLineTool {
    /// Returns an exit code if the arguments contain a command, `nil` to start the app normally.
    static func run(_ arguments: [String]) -> Int32? {
        if let index = arguments.firstIndex(of: "--login-item") {
            return loginItem(arguments.dropFirst(index + 1).first ?? "status")
        }
        if let index = arguments.firstIndex(of: "--claude") {
            return claude(Array(arguments.dropFirst(index + 1)))
        }
        if let index = arguments.firstIndex(of: "--hooks") {
            return hooks(arguments.dropFirst(index + 1).first ?? "status")
        }
        if let index = arguments.firstIndex(of: "--app-command"), index + 1 < arguments.count {
            let name = arguments[index + 1]
            let known = Array(AppRequests.windows.keys) + AppRequests.actions + CommonCommand.allCases.map(\.cliName)
            guard known.contains(name) else {
                printError("Usage: ClaudePult --app-command " + known.sorted().joined(separator: "|"))
                return 2
            }
            AppRequests.post(name)
            print("sent \(name) to the running app")
            return 0
        }
        if let index = arguments.firstIndex(of: "--command"), index + 1 < arguments.count {
            guard let command = CommonCommand.allCases.first(where: { $0.cliName == arguments[index + 1] }),
                  command.script != nil else {
                printError("Usage: ClaudePult --command " + CommonCommand.allCases.filter { $0.script != nil }.map(\.cliName).joined(separator: "|"))
                return 2
            }
            let directory = AppSettings().dailyReportDirectory
            return waitFor {
                let (result, _) = await CommandStore.execute(command, dailyReportDirectory: directory)
                print("\(result.isError ? "error" : "ok"): \(result.text)")
                return result.isError ? 1 : 0
            }
        }
        if arguments.contains("--usage-raw") || arguments.contains("--usage") {
            let raw = arguments.contains("--usage-raw")
            return waitFor {
                if raw {
                    let data = try await UsageService.fetchData()
                    let object = try JSONSerialization.jsonObject(with: data)
                    let pretty = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
                    print(String(decoding: pretty, as: UTF8.self))
                } else {
                    let snapshot = try await UsageService.fetch()
                    for window in snapshot.windows {
                        let reset = window.resetsAt.map { " reset \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
                        print("\(window.key): \(Int(window.utilization.rounded()))%\(reset)")
                    }
                    if let extra = snapshot.extra { print("extra_usage: enabled=\(extra.isEnabled)") }
                }
                return 0
            }
        }
        if arguments.contains("--token-usage") {
            let settings = AppSettings()
            let projectsDirectory = settings.projectsDirectory
            return waitFor {
                let started = Date.now
                let records = await TokenScanner().scan(since: .now.addingTimeInterval(-7 * 86_400))
                for (title, since) in [("5 h", Date.now.addingTimeInterval(-5 * 3600)), ("today", Calendar.current.startOfDay(for: .now)), ("7 days", Date.now.addingTimeInterval(-7 * 86_400))] {
                    let breakdown = TokenBreakdown.make(records, since: since, projectsDirectory: projectsDirectory)
                    print("== \(title): \(TokenBreakdown.tokensText(breakdown.totalTokens)) tokens")
                    for row in breakdown.projects.prefix(8) {
                        print("  \(row.name): \(Int((row.share * 100).rounded()))% · \(TokenBreakdown.tokensText(row.tokens))")
                    }
                    if let top = breakdown.topSession { print("  top session: \(top.project) \(top.sessionID.prefix(8)) \(Int((top.share * 100).rounded()))%") }
                }
                print("scanned \(records.count) messages in \(String(format: "%.1f", Date.now.timeIntervalSince(started))) s")
                return 0
            }
        }
        if arguments.contains("--modes") {
            let modes = ModeStore(settings: AppSettings())
            for mode in modes.modes {
                let flags = (mode.id == modes.currentID ? "*" : " ") + (modes.enabledIDs.contains(mode.id) ? "on " : "off")
                print("\(flags)  \(mode.name)  [\(mode.template)]  \(mode.source.title): \(mode.source.folder ?? "-")")
                let modules = (mode.modules ?? []).map { $0.kind.rawValue + ($0.shown ? "" : " (hidden)") }
                print("       modules: \(modules.joined(separator: ", "))")
            }
            print("installed: \(modes.installedModules.map(\.rawValue).joined(separator: ", "))")
            return 0
        }
        if let index = arguments.firstIndex(of: "--export-settings"), index + 1 < arguments.count {
            let url = URL(fileURLWithPath: (arguments[index + 1] as NSString).expandingTildeInPath)
            do {
                try ModeStore.encode(ModeStore(settings: AppSettings()).exportBundle()).write(to: url, options: .atomic)
                print("exported to \(url.path)")
                return 0
            } catch {
                printError("error: \(error.localizedDescription)")
                return 1
            }
        }
        if let index = arguments.firstIndex(of: "--assistant-preview"), index + 1 < arguments.count {
            var draft = AssistantDraft(firstLaunch: false, menuBar: .make(.limits), hiddenBlocks: [], reminderHours: [24])
            let id = arguments.dropFirst(index + 2).first
            draft.choose(ModeTemplate.loadAll().first { $0.id == id })
            let renderer = ImageRenderer(content: AssistantPreview(draft: draft).frame(width: 430, height: 560).background(Color(white: 0.95))
                .environment(\.layoutDirection, layoutDirection))
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return 1 }
            do {
                try png.write(to: URL(fileURLWithPath: arguments[index + 1]))
                print("\(arguments[index + 1]): \(draft.mode.name), \(draft.steps.count) steps")
                return 0
            } catch {
                printError(error.localizedDescription)
                return 1
            }
        }
        if let index = arguments.firstIndex(of: "--git-scan"), index + 1 < arguments.count {
            let folder = (arguments[index + 1] as NSString).expandingTildeInPath
            return waitFor {
                guard let report = await GitScanner.report(projectsDirectory: folder, fetch: false) else { return 1 }
                for project in report.projects {
                    let prs = project.openPRs.map { " PR \($0.count) ci=\(project.pullRequestsCI.rawValue)" } ?? ""
                    print("\(project.health.rawValue)  \(project.name)  [\(project.branch ?? "-")] dirty=\(project.dirty)\(prs) stage=\(project.status?.summary?.stage ?? "-")")
                    for item in project.attention { print("    \(item.level.rawValue): \(item.text)") }
                }
                return 0
            }
        }
        if let index = arguments.firstIndex(of: "--calendar") {
            let infos: [CalendarScanner.ModeInfo]
            if index + 1 < arguments.count {
                infos = [.init(id: "cli", name: "папка", icon: "folder", source: .folders(arguments[index + 1]), calendar: .contentPlan)]
            } else {
                let modes = ModeStore(settings: AppSettings())
                infos = modes.enabledModes.map { .init(id: $0.id, name: $0.name, icon: $0.icon, source: $0.source, calendar: $0.calendar) }
            }
            let entries = CalendarScanner.entries(for: infos).sorted { $0.date < $1.date }
            for entry in entries {
                let when = CalendarScanner.text(entry.date, withTime: entry.hasTime)
                print("\(when)  \(entry.kind.rawValue)  \(entry.title)" + (entry.detail.map { "  (\($0))" } ?? "")
                      + "  — \(CalendarText.relative(entry.date, hasTime: entry.hasTime))" + (entry.isOverdue() ? "  OVERDUE" : ""))
            }
            if entries.isEmpty { print("no calendar dates") }
            return 0
        }
        if let index = arguments.firstIndex(of: "--folder-projects"), index + 1 < arguments.count {
            let projects = FolderScanner.scan(source: .folders(arguments[index + 1]))
            for project in projects {
                let metrics = FolderMetric.allCases.compactMap { metric in metric.text(for: project, wordsPerMinute: 150).map { "\(metric.rawValue)=\($0)" } }
                print("\(project.name)  [\(project.card.stage ?? "—")]  main=\(project.mainFile ?? "—")  " + metrics.joined(separator: "  "))
            }
            if projects.isEmpty { print("no folder projects in \(arguments[index + 1])") }
            return 0
        }
        if let index = arguments.firstIndex(of: "--api-complete"), index + 2 < arguments.count {
            guard let provider = APIProvider(rawValue: arguments[index + 1]) else {
                printError("Usage: ClaudePult --api-complete " + APIProvider.allCases.map(\.rawValue).joined(separator: "|") + " <prompt> [base-url]")
                return 2
            }
            var config = AppSettings().aiServices
            if index + 3 < arguments.count { config.compatibleBaseURL = arguments[index + 3] }
            if provider == .compatible, config.model(.compatible) == nil { config.models["compatible"] = "test" }
            let prompt = arguments[index + 2]
            let request = config
            return waitFor {
                let reply = try await APIClient.complete(provider, config: request, prompt: prompt)
                print(reply.text)
                print("tokens: in \(reply.inputTokens), out \(reply.outputTokens)")
                return 0
            }
        }
        if let index = arguments.firstIndex(of: "--services") {
            return servicesReport(check: arguments.dropFirst(index + 1).first == "check")
        }
        if let index = arguments.firstIndex(of: "--menubar-preview"), index + 1 < arguments.count {
            return menuBarPreview(path: arguments[index + 1], preset: arguments.dropFirst(index + 2).first)
        }
        if let index = arguments.firstIndex(of: "--readiness") {
            return readiness(png: arguments.dropFirst(index + 1).first { $0.hasSuffix(".png") })
        }
        if arguments.contains("--notifications-status") {
            return waitFor {
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                let names: [UNAuthorizationStatus: String] = [.notDetermined: "notDetermined", .denied: "denied", .authorized: "authorized", .provisional: "provisional"]
                print("notifications: \(names[settings.authorizationStatus] ?? "unknown(\(settings.authorizationStatus.rawValue))"), alerts: \(settings.alertSetting == .enabled)")
                return settings.authorizationStatus == .authorized ? 0 : 1
            }
        }
        if let index = arguments.firstIndex(of: "--background-settings") {
            let profile = arguments.dropFirst(index + 1).first.flatMap(PermissionProfile.init(rawValue:)) ?? .code
            print(BackgroundPermissions.settingsJSON(profile))
            return 0
        }
        if arguments.contains("--sessions") {
            for item in SessionStore.loadItems(from: SessionFiles.sessionsDirectory, now: .now) {
                let s = item.session
                print([s.id, item.state.rawValue, s.displayProject, s.worktreeName ?? "-", s.tty ?? "-", s.task ?? "-"].joined(separator: "\t"))
            }
            return 0
        }
        if let index = arguments.firstIndex(of: "--show-session"), index + 1 < arguments.count {
            let id = arguments[index + 1]
            let session = SessionStore.loadItems(from: SessionFiles.sessionsDirectory, now: .now).first(where: { $0.id == id })?.session
            if session?.entrypoint == "claude-desktop" {
                guard let link = SessionActions.desktopLink(cliSessionID: id) else {
                    printError("Claude app has no session for \(id)")
                    return 1
                }
                NSWorkspace.shared.open(link)
                print("opened \(link.absoluteString)")
                return 0
            }
            guard let session, let tty = session.tty, session.isInTerminalApp else {
                printError("no Terminal.app session with id \(id)")
                return 1
            }
            return waitFor {
                let found = await SessionActions.focusTerminalTab(tty: tty)
                print(found ? "focused \(tty)" : "tab not found")
                return found ? 0 : 1
            }
        }
        return nil
    }

    private static func hooks(_ action: String) -> Int32 {
        let installer = HookInstaller.live(projectsDirectory: AppSettings().projectsDirectory)
        do {
            switch action {
            case "status": break
            case "install":
                if let backup = try installer.install() { print("backup: \(backup.path)") }
            case "uninstall":
                if let backup = try installer.uninstall() { print("backup: \(backup.path)") }
            default:
                printError("Usage: ClaudePult --hooks [status|install|uninstall]")
                return 2
            }
        } catch {
            printError("error: \(error.localizedDescription)")
            return 1
        }
        print("hooks: \(installer.status())")
        return 0
    }

    private static func loginItem(_ action: String) -> Int32 {
        let controller = LoginItemController()
        switch action {
        case "status": break
        case "on": controller.setEnabled(true)
        case "off": controller.setEnabled(false)
        default:
            printError("Usage: ClaudePult --login-item [status|on|off]")
            return 2
        }

        print("login-item: \(controller.state)")
        if let error = controller.lastError {
            printError("error: \(error)")
            return 1
        }
        return 0
    }

    private static func claude(_ arguments: [String]) -> Int32 {
        var args = arguments
        let printOnly = args.contains("--print")
        let background = args.contains("--background")
        args.removeAll { $0 == "--print" || $0 == "--background" }
        var configuredPath = AppSettings().claudePath
        if let index = args.firstIndex(of: "--claude-path"), index + 1 < args.count {
            configuredPath = args[index + 1]
            args.removeSubrange(index...index + 1)
        }

        let usage = "Usage: ClaudePult --claude next|finish|task <project-path> [task text] [--claude-path <path>] [--print] [--background]"
        guard args.count >= 2 else { printError(usage); return 2 }
        let command: ClaudeCommand
        switch args[0] {
        case "next": command = .nextStep
        case "finish": command = .finishSession
        case "task" where args.count >= 3: command = .customTask(args[2...].joined(separator: " "))
        default: printError(usage); return 2
        }

        let request = LaunchRequest(
            command: command,
            projectPath: (args[1] as NSString).standardizingPath,
            claudePath: ClaudeLocator.resolve(configured: configuredPath)
        )
        if printOnly {
            if background {
                print(([request.claudePath] + BackgroundPermissions.arguments(prompt: command.prompt, sessionID: "<id>"))
                    .map(ShellQuote.quote).joined(separator: " "))
            } else {
                print(ShellQuote.claudeCommandLine(folder: request.projectPath, claude: request.claudePath, prompt: command.prompt))
            }
            return 0
        }
        if background {
            return launchInBackground(request)
        }
        return waitFor {
            switch try await ClaudeLauncher.launch(request) {
            case let .launched(folder, worktree):
                print("launched in \(folder)" + (worktree.map { " (worktree, branch \($0.branch))" } ?? ""))
                return 0
            case let .needsConfirmation(question):
                printError(question)
                return 3
            }
        }
    }

    /// Starts a background run; the running ClaudePult app picks it up and reports the result.
    private static func launchInBackground(_ request: LaunchRequest) -> Int32 {
        let folder = FolderBox()
        let prepared = waitFor {
            switch try await ClaudeLauncher.prepareFolder(request) {
            case let .ready(path, worktree):
                folder.value = (path, worktree)
                return 0
            case let .needsConfirmation(question):
                printError(question)
                return 3
            }
        }
        guard prepared == 0, let (path, worktree) = folder.value else { return prepared }
        do {
            // This process exits right away; the running app picks the run up and reports its result.
            let store = RunStore(settings: AppSettings())
            let run = try store.launch(
                command: request.command, project: (request.projectPath as NSString).lastPathComponent,
                projectPath: request.projectPath, folder: path, worktreeBranch: worktree?.branch,
                claudePath: request.claudePath
            )
            print("background run \(run.id) in \(path), log \(run.logURL.path)")
            return 0
        } catch {
            printError("error: \(error.localizedDescription)")
            return 1
        }
    }

    /// Runs async work to completion from the synchronous app entry point.
    private static func waitFor(_ work: @escaping @Sendable () async throws -> Int32) -> Int32 {
        let semaphore = DispatchSemaphore(value: 0)
        let result = ExitCode()
        Task.detached {
            do {
                result.value = try await work()
            } catch {
                printError("error: \(error.localizedDescription)")
                result.value = 1
            }
            semaphore.signal()
        }
        semaphore.wait()
        return result.value
    }

    private nonisolated static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    /// Keys are never printed — only whether one is stored and what the check says.
    private static func servicesReport(check: Bool) -> Int32 {
        let config = AppSettings().aiServices
        return waitFor {
            let agents = await AIServiceStore.findAgents()
            for kind in AgentKind.allCases {
                let info = agents[kind]
                print("agent \(kind.binary): " + (info.map { $0.path + ($0.version.map { " — \($0)" } ?? "") } ?? "not installed"))
            }
            let keys = await AIServiceStore.storedKeys()
            for provider in APIProvider.allCases {
                var line = "api \(provider.rawValue): key " + (keys.contains(provider) ? "stored" : "none")
                if check, keys.contains(provider) || !provider.keyRequired {
                    line += ", check: " + (await AIServiceStore.check(provider, baseURL: config.baseURL(provider))).text
                }
                print(line)
            }
            return 0
        }
    }

    /// Windows take the direction from NSApp; the offscreen renderer has to be told (Arabic is right-to-left).
    private static var layoutDirection: LayoutDirection {
        Locale.Language(identifier: ContentLanguage.current.rawValue).characterDirection == .rightToLeft ? .rightToLeft : .leftToRight
    }

    /// The readiness rows for this Mac; with a path, also drawn as the assistant's first screen shows them.
    private static func readiness(png path: String?) -> Int32 {
        let hooks = HookInstaller.live(projectsDirectory: AppSettings().projectsDirectory).status()
        let loginItem = LoginItemController().state
        let box = ReadinessBox()
        _ = waitFor {
            let agents = await AIServiceStore.findAgents()
            let keys = await AIServiceStore.storedKeys()
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            box.input = Readiness.Input(
                claudeVersion: agents[.claudeCode].map { $0.version ?? "" },
                otherServices: AgentKind.allCases.filter { $0 != .claudeCode && agents[$0] != nil }.map(\.title)
                    + APIProvider.allCases.filter { keys.contains($0) }.map(\.title),
                hooks: hooks,
                notifications: status == .authorized || status == .provisional ? .allowed : status == .denied ? .denied : .notAsked,
                loginItem: loginItem
            )
            return 0
        }
        guard let input = box.input else { return 1 }
        let items = Readiness.items(input)
        for item in items {
            print("\(item.state)\t\(item.title): \(item.detail)" + (item.action.map { " [\($0.title)]" } ?? ""))
        }
        if let path {
            let renderer = ImageRenderer(content: ReadinessList(items: items) { _ in }.padding(20).frame(width: 470).background(Color(white: 0.95))
                .environment(\.layoutDirection, layoutDirection))
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
                  (try? png.write(to: URL(fileURLWithPath: path))) != nil else { return 1 }
        }
        return Readiness.isReady(items) ? 0 : 1
    }

    /// Draws the item as the menu bar would (dark and light) from the saved config, or from a preset.
    private static func menuBarPreview(path: String, preset: String?) -> Int32 {
        let config = preset.flatMap(MenuBarConfig.Preset.init(rawValue:)).map(MenuBarConfig.make) ?? AppSettings().menuBarConfig
        let groups = MenuBarComposer.groups(config, .sample)
        let item = MenuBarRenderer.image(groups, config: config)
        let scale: CGFloat = 2, pad: CGFloat = 8
        let size = NSSize(width: (item.size.width + pad * 2) * scale, height: (item.size.height + pad * 2) * scale * 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return 1 }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)
        let half = item.size.height + pad * 2
        for (index, name) in [NSAppearance.Name.darkAqua, .aqua].enumerated() {
            NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
                let band = NSRect(x: 0, y: CGFloat(index) * half, width: item.size.width + pad * 2, height: half)
                (name == .darkAqua ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
                band.fill()
                item.draw(in: NSRect(x: pad, y: band.minY + pad, width: item.size.width, height: item.size.height))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return 1 }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("\(path): \(Int(item.size.width)) pt wide, \(groups.count) element(s)")
            return 0
        } catch {
            printError(error.localizedDescription)
            return 1
        }
    }
}

/// Written by the detached task before `signal()`, read after `wait()`.
private final class ReadinessBox: @unchecked Sendable {
    var input: Readiness.Input?
}

private final class ExitCode: @unchecked Sendable {
    var value: Int32 = 0
}

private final class FolderBox: @unchecked Sendable {
    var value: (String, WorktreePlan?)?
}
