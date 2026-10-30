import Foundation
import Testing
@testable import ClaudePult

struct ProjectCardTests {
    @Test func parsesFieldsInAnyMarkdownForm() {
        let card = ProjectCardFile.parse("""
        # Ролик про кофе

        - **Этап:** сценарий
        Дедлайн: 2026-11-05
        * Публикация: 05.11.2026 18:00
        Формат:
        main file: текст/сценарий.md
        Площадка: YouTube
        Этап: монтаж
        Заметка: не поле
        """)
        #expect(card.stage == "сценарий", "the first value wins")
        #expect(card.values[.format] == nil, "empty values are not values")
        #expect(card.values[.mainFile] == "текст/сценарий.md")
        #expect(card.values[.platform] == "YouTube")
        let calendar = Calendar.current
        #expect(card.deadline.map { calendar.dateComponents([.year, .month, .day], from: $0) } == DateComponents(year: 2026, month: 11, day: 5))
        #expect(card.publish.map { calendar.component(.hour, from: $0) } == 18)
        #expect(ProjectCardFile.date("завтра") == nil)
    }

    @Test func writesAValueBackKeepingTheRest() {
        let text = "# Кофе\n\n- Этап: идея\nДедлайн: 2026-11-05\n\nЗаметки и мысли."
        #expect(ProjectCardFile.setting(.stage, to: "сценарий", in: text)
            == "# Кофе\n\n- Этап: сценарий\nДедлайн: 2026-11-05\n\nЗаметки и мысли.")
        #expect(ProjectCardFile.setting(.stage, to: "идея", in: "# Кофе\nТекст.")
            == "# Кофе\n\nЭтап: идея\n\nТекст.")
        #expect(ProjectCardFile.setting(.stage, to: "идея", in: "Просто текст") == "Этап: идея\nПросто текст")
        let template = ProjectCardFile.template(name: "Кофе", stage: "идея")
        #expect(ProjectCardFile.parse(template).stage == "идея")
        #expect(ProjectCardFile.parse(ProjectCardFile.setting(.deadline, to: "2026-12-01", in: template)).values[.deadline] == "2026-12-01")
    }

    @Test func metricsText() {
        let now = Date(timeIntervalSince1970: 1_793_300_000)
        var project = FolderProject(name: "A", path: "/A", card: ProjectCardFile(), hasCardFile: false, mainFile: "a.md",
                                    words: 1500, sources: 3, lastActivity: now.addingTimeInterval(-7200))
        #expect(FolderMetric.words.text(for: project, wordsPerMinute: 150) == "1500 сл.")
        #expect(FolderMetric.duration.text(for: project, wordsPerMinute: 150) == "10:00")
        #expect(FolderMetric.duration.text(for: project, wordsPerMinute: 130) == "11:32")
        #expect(FolderMetric.readingTime.text(for: project, wordsPerMinute: 150) == "8 мин чтения")
        #expect(FolderMetric.pages.text(for: project, wordsPerMinute: 150) == "6 стр.")
        #expect(FolderMetric.sources.text(for: project, wordsPerMinute: 150) == "3 ист.")
        #expect(FolderMetric.lastActivity.text(for: project, wordsPerMinute: 150, now: now) == "2 ч назад")
        #expect(FolderMetric.deadline.text(for: project, wordsPerMinute: 150) == nil)
        project.words = nil
        #expect(FolderMetric.duration.text(for: project, wordsPerMinute: 150) == nil)
    }

    @Test func countsWordsNotMarkup() {
        #expect(FolderScanner.words("# Заголовок\n\n- пункт один, [ссылка](https://x.y) — 2026 год!") == 6)
        #expect(FolderScanner.words("  \n — * \n") == 0)
    }
}

struct FolderScannerTests {
    private func makeTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "claudepult-folders-\(UUID().uuidString)")
        let fm = FileManager.default
        func write(_ path: String, _ text: String, ago: TimeInterval = 0) throws {
            let url = root.appending(path: path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            try fm.setAttributes([.modificationDate: Date.now.addingTimeInterval(-ago)], ofItemAtPath: url.path)
        }
        try write("Кофе/проект.md", "# Кофе\nЭтап: сценарий\nГлавный файл: сценарий.md\n", ago: 50)
        try write("Кофе/сценарий.md", "раз два три четыре", ago: 100)
        try write("Кофе/заметки.md", "один", ago: 10)
        try write("Кофе/источники/статья.txt", "x")
        try write("Кофе/источники/отчёт.pdf", "x")
        try write("Чай/черновик.txt", "альфа бета", ago: 5000)
        try write("Чай/черновик-старый.txt", "альфа бета гамма", ago: 9000)
        try write("_архив/старое.md", "x")
        try write(".скрытая/x.md", "x")
        return root
    }

    @Test func scansFoldersAsProjects() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = FolderScanner.scan(source: .folders(root.path))
        #expect(projects.map(\.name) == ["Кофе", "Чай"], "newest first; «_» and hidden folders skipped")
        let coffee = projects[0]
        #expect(coffee.hasCardFile)
        #expect(coffee.card.stage == "сценарий")
        #expect(coffee.mainFile == "сценарий.md", "the card's main file wins over the newest file")
        #expect(coffee.words == 4)
        #expect(coffee.sources == 2)
        let tea = projects[1]
        #expect(!tea.hasCardFile)
        #expect(tea.mainFile == "черновик.txt", "else the newest text file")
        #expect(tea.words == 2)
        #expect(FolderScanner.scan(source: .inbox(root.appending(path: "Чай").path)).map(\.name) == ["Чай"])
        #expect(FolderScanner.scan(source: .folders(root.appending(path: "нет").path)).isEmpty)
        #expect(FolderScanner.scan(source: .none).isEmpty)
    }

    @MainActor
    @Test func storeCreatesProjectsAndChangesStages() async throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "claudepult-folders-\(UUID().uuidString)"
        let settings = AppSettings(defaults: try #require(UserDefaults(suiteName: name)))
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        settings.activeSource = .folders(root.path)
        let store = FolderProjectStore(settings: settings)
        await store.refresh()
        #expect(store.projects.count == 2)

        let path = try store.createProject(named: "Новый ролик", firstStage: "идея")
        let card = try String(contentsOfFile: path + "/" + ProjectCardFile.fileName, encoding: .utf8)
        #expect(ProjectCardFile.parse(card).stage == "идея")
        #expect(throws: FolderProjectStore.CreateError.exists) { try store.createProject(named: "Кофе", firstStage: nil) }
        #expect(throws: FolderProjectStore.CreateError.badName) { try store.createProject(named: "a/b", firstStage: nil) }

        let tea = try #require(store.projects.first { $0.name == "Чай" })
        store.setStage("монтаж", of: tea)
        let written = try String(contentsOfFile: tea.path + "/" + ProjectCardFile.fileName, encoding: .utf8)
        #expect(ProjectCardFile.parse(written).stage == "монтаж")
        #expect(written.hasPrefix("# Чай"))
        #expect(store.projects.first { $0.name == "Чай" }?.card.stage == "монтаж")
        let untouched = try String(contentsOfFile: tea.path + "/черновик.txt", encoding: .utf8)
        #expect(untouched == "альфа бета")

        settings.activeSource = .gitReport(projects: root.path, dailyReport: root.path)
        await store.refresh()
        #expect(store.projects.isEmpty)
        #expect(!store.isActive)
    }
}
