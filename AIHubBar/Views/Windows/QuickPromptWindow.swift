import AppKit
import SwiftUI

/// «Быстрый запрос» (docs/specs/SPEC-quick-prompt.md): a small window over every other one — the task, the project,
/// the agent and where it runs. ⌘↩ sends, Esc closes; it closes by itself once the task is on its way.
struct QuickPromptWindow: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings
    @Environment(ProjectStore.self) private var store
    @Environment(AIServiceStore.self) private var services
    @Environment(LaunchController.self) private var launcher
    @Environment(AppRequests.self) private var requests
    @Environment(QuickPromptController.self) private var quickPrompt
    @State private var text = ""
    @State private var projectPath: String?
    @State private var agent: AgentKind = .claudeCode
    @State private var mode: LaunchMode = .background
    /// The project a Claude Code launch went to: the window waits for its answer there.
    @State private var sentPath: String?
    @FocusState private var focused: Bool

    private var project: Project? { store.projects.first { $0.path == projectPath } }
    private var agents: [AgentKind] { QuickPrompt.agents(installed: Set(services.agents.keys)) }
    private var isLaunching: Bool { sentPath.map(launcher.working.contains) ?? false }
    private var canSend: Bool {
        QuickPrompt.canSend(text, project: project?.path) && !isLaunching && !launcher.working.contains(projectPath ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Label("Быстрый запрос", systemImage: ModuleKind.quickPrompt.symbol)
                    .font(.headline)
                Spacer()
                Button {
                    SettingsRoute.open(module: .quickPrompt)
                    requests.openWindow(.settings)
                    dismiss()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Настройки быстрого запроса")
                .accessibilityLabel("Настройки быстрого запроса")
            }
            TextField("Что сделать?", text: $text, axis: .vertical)
                .lineLimit(3...8)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .accessibilityLabel("Задача")
            if store.projects.isEmpty {
                Label("Нет git-проектов: укажите папку с проектами в профиле — Настройки → «Профили».", systemImage: "folder.badge.questionmark")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Picker("Проект", selection: $projectPath) {
                    ForEach(store.projects) { Text($0.name).tag(Optional($0.path)) }
                }
                .disabled(store.projects.isEmpty)
                Picker("Агент", selection: $agent) {
                    ForEach(agents, id: \.self) { Text($0.title).tag($0) }
                }
                .fixedSize()
            }
            HStack(spacing: 8) {
                Picker("Где запустить", selection: $mode) {
                    ForEach(QuickPrompt.modes(for: agent), id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help(agent == .claudeCode
                    ? String(localized: "Фон — claude -p без окна, итог уведомлением; Терминал — новое окно, можно отвечать Claude")
                    : String(localized: "Другие агенты — только в Терминале: задача в буфере обмена, вставьте ⌘V"))
                if isLaunching { ProgressView().controlSize(.small) }
                Spacer()
                Button("Отмена") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Отправить") { send() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSend)
            }
            answer
        }
        .padding(16)
        .frame(width: 540)
        .background(WindowReader { window in
            // Over every app, on whichever Space is current, also next to a full-screen app.
            window?.level = .floating
            window?.collectionBehavior.formUnion([.moveToActiveSpace, .fullScreenAuxiliary])
        })
        .onAppear(perform: reset)
        .onChange(of: quickPrompt.opened) { reset() }
        .onChange(of: agent) {
            mode = QuickPrompt.mode(for: agent, last: mode, preferred: settings.defaultLaunchMode)
        }
        .onChange(of: isLaunching) {
            if !isLaunching { closeIfLaunched() }
        }
        .task(id: quickPrompt.note) {
            // Another agent opened in Terminal: long enough to read where the task is.
            guard let note = quickPrompt.note, !note.isError else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { dismiss() }
        }
    }

    /// How the request went, and the launcher's questions («Запустить всё равно», the limit).
    @ViewBuilder private var answer: some View {
        if let path = sentPath, !isLaunching, let message = launcher.messages[path], let project {
            VStack(alignment: .leading, spacing: 6) {
                messageLabel(message)
                HStack(spacing: 6) {
                    if launcher.pendingConfirmation[path] != nil {
                        Button("Запустить всё равно") { followUp { launcher.confirmPending(in: project) } }
                    }
                    if launcher.pendingLimit[path] != nil {
                        Button("Запустить после сброса") { followUp { launcher.launchAfterReset(in: project) } }
                        Button("Запустить сейчас") { followUp { launcher.launchDespiteLimit(in: project) } }
                    }
                }
                .controlSize(.small)
            }
        } else if let note = quickPrompt.note {
            messageLabel(note)
        }
    }

    private func messageLabel(_ message: LaunchController.Message) -> some View {
        Label {
            Text(message.text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: message.isError ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(message.isError ? .red : .secondary)
        }
        .font(.callout)
    }

    /// A new request: empty text, Claude Code, the project in front (or the last one).
    private func reset() {
        text = ""
        sentPath = nil
        agent = .claudeCode
        let candidates = store.projects.map { QuickPrompt.Candidate(name: $0.name, path: $0.path, lastActivity: $0.lastActivity) }
        projectPath = QuickPrompt.defaultProject(candidates, front: quickPrompt.front, last: settings.quickPrompt.lastProject)
        mode = QuickPrompt.mode(for: agent, last: settings.quickPrompt.lastMode.flatMap(LaunchMode.init(rawValue:)),
                                preferred: settings.defaultLaunchMode)
        focused = true
    }

    private func send() {
        guard canSend, let project else { return }
        let task = text
        quickPrompt.send(task, project: project, agent: agent, mode: mode)
        guard agent == .claudeCode else { return }
        sentPath = project.path
        if !isLaunching { closeIfLaunched() }
    }

    private func followUp(_ action: () -> Void) {
        action()
        if !isLaunching { closeIfLaunched() }
    }

    /// The launch is under way and asks nothing: the window has done its job (its message shows in the project too).
    private func closeIfLaunched() {
        guard let path = sentPath else { return }
        let asks = launcher.pendingConfirmation[path] != nil || launcher.pendingLimit[path] != nil
        if !asks, launcher.messages[path]?.isError != true { dismiss() }
    }
}
