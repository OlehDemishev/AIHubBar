import AppKit
import Foundation
import SwiftUI
import UserNotifications

/// What the command-line commands do (`CommandLineTool.commands` lists them).
extension CommandLineTool {
    static func hooks(_ action: String) -> Int32 {
        let installer = HookInstaller.live(projectsDirectory: AppSettings().projectsDirectory)
        do {
            switch action {
            case "status": break
            case "install":
                if let backup = try installer.install() { print("backup: \(backup.path)") }
            case "uninstall":
                if let backup = try installer.uninstall() { print("backup: \(backup.path)") }
            default:
                printError("Usage: AIHubBar --hooks [status|install|uninstall]")
                return 2
            }
        } catch {
            printError("error: \(error.localizedDescription)")
            return 1
        }
        print("hooks: \(installer.status())")
        return 0
    }

    static func loginItem(_ action: String) -> Int32 {
        let controller = LoginItemController()
        switch action {
        case "status": break
        case "on": controller.setEnabled(true)
        case "off": controller.setEnabled(false)
        default:
            printError("Usage: AIHubBar --login-item [status|on|off]")
            return 2
        }

        print("login-item: \(controller.state)")
        if let error = controller.lastError {
            printError("error: \(error)")
            return 1
        }
        return 0
    }

    static func claude(_ arguments: [String]) -> Int32 {
        var args = arguments
        let printOnly = args.contains("--print")
        let background = args.contains("--background")
        args.removeAll { $0 == "--print" || $0 == "--background" }
        var configuredPath = AppSettings().claudePath
        if let index = args.firstIndex(of: "--claude-path"), index + 1 < args.count {
            configuredPath = args[index + 1]
            args.removeSubrange(index...index + 1)
        }

        let usage = "Usage: AIHubBar --claude next|finish|task <project-path> [task text] [--claude-path <path>] [--print] [--background]"
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

    /// Starts a background run; the running AI Hub Bar app picks it up and reports the result.
    static func launchInBackground(_ request: LaunchRequest) -> Int32 {
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
    static func waitFor(_ work: @escaping @Sendable () async throws -> Int32) -> Int32 {
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

    nonisolated static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    /// Keys are never printed — only whether one is stored and what the check says.
    static func servicesReport(check: Bool) -> Int32 {
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

    /// What the panel would show for each service found by its tool (Codex, Copilot, Gemini, Cursor): limits, notes
    /// (plan, credits, context) and tokens per project, then the other agents' recent conversations — for live checks
    /// of SPEC-ai-services stages 3–6. Keys aren't read.
    static func limitsReport() -> Int32 {
        // Read here: `AppSettings` belongs to the main thread, which `waitFor` blocks.
        let settings = AppSettings()
        let geminiLimit = settings.hubGeminiDailyLimit, geminiQuota = settings.hubGeminiQuota
        return waitFor {
            for source in HubLimit.Source.allCases where source.keychainAccount == nil {
                guard HubLimitsStore.toolPresent(source) else { print("\(source.rawValue): not found"); continue }
                let limit = await HubLimitsStore.read(source, geminiDailyLimit: geminiLimit, geminiQuota: geminiQuota)
                print("\(source.rawValue):" + (limit.error.map { " error: \($0)" } ?? ""))
                for window in limit.windows {
                    print("  window \(window.title): " + [window.percent.map { "\($0) %" }, window.detail, window.resetsAt.map { "resets \($0.ISO8601Format())" }].compactMap { $0 }.joined(separator: ", "))
                }
                for note in limit.notes { print("  note \(note.text)") }
                for project in limit.projects { print("  project \(project.name): \(project.tokens) tokens") }
            }
            // The other agents' recent conversations, as «Сессии» lists them.
            for thread in AgentThread.recent() {
                let context = thread.context.map { ", context \(Int(($0 * 100).rounded())) %" } ?? ""
                print("thread \(thread.agent.binary) \(thread.project): \(thread.title)\(thread.isWorking ? ", running" : "")\(context)")
            }
            return 0
        }
    }

    /// Windows take the direction from NSApp; the offscreen renderer has to be told (Arabic is right-to-left).
    static var layoutDirection: LayoutDirection {
        Locale.Language(identifier: ContentLanguage.current.rawValue).characterDirection == .rightToLeft ? .rightToLeft : .leftToRight
    }

    /// The readiness rows for this Mac; with a path, also drawn as the assistant's first screen shows them.
    static func readiness(png path: String?) -> Int32 {
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

    /// The help window's content as JSON (docs/specs/SPEC-help.md §4): the site's help page renders the same topics.
    static func helpExport(path: String) -> Int32 {
        let data = HelpExport.make()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try encoder.encode(data).write(to: URL(fileURLWithPath: path), options: .atomic)
            print("\(path): \(data.topics.count) topics, \(data.language)")
            return 0
        } catch {
            printError(error.localizedDescription)
            return 1
        }
    }

    /// Draws the item as the menu bar would (dark and light) from the saved config, or from a preset.
    static func menuBarPreview(path: String, preset: String?) -> Int32 {
        let config = preset.flatMap(MenuBarConfig.Preset.init(rawValue:)).map(MenuBarConfig.make) ?? AppSettings().menuBarConfig
        let item = MenuBarRenderer.image(MenuBarComposer.strip(config, .sample), config: config)
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
            print("\(path): \(Int(item.size.width)) pt wide, \(MenuBarComposer.groups(config, .sample).count) element(s)")
            return 0
        } catch {
            printError(error.localizedDescription)
            return 1
        }
    }
}

/// Written by the detached task before `signal()`, read after `wait()`.
final class ReadinessBox: @unchecked Sendable {
    var input: Readiness.Input?
}

final class ExitCode: @unchecked Sendable {
    var value: Int32 = 0
}

final class FolderBox: @unchecked Sendable {
    var value: (String, WorktreePlan?)?
}
