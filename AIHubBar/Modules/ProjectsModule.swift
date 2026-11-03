import AppKit
import SwiftUI

// «Проекты» (docs/specs/SPEC-refactor.md §3): what the module is, its Settings sections and its «Панель сейчас» line.

extension ModuleDefinition {
    static let projects = ModuleDefinition(
        kind: .projects,
        group: .work,
        symbol: "folder",
        title: String(localized: "Проекты"),
        summary: String(localized: "Проекты профиля: git-репозитории или папки, карточки, команды. Настраиваются в профиле."),
        tagline: String(localized: "Репозитории и папки, PR, команды"),
        isBuiltIn: true,
        places: [.panel, .menuBar, .notifications, .telegram],
        menuBarKinds: [.projectsAlert],
        primaryMenuBarKinds: [.projectsAlert],
        notifications: [.pullRequests],
        telegram: .pullRequests,
        bringIn: .profilePage,
        keywords: ["Pull requests", "CI"]
    )
}

extension ModuleUI {
    static let projects = ModuleUI(
        settings: { AnyView(PullRequestAlertSection()) },
        sketch: { AnyView(ProjectsSketch()) }
    )
}

/// «Панель сейчас»: how many projects, how many with problems.
private struct ProjectsSketch: View {
    @Environment(ProjectStore.self) private var store

    var body: some View {
        let red = store.projects.filter { $0.health == .red }.count
        SketchLine(store.projects.isEmpty ? ModuleKind.projects.tagline : String(localized: "Проектов: \(store.projects.count) · с проблемами: \(red)"))
    }
}

/// Notifications about open pull requests of the projects.
struct PullRequestAlertSection: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Section {
            Toggle("Уведомлять, когда CI упал или починился и когда PR закрыт", systemImage: "arrow.triangle.pull", isOn: $settings.pullRequestAlerts)
            Toggle("Дублировать в Telegram", systemImage: "paperplane", isOn: $settings.pullRequestAlertsToTelegram)
                .disabled(!settings.pullRequestAlerts)
        } header: {
            Text("Pull requests")
        } footer: {
            Footnote(text: String(localized: "По данным списка проектов (gh): обновляется раз в 5 минут и при открытии панели. Клик по уведомлению открывает PR."))
        }
    }
}
