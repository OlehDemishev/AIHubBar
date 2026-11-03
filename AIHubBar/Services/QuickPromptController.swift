import AppKit
import ApplicationServices
import Observation

/// «Быстрый запрос» (docs/specs/SPEC-quick-prompt.md): the hot key while the module is on, what was in front when it
/// was pressed, and sending the task — Claude Code through the projects' own launch, other agents in Terminal.
@MainActor
@Observable
final class QuickPromptController {
    @ObservationIgnored var isActive: () -> Bool = { false }
    /// Opens the window; set by the container (windows are opened by the menu bar label).
    @ObservationIgnored var openWindow: (() -> Void)?
    /// Opens the module's Settings page.
    @ObservationIgnored var openSettings: (() -> Void)?

    /// What was in front at the last open: the window picks its project from it.
    private(set) var front: FrontContext?
    /// Grows with every open, so a window that is already on screen starts over.
    private(set) var opened = 0
    /// The answer of a request that went to another agent; Claude Code's answer is the launcher's.
    private(set) var note: LaunchController.Message?

    private let settings: AppSettings
    private let launcher: LaunchController
    private let services: AIServiceStore
    @ObservationIgnored private var registered: QuickPromptHotKey?

    init(settings: AppSettings, launcher: LaunchController, services: AIServiceStore) {
        self.settings = settings
        self.launcher = launcher
        self.services = services
    }

    /// Registers the hot key and follows the module switch and the key setting from then on.
    func start() {
        GlobalHotKey.quickPromptAction = { [weak self] in self?.show() }
        sync()
    }

    private func sync() {
        let key = withObservationTracking {
            isActive() ? settings.quickPrompt.hotKey : .off
        } onChange: { [weak self] in
            Task { @MainActor in self?.sync() }
        }
        guard key != registered else { return }
        registered = key
        GlobalHotKey.registerQuickPrompt(key)
    }

    /// The hot key and `--app-command quick-prompt`: reads what is in front, then brings the window up. With the
    /// module off it opens its Settings page instead.
    func show() {
        guard isActive() else {
            AppLog.info("Quick prompt asked for while its module is off: opening its page")
            openSettings?()
            return
        }
        front = Self.readFront()
        note = nil
        opened += 1
        AppLog.info("Quick prompt opened over \(front?.bundleID ?? "nothing")")
        NSApp.activate()
        openWindow?()
    }

    /// Sends the task. The window learns how a Claude Code launch went from the launcher's state for the project.
    func send(_ text: String, project: Project, agent: AgentKind, mode: LaunchMode) {
        settings.quickPrompt.lastProject = project.path
        note = nil
        let command = ClaudeCommand.customTask(text)
        if agent == .claudeCode {
            settings.quickPrompt.lastMode = mode.rawValue
            AppLog.info("Quick prompt → Claude Code (\(mode.rawValue)) in \(project.name)")
            launcher.launch(command, in: project, mode: mode)
            return
        }
        guard let path = services.agents[agent]?.path else {
            note = LaunchController.Message(text: String(localized: "\(agent.title) не установлен"), isError: true)
            return
        }
        // Other agents only in Terminal, as «Открыть в…»: the agent opens in the folder, the task waits on the clipboard.
        let prompt = command.prompt(settings.promptStyle, rulesFile: PathText.tilde(settings.projectsDirectory + "/CLAUDE.md"))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        note = LaunchController.Message(text: String(localized: "\(agent.title) открыт в Терминале — задача скопирована, вставьте ⌘V"))
        Task {
            do {
                try await TerminalLauncher.run(agent.terminalCommandLine(folder: project.path, path: path))
                AppLog.info("Quick prompt → \(agent.binary) in Terminal: \(project.name)")
            } catch {
                note = LaunchController.Message(text: error.localizedDescription, isError: true)
                AppLog.error("Quick prompt → \(agent.binary) failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - What is in front

    /// The front app, and — only when Accessibility is already granted (for «Раскладка») — its front window's
    /// document and title. Nothing is asked for.
    static func readFront() -> FrontContext? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        var context = FrontContext(bundleID: app.bundleIdentifier)
        guard AXIsProcessTrusted() else { return context }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        // A busy app must not hold up the hot key.
        AXUIElementSetMessagingTimeout(element, 0.3)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return context }
        let window = unsafeDowncast(value, to: AXUIElement.self)
        context.windowTitle = string(window, kAXTitleAttribute)
        if let document = string(window, kAXDocumentAttribute), let url = URL(string: document), url.isFileURL {
            context.documentPath = url.path
        }
        return context
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
