import SwiftUI

/// «Claude» block of an expanded project: the three commands, the custom-task field and the launch result.
struct ClaudeActionsView: View {
    let project: Project

    @Environment(LaunchController.self) private var launcher
    @Environment(AIServiceStore.self) private var services
    @State private var isEditingTask = false
    @State private var task = ""
    @State private var rememberMode = false
    @FocusState private var taskFocused: Bool

    private var isWorking: Bool { launcher.working.contains(project.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Claude")
                    .scaledFont(.caption, weight: .semibold)
                    .foregroundStyle(.secondary)
                if isWorking {
                    ProgressView().controlSize(.mini)
                }
                Spacer()
                otherAgents
            }

            HStack(spacing: 6) {
                ActionButton(title: String(localized: "Следующий шаг"), systemImage: "forward.fill", isProminent: true) {
                    launcher.request(.nextStep, in: project)
                }
                .help(project.status?.summary?.next.first.map { String(localized: "Первый пункт Next: \($0)") } ?? String(localized: "Первый пункт Next из STATUS.md"))
                ActionButton(title: String(localized: "Своя задача…"), systemImage: "text.cursor") {
                    withAnimation(.snappy(duration: 0.2)) { isEditingTask.toggle() }
                    taskFocused = isEditingTask
                }
                ActionButton(title: String(localized: "Завершить"), systemImage: "checkmark.circle") {
                    launcher.request(.finishSession, in: project)
                }
                .help("Завершить сессию: проверки, коммит, push, PR и STATUS по разделу «Конец сессии»")
                ActionButton(title: String(localized: "На ночь"), systemImage: "moon.zzz") {
                    launcher.queueForNight(.nextStep, in: project)
                }
                .help("Следующий шаг — в фоне ночью; утром сводка. Свою задачу на ночь — в «Своя задача…»")
            }
            .disabled(isWorking)

            if isEditingTask {
                taskEditor
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }

            if let command = launcher.pendingModeChoice[project.id] {
                modeChooser(command)
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }

            if let message = launcher.messages[project.id] {
                messageView(message)
                    .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.2), value: launcher.messages[project.id])
        .animation(.snappy(duration: 0.2), value: launcher.pendingModeChoice[project.id])
    }

    /// Other installed agents open in Terminal in the project folder (SPEC-modes §11).
    @ViewBuilder private var otherAgents: some View {
        let installed = AgentKind.allCases.filter { $0 != .claudeCode && services.agents[$0] != nil }
        if !installed.isEmpty {
            Menu {
                ForEach(installed, id: \.self) { kind in
                    Button(kind.title) {
                        guard let path = services.agents[kind]?.path else { return }
                        Task {
                            do {
                                try await TerminalLauncher.run(kind.terminalCommandLine(folder: project.path, path: path))
                                AppLog.info("Opened \(kind.binary) in Terminal: \(project.path)")
                            } catch {
                                AppLog.error("Opening \(kind.binary) failed: \(error.localizedDescription)")
                            }
                        }
                    }
                }
            } label: {
                Text("Открыть в…").scaledFont(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Открыть другой агент в Терминале, в папке проекта")
        }
    }

    private func modeChooser(_ command: ClaudeCommand) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Где запустить «\(command.title)»?")
                .scaledFont(.caption, weight: .medium)
            HStack(spacing: 6) {
                ActionButton(title: LaunchMode.terminal.title, systemImage: "terminal", isProminent: true) {
                    launcher.choose(.terminal, remember: rememberMode, in: project)
                }
                .help("Новое окно Терминала: видно, что делает Claude, можно отвечать на вопросы")
                ActionButton(title: LaunchMode.background.title, systemImage: "moon.zzz", isProminent: true) {
                    launcher.choose(.background, remember: rememberMode, in: project)
                }
                .help("claude -p без окна: только разрешённые действия, итог — уведомлением и в Telegram")
                Spacer(minLength: 4)
                Button("Отмена") { launcher.cancelModeChoice(in: project) }
                    .controlSize(.small)
            }
            Toggle("Запомнить выбор", isOn: $rememberMode)
                .toggleStyle(.checkbox)
                .scaledFont(.caption)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
    }

    private var taskEditor: some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextField("Что сделать в \(project.name)?", text: $task, axis: .vertical)
                .lineLimit(2...6)
                .textFieldStyle(.roundedBorder)
                .scaledFont(.callout)
                .focused($taskFocused)
            HStack(spacing: 6) {
                Button("Отмена") {
                    withAnimation(.snappy(duration: 0.2)) { isEditingTask = false }
                }
                .keyboardShortcut(.cancelAction)
                Button("На ночь") {
                    launcher.queueForNight(.customTask(task), in: project)
                    task = ""
                    withAnimation(.snappy(duration: 0.2)) { isEditingTask = false }
                }
                .help("Запустить в фоне ночью; утром придёт сводка")
                .disabled(task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
                Button("Запустить") {
                    launcher.request(.customTask(task), in: project)
                    task = ""
                    withAnimation(.snappy(duration: 0.2)) { isEditingTask = false }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
            }
            .controlSize(.small)
        }
    }

    private func messageView(_ message: LaunchController.Message) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(message.text).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: message.isError ? "exclamationmark.triangle.fill" : "info.circle")
                    .foregroundStyle(message.isError ? .red : .secondary)
            }
            .scaledFont(.caption)

            HStack(spacing: 6) {
                if launcher.pendingConfirmation[project.id] != nil {
                    Button("Запустить всё равно") { launcher.confirmPending(in: project) }
                }
                if launcher.pendingLimit[project.id] != nil {
                    Button("Запустить после сброса") { launcher.launchAfterReset(in: project) }
                    Button("Запустить сейчас") { launcher.launchDespiteLimit(in: project) }
                }
                if message.isError, message.text.contains(String(localized: "Автоматизация")) {
                    Button("Открыть настройки") { LaunchController.openAutomationSettings() }
                }
                Button("Скрыть") { launcher.dismissMessage(for: project) }
            }
            .controlSize(.mini)
        }
    }
}

/// Worktrees of a project with «Удалить worktree» (only when clean and pushed; checked on click).
struct WorktreeListView: View {
    let project: Project

    @Environment(LaunchController.self) private var launcher

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Worktree")
                .scaledFont(.caption, weight: .semibold)
                .foregroundStyle(.secondary)
            ForEach(project.worktrees, id: \.path) { worktree in
                row(worktree)
            }
        }
    }

    private func row(_ worktree: Worktree) -> some View {
        let state = launcher.worktreeStates[worktree.path]
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(.tertiary)
                VStack(alignment: .leading, spacing: 0) {
                    Text((worktree.path as NSString).lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text([worktree.branch, (worktree.dirty ?? 0) > 0 ? String(localized: "изменено файлов: \(worktree.dirty ?? 0)") : nil]
                        .compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                switch state {
                case .checking, .removing:
                    ProgressView().controlSize(.mini)
                case .confirm:
                    Button("Отмена") { launcher.cancelWorktreeRemoval(worktree) }
                    Button("Удалить?") { launcher.removeWorktree(worktree, of: project) }
                        .tint(.red)
                case nil, .blocked:
                    Button {
                        launcher.removeWorktree(worktree, of: project)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("Удалить worktree (только если нет незакоммиченного и ветка запушена)")
                }
            }
            if case let .blocked(reason) = state {
                Text(reason)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
            }
        }
        .scaledFont(.caption)
        .controlSize(.mini)
        .buttonStyle(.bordered)
    }
}
