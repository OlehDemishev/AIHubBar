import AppKit
import Observation
import SwiftUI

// «Версии» (docs/specs/SPEC-content.md §4, §6): what the module is, its settings, the service that takes the versions
// and its Settings sections. The versions themselves are `VersionStore`.

extension ModuleDefinition {
    static let versions = ModuleDefinition(
        kind: .versions,
        group: .work,
        symbol: "clock.arrow.circlepath",
        title: String(localized: "Версии"),
        summary: String(localized: "Версии черновиков для проектов-папок: тексты и карточка проекта сохраняются перед каждым запуском AI и пока вы пишете. Хранятся в папке приложения, не в проекте, и никуда не отправляются."),
        tagline: String(localized: "Черновики не пропадают"),
        // Works behind the scenes: no block in the panel, nothing in the menu bar.
        isPanelBlock: false,
        places: [],
        keywords: [String(localized: "Как часто сохранять"), String(localized: "Сколько хранить"), String(localized: "Очистить")]
    )
}

extension ModuleUI {
    static let versions = ModuleUI(
        settings: { AnyView(VersionsSection()) },
        sketch: nil
    )
}

/// What «Модули → Версии» sets (SPEC-content §6).
struct VersionsSettings: Codable, Equatable, Sendable {
    /// How often a version is taken while the Mac is on; before an AI run one is taken in any case.
    enum Pace: String, Codable, CaseIterable, Sendable {
        case tenMinutes, thirtyMinutes, beforeRuns

        var seconds: TimeInterval? {
            switch self {
            case .tenMinutes: 600
            case .thirtyMinutes: 1800
            case .beforeRuns: nil
            }
        }

        var title: String {
            switch self {
            case .tenMinutes: String(localized: "Каждые 10 минут, если что-то изменилось")
            case .thirtyMinutes: String(localized: "Каждые 30 минут, если что-то изменилось")
            case .beforeRuns: String(localized: "Только перед запуском AI")
            }
        }
    }

    var pace = Pace.tenMinutes
    /// One version a day is kept this long; every version of the last 24 hours stays in any case.
    var keepDays = VersionStore.defaultKeepDays
    /// Text files larger than this are skipped.
    var sizeLimitMB = 20

    static let keepChoices = [30, 90]
    static let sizeChoices = [5, 20, 100]

    var sizeLimit: Int { sizeLimitMB * 1024 * 1024 }

    init() {}

    // Fields added later must not throw away what a person already chose.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pace = (try? container.decodeIfPresent(Pace.self, forKey: .pace)) ?? .tenMinutes
        keepDays = (try? container.decodeIfPresent(Int.self, forKey: .keepDays)) ?? VersionStore.defaultKeepDays
        sizeLimitMB = (try? container.decodeIfPresent(Int.self, forKey: .sizeLimitMB)) ?? 20
    }
}

/// Takes the versions: before every AI run on a folder project, and on a timer for the current profile's folder
/// projects while something in them changes. Works only while the «Версии» module does.
@MainActor
@Observable
final class VersionKeeper {
    @ObservationIgnored var isActive: () -> Bool = { true }
    /// Bytes on disk, for the Settings page; nil until counted.
    private(set) var diskSize: Int?
    /// When the timer last went over the projects.
    private(set) var lastSweep: Date?

    let store: VersionStore
    private let settings: AppSettings
    private let folders: FolderProjectStore
    private var loop: Task<Void, Never>?
    private var lastCleanup: Date?

    init(settings: AppSettings, folders: FolderProjectStore, store: VersionStore = .live) {
        self.settings = settings
        self.folders = folders
        self.store = store
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await self?.tick()
            }
        }
    }

    /// Whether the timer should go over the projects now.
    static func isDue(last: Date?, pace: VersionsSettings.Pace, now: Date) -> Bool {
        guard let interval = pace.seconds else { return false }
        guard let last else { return true }
        return now.timeIntervalSince(last) >= interval
    }

    func tick(now: Date = .now) async {
        guard isActive(), Self.isDue(last: lastSweep, pace: settings.versions.pace, now: now) else { return }
        await sweep(now: now)
    }

    /// A version of every folder project of the current profile that changed, then the clean-up of old ones.
    func sweep(now: Date = .now) async {
        lastSweep = now
        let paths = folders.projects.map(\.path)
        guard !paths.isEmpty else { return }
        let store = store, limit = settings.versions.sizeLimit, keepDays = settings.versions.keepDays
        // A deleted project's versions are looked for once a day.
        let cleanUp = lastCleanup.map { now.timeIntervalSince($0) > 86_400 } ?? true
        if cleanUp { lastCleanup = now }
        let taken = await Task.detached(priority: .utility) { () -> Int in
            var taken = 0
            for path in paths {
                do {
                    if try store.take(projectPath: path, reason: .automatic, now: now, sizeLimit: limit) != nil { taken += 1 }
                } catch {
                    AppLog.error("Versions: \(path) not saved: \(error.localizedDescription)")
                }
                store.prune(projectPath: path, now: now, keepDays: keepDays)
            }
            if cleanUp { store.removeOrphans(now: now, after: keepDays) }
            return taken
        }.value
        if taken > 0 { AppLog.info("Versions: \(taken) of \(paths.count) projects changed") }
    }

    /// Before an AI run: taken at once, so the run starts on files that are already safe.
    func takeBeforeRun(projectPath: String, title: String, now: Date = .now) {
        guard isActive() else { return }
        do {
            if try store.take(projectPath: projectPath, reason: .beforeRun(title), now: now, sizeLimit: settings.versions.sizeLimit) != nil {
                AppLog.info("Versions: taken before «\(title)» in \(projectPath)")
            }
        } catch {
            AppLog.error("Versions: \(projectPath) not saved before «\(title)»: \(error.localizedDescription)")
        }
    }

    func refreshSize() async {
        let store = store
        diskSize = await Task.detached(priority: .utility) { store.size() }.value
    }

    /// «Очистить»: every version of every project.
    func clear() async {
        let store = store
        await Task.detached(priority: .utility) { store.clear() }.value
        AppLog.info("Versions: cleared")
        await refreshSize()
    }
}

struct VersionsSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(VersionKeeper.self) private var keeper

    var body: some View {
        @Bindable var settings = settings
        Section {
            Picker("Как часто сохранять", systemImage: "clock", selection: $settings.versions.pace) {
                ForEach(VersionsSettings.Pace.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Сколько хранить", systemImage: "calendar", selection: $settings.versions.keepDays) {
                ForEach(VersionsSettings.keepChoices, id: \.self) { Text("Дней: \($0)").tag($0) }
            }
            Picker("Пропускать файлы больше", systemImage: "doc.badge.ellipsis", selection: $settings.versions.sizeLimitMB) {
                ForEach(VersionsSettings.sizeChoices, id: \.self) { Text("\($0) МБ").tag($0) }
            }
        } footer: {
            Footnote(text: String(localized: "Сохраняются тексты (.md, .txt, .rtf, .docx, .fountain) и карточка проекта; картинки, звук и видео — нет. Все версии за последние сутки, дальше по одной в день. Перед каждым запуском AI версия снимается всегда. У git-проектов версий нет: там есть git."))
        }
        Section {
            IconRow("На диске", systemImage: "internaldrive") {
                HStack {
                    Text(keeper.diskSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "…")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button("Показать в Finder") {
                        try? FileManager.default.createDirectory(at: keeper.store.root, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(keeper.store.root)
                    }
                    ConfirmedButton(title: "Удалить все версии?", message: String(localized: "Версии всех проектов будут удалены. Сами проекты не меняются. Отменить нельзя."), confirm: "Очистить") {
                        Task { await keeper.clear() }
                    } label: { Text("Очистить") }
                    .disabled((keeper.diskSize ?? 0) == 0)
                }
            }
        } footer: {
            Footnote(text: String(localized: "Версии лежат в папке приложения, не в папке проекта. Версии проекта, папки которого больше нет, удаляются через месяц."))
        }
        .task { await keeper.refreshSize() }
    }
}
