import AppKit
import Foundation
import SwiftUI
import UserNotifications

/// Headless commands for scripts and checks, run instead of the UI:
/// - `AIHubBar --help` (every command below, from the command table)
/// - `AIHubBar --login-item [status|on|off]`
/// - `AIHubBar --claude next|finish|task <project-path> [task text] [--claude-path <path>] [--print] [--background]`
/// - `AIHubBar --hooks [status|install|uninstall]`
/// - `AIHubBar --copilot-hooks [status|install|uninstall]` (Copilot CLI session states, `CopilotHooks`)
/// - `AIHubBar --codex-hooks [status|install|uninstall]` (Codex CLI session states, `CodexHooks`)
/// - `AIHubBar --sessions`, `AIHubBar --show-session <id>`, `AIHubBar --background-settings [code|filesOnly|filesAndWeb]`
/// - `AIHubBar --command report|summary|cleanup-check|cleanup` (in this process)
/// - `AIHubBar --app-command <command>|help|cleanup-output` (asks the running app)
/// - `AIHubBar --usage`, `AIHubBar --usage-raw` (subscription limits; the token is never printed), `--token-usage`
/// - `AIHubBar --notifications-status`
/// - `AIHubBar --modes`, `AIHubBar --export-settings <file.claudepult>` (import: open the file in Finder)
/// - `AIHubBar --assistant-preview <file.png> [template|welcome] [--dark]` (the assistant's right side for a template, or
///   the map of the panel on its first screen; sample data)
/// - `AIHubBar --git-scan <folder>` (the built-in git scanner: health, branch, changes, PRs, attention)
/// - `AIHubBar --calendar [folder] [template]` (calendar dates of the enabled modes, or of a folder read as «папки» +
///   контент-план, with a template's stages)
/// - `AIHubBar --folder-projects <folder> [template]` (folder projects as the panel would list them in that template)
/// - `AIHubBar --api-complete <provider> <prompt> [base-url]` (one request to a model by API, prints reply and tokens)
/// - `AIHubBar --services [check]` (installed agents, stored API keys; `check` lists each provider's models)
/// - `AIHubBar --menubar-preview <file.png> [minimum|limits|everything]` (the menu bar item with sample data)
/// - `AIHubBar --help-export <file.json>` (the help topics in this process's language, for the site; add
///   `-AppleLanguages "(en)"` for another one — scripts/export-help.sh)
/// - `AIHubBar --resources` (one reading of «Ресурсы Mac»: processor, memory, disk, network, battery, graphics, top apps)
/// - `AIHubBar --readiness [file.png]` (what this Mac still needs, as on the assistant's first screen; exit 1 if something is left)
/// One command-line command (`CommandLineTool.commands`).
@MainActor
struct CLICommand {
    let flags: [String]
    /// Values that must follow the flag; without them the next command is tried.
    let needs: Int
    let usage: String
    let run: @MainActor ([String], Int) -> Int32

    init(_ flags: [String], needs: Int, usage: String, run: @escaping @MainActor ([String], Int) -> Int32) {
        self.flags = flags
        self.needs = needs
        self.usage = usage
        self.run = run
    }
}

@MainActor
enum CommandLineTool {
    /// Returns an exit code if the arguments contain a command, `nil` to start the app normally.
    static func run(_ arguments: [String]) -> Int32? {
        if arguments.contains("--help") {
            print("AIHubBar <command>\n" + commands.map { "  " + $0.usage }.joined(separator: "\n"))
            return 0
        }
        // In order: the first command whose flag is there and has its values runs (as the old `if` chain did).
        for command in commands {
            guard let index = command.flags.lazy.compactMap({ arguments.firstIndex(of: $0) }).first,
                  index + command.needs < arguments.count else { continue }
            return command.run(arguments, index)
        }
        return nil
    }

    /// Every command: its flags, how many values must follow the flag, the usage line for `--help`, and what it does
    /// (SPEC-refactor §6 — it was one `if` chain).
    static var commands: [CLICommand] {
        [
            CLICommand(["--login-item"], needs: 0, usage: "--login-item status|on|off  start at login") { arguments, index in
                return loginItem(arguments.dropFirst(index + 1).first ?? "status")
            },
            CLICommand(["--claude"], needs: 0, usage: "--claude next|finish|task <project> [task] [--claude-path <path>] [--print] [--background]") { arguments, index in
                return claude(Array(arguments.dropFirst(index + 1)))
            },
            CLICommand(["--hooks"], needs: 0, usage: "--hooks [status|install|uninstall]  Claude Code session hooks") { arguments, index in
                return hooks(arguments.dropFirst(index + 1).first ?? "status")
            },
            CLICommand(["--copilot-hooks"], needs: 0, usage: "--copilot-hooks [status|install|uninstall]  Copilot CLI session states") { arguments, index in
                let hooks = CopilotHooks.live(projectsDirectory: AppSettings().projectsDirectory)
                do {
                    switch arguments.dropFirst(index + 1).first ?? "status" {
                    case "status": break
                    case "install": try hooks.install()
                    case "uninstall": try hooks.uninstall()
                    default:
                        printError("Usage: AIHubBar --copilot-hooks [status|install|uninstall]")
                        return 2
                    }
                } catch {
                    printError(error.localizedDescription)
                    return 1
                }
                print("copilot hooks: \(hooks.status()) (\(hooks.fileURL.path))")
                return 0
            },
            CLICommand(["--codex-hooks"], needs: 0, usage: "--codex-hooks [status|install|uninstall]  Codex CLI session states") { arguments, index in
                let hooks = CodexHooks.live(projectsDirectory: AppSettings().projectsDirectory)
                do {
                    switch arguments.dropFirst(index + 1).first ?? "status" {
                    case "status": break
                    case "install": try hooks.install()
                    case "uninstall": try hooks.uninstall()
                    default:
                        printError("Usage: AIHubBar --codex-hooks [status|install|uninstall]")
                        return 2
                    }
                } catch {
                    printError(error.localizedDescription)
                    return 1
                }
                print("codex hooks: \(hooks.status()) (\(hooks.fileURL.path)); Codex runs them once trusted in /hooks")
                return 0
            },
            CLICommand(["--app-command"], needs: 1, usage: "--app-command <command>  ask the running app (help, settings, assistant, cleanup-output, notch-setup, usage-history, quick-prompt, test-notification, test-island, report, summary…)") { arguments, index in
                let name = arguments[index + 1]
                let known = Array(AppRequests.windows.keys) + AppRequests.actions + CommonCommand.allCases.map(\.cliName)
                guard known.contains(name) else {
                    printError("Usage: AIHubBar --app-command " + known.sorted().joined(separator: "|"))
                    return 2
                }
                AppRequests.post(name)
                print("sent \(name) to the running app")
                return 0
            },
            CLICommand(["--command"], needs: 1, usage: "--command report|summary|cleanup-check|cleanup  a _daily-report command, in this process") { arguments, index in
                guard let command = CommonCommand.allCases.first(where: { $0.cliName == arguments[index + 1] }),
                      command.script != nil else {
                    printError("Usage: AIHubBar --command " + CommonCommand.allCases.filter { $0.script != nil }.map(\.cliName).joined(separator: "|"))
                    return 2
                }
                let directory = AppSettings().dailyReportDirectory
                return waitFor {
                    let (result, _) = await CommandStore.execute(command, dailyReportDirectory: directory)
                    print("\(result.isError ? "error" : "ok"): \(result.text)")
                    return result.isError ? 1 : 0
                }
            },
            CLICommand(["--usage-raw", "--usage"], needs: 0, usage: "--usage | --usage-raw  subscription limits (the token is never printed)") { arguments, index in
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
            },
            CLICommand(["--token-usage"], needs: 0, usage: "--token-usage  tokens by project") { arguments, index in
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
            },
            CLICommand(["--modes"], needs: 0, usage: "--modes  profiles and modules") { arguments, index in
                let modes = ProfileStore(settings: AppSettings(), readOnly: true)
                for mode in modes.modes {
                    let flags = (mode.id == modes.currentID ? "*" : " ") + (modes.enabledIDs.contains(mode.id) ? "on " : "off")
                    print("\(flags)  \(mode.name)  [\(mode.template)]  \(mode.source.title): \(mode.source.folder ?? "-")")
                    let modules = (mode.modules ?? []).map { $0.kind.rawValue + ($0.shown ? "" : " (hidden)") }
                    print("       modules: \(modules.joined(separator: ", "))")
                }
                print("installed: \(modes.installedModules.map(\.rawValue).joined(separator: ", "))")
                print("off: \(modes.switchedOff.map(\.rawValue).joined(separator: ", "))")
                return 0
            },
            CLICommand(["--export-settings"], needs: 1, usage: "--export-settings <file.claudepult>") { arguments, index in
                let url = URL(fileURLWithPath: (arguments[index + 1] as NSString).expandingTildeInPath)
                do {
                    try ProfileStore.encode(ProfileStore(settings: AppSettings(), readOnly: true).exportBundle()).write(to: url, options: .atomic)
                    print("exported to \(url.path)")
                    return 0
                } catch {
                    printError("error: \(error.localizedDescription)")
                    return 1
                }
            },
            CLICommand(["--assistant-preview"], needs: 1, usage: "--assistant-preview <file.png> [template|welcome] [--dark]  the assistant's right side with sample data") { arguments, index in
                let id = arguments.dropFirst(index + 2).first
                let dark = arguments.contains("--dark")
                var draft = AssistantDraft(firstLaunch: id == "welcome", menuBar: .make(.limits), reminderHours: [24])
                if id != "welcome" { draft.choose(ProfileTemplate.loadAll().first { $0.id == id }) }
                let renderer = ImageRenderer(content: AssistantSidePane(draft: draft, animated: false).frame(width: 430, height: 620)
                    .background(Color(white: dark ? 0.15 : 0.95))
                    .environment(\.colorScheme, dark ? .dark : .light)
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
            },
            CLICommand(["--git-scan"], needs: 1, usage: "--git-scan <folder>  the built-in git scanner") { arguments, index in
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
            },
            CLICommand(["--calendar"], needs: 0, usage: "--calendar [folder] [template]  calendar dates") { arguments, index in
                let infos: [CalendarScanner.ProfileInfo]
                if index + 1 < arguments.count {
                    let template = ProfileTemplate.loadAll().first { $0.id == arguments.dropFirst(index + 2).first }
                    infos = [.init(id: "cli", name: "папка", icon: "folder", source: .folders(arguments[index + 1]), calendar: .contentPlan, doneStage: template?.mode.doneStage)]
                } else {
                    let modes = ProfileStore(settings: AppSettings(), readOnly: true)
                    infos = modes.enabledModes.map { .init(id: $0.id, name: $0.name, icon: $0.icon, source: $0.source, calendar: $0.calendar, doneStage: $0.doneStage) }
                }
                let entries = CalendarScanner.entries(for: infos).sorted { $0.date < $1.date }
                for entry in entries {
                    let when = CalendarScanner.text(entry.date, withTime: entry.hasTime)
                    print("\(when)  \(entry.kind.rawValue)  \(entry.title)" + (entry.detail.map { "  (\($0))" } ?? "")
                          + "  — \(CalendarText.relative(entry.date, hasTime: entry.hasTime))" + (entry.isOverdue() ? "  OVERDUE" : ""))
                }
                if entries.isEmpty { print("no calendar dates") }
                return 0
            },
            CLICommand(["--folder-projects"], needs: 1, usage: "--folder-projects <folder> [template]  folder projects as the panel lists them") { arguments, index in
                let template = ProfileTemplate.loadAll().first { $0.id == arguments.dropFirst(index + 2).first }
                let projects = FolderScanner.scan(source: .folders(arguments[index + 1]), resultPatterns: template?.mode.resultPatterns ?? [])
                for project in projects {
                    let metrics = FolderMetric.allCases.compactMap { metric in metric.text(for: project, wordsPerMinute: 150).map { "\(metric.rawValue)=\($0)" } }
                    print("\(project.name)  [\(project.card.stage ?? "—")]  main=\(project.mainFile ?? "—")  " + metrics.joined(separator: "  "))
                }
                if projects.isEmpty { print("no folder projects in \(arguments[index + 1])") }
                return 0
            },
            CLICommand(["--api-complete"], needs: 2, usage: "--api-complete <provider> <prompt> [base-url]  one request to a model by API") { arguments, index in
                guard let provider = APIProvider(rawValue: arguments[index + 1]) else {
                    printError("Usage: AIHubBar --api-complete " + APIProvider.allCases.map(\.rawValue).joined(separator: "|") + " <prompt> [base-url]")
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
            },
            CLICommand(["--services"], needs: 0, usage: "--services [check|limits]  agents, API keys, limits") { arguments, index in
                if arguments.dropFirst(index + 1).first == "limits" { return limitsReport() }
                return servicesReport(check: arguments.dropFirst(index + 1).first == "check")
            },
            CLICommand(["--help-export"], needs: 1, usage: "--help-export <file.json>  the help topics as JSON (-AppleLanguages \"(en)\" for another language)") { arguments, index in
                return helpExport(path: (arguments[index + 1] as NSString).expandingTildeInPath)
            },
            CLICommand(["--menubar-preview"], needs: 1, usage: "--menubar-preview <file.png> [minimum|limits|everything]") { arguments, index in
                return menuBarPreview(path: arguments[index + 1], preset: arguments.dropFirst(index + 2).first)
            },
            CLICommand(["--resources"], needs: 0, usage: "--resources  one reading of «Ресурсы Mac»") { arguments, index in
                var sampler = SystemSampler()
                _ = sampler.sample()
                Thread.sleep(forTimeInterval: 1)
                let s = sampler.sample()
                print(String(format: "cpu: %.0f %%", s.cpu))
                print("memory: \(ResourceText.memory(s.memoryUsed)) of \(ResourceText.memory(s.memoryTotal)) (\(Int(s.memoryPercent.rounded())) %), pressure \(s.pressure)")
                print("disk: \(ResourceText.bytes(s.diskFree)) free of \(ResourceText.bytes(s.diskTotal))")
                print("network: in \(ResourceText.speed(s.networkIn)), out \(ResourceText.speed(s.networkOut))")
                print("battery: " + (s.battery.map { "\($0.percent) %, charging \($0.charging), on AC \($0.onAC), minutes left \($0.minutesLeft.map(String.init) ?? "-")" } ?? "none"))
                print("gpu: " + (s.gpu.map { String(format: "%.0f %%", $0) } ?? "not reported"))
                return waitFor {
                    for process in await SystemMonitor.topProcesses() { print(String(format: "top: %5.1f %%  %@", process.cpu, process.name)) }
                    return 0
                }
            },
            CLICommand(["--readiness"], needs: 0, usage: "--readiness [file.png]  what this Mac still needs") { arguments, index in
                return readiness(png: arguments.dropFirst(index + 1).first { $0.hasSuffix(".png") })
            },
            CLICommand(["--notifications-status"], needs: 0, usage: "--notifications-status") { arguments, index in
                return waitFor {
                    let settings = await UNUserNotificationCenter.current().notificationSettings()
                    let names: [UNAuthorizationStatus: String] = [.notDetermined: "notDetermined", .denied: "denied", .authorized: "authorized", .provisional: "provisional"]
                    print("notifications: \(names[settings.authorizationStatus] ?? "unknown(\(settings.authorizationStatus.rawValue))"), alerts: \(settings.alertSetting == .enabled)")
                    return settings.authorizationStatus == .authorized ? 0 : 1
                }
            },
            CLICommand(["--background-settings"], needs: 0, usage: "--background-settings [code|filesOnly|filesAndWeb]") { arguments, index in
                let profile = arguments.dropFirst(index + 1).first.flatMap(PermissionProfile.init(rawValue:)) ?? .code
                print(BackgroundPermissions.settingsJSON(profile))
                return 0
            },
            CLICommand(["--sessions"], needs: 0, usage: "--sessions  Claude Code sessions on this Mac") { arguments, index in
                for item in SessionStore.loadItems(from: SessionFiles.sessionsDirectory, now: .now) {
                    let s = item.session
                    print([s.id, item.state.rawValue, s.displayProject, s.worktreeName ?? "-", s.tty ?? "-", s.task ?? "-"].joined(separator: "\t"))
                }
                return 0
            },
            CLICommand(["--show-session"], needs: 1, usage: "--show-session <id>  bring a session to the front") { arguments, index in
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
            },
        ]
    }
}
