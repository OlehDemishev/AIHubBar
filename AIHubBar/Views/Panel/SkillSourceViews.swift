import AppKit
import SwiftUI

// GitHub repositories as sources of the Skills Catalog (SkillRemote, SkillGitHub): Settings → Скиллы → «Источники»,
// and what a skill from a source shows in the list and on its card.

enum SkillSourceText {
    static func failure(_ code: String) -> String {
        switch code {
        case "not-found": String(localized: "Репозиторий не найден или закрыт.")
        case "rate-limit": String(localized: "GitHub просит подождать: без входа можно 60 запросов в час.")
        case "network": String(localized: "Нет связи с GitHub.")
        case "repo": String(localized: "Нужен репозиторий GitHub: owner/repo или его адрес.")
        default: String(localized: "Не удалось прочитать репозиторий.")
        }
    }
}

/// «Источники» in Settings → Скиллы.
struct SkillsSourcesSection: View {
    @Environment(SkillStore.self) private var skills
    @State private var newSource = ""
    @State private var failure: String?
    @State private var finding = false

    var body: some View {
        Section {
            ForEach(skills.sources) { source in row(source) }
            if skills.sources.isEmpty {
                ForEach(SkillCatalog.suggestedSources, id: \.self) { slug in
                    LabeledContent {
                        Button("Добавить") { add(slug) }
                    } label: {
                        Label { Text(verbatim: slug) } icon: { Image(systemName: "checkmark.seal") }
                    }
                }
            }
            HStack {
                TextField("", text: $newSource, prompt: Text(verbatim: "owner/repo").foregroundStyle(.tertiary))
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { add(newSource) }
                Button("Добавить") { add(newSource) }.disabled(newSource.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Найти источники…") { finding = true }
                if !skills.sources.isEmpty {
                    Button("Проверить все") { Task { await skills.checkSources() } }.disabled(!skills.checking.isEmpty)
                }
            }
            if let failure { Text(verbatim: failure).foregroundStyle(.red) }
        } header: {
            Text("Источники")
        } footer: {
            Footnote(text: String(localized: "Публичные репозитории GitHub со скиллами. Скиллы скачиваются в папку приложения на конкретном коммите и проверяются тем же сканером — ничего из них не запускается, в папки агентов они попадают, только если вы их установите. Источники проверяются дважды в день; без входа GitHub разрешает 60 запросов в час, одна проверка — три запроса."))
        }
        .task { await skills.loadSources() }
        .sheet(isPresented: $finding) { SkillsSourceFinderSheet() }
    }

    private func row(_ source: SkillCatalog.RemoteSource) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if source.official { Image(systemName: "checkmark.seal.fill").foregroundStyle(Color.accentColor).help(String(localized: "Официальный: репозиторий разработчика агента")) }
                Text(verbatim: source.repo.slug).fontWeight(.medium)
                if let stars = source.stars { Text(verbatim: "★ \(stars.formatted())").foregroundStyle(.secondary) }
                Spacer()
                if skills.checking.contains(source.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Проверить") { Task { await skills.check(source) } }.controlSize(.small)
                }
                Button { NSWorkspace.shared.open(URL(string: source.repo.url)!) } label: { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(.borderless)
                    .help(String(localized: "Открыть на GitHub"))
                Button { Task { await skills.removeSource(source.id) } } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help(String(localized: "Убрать источник: его скиллы уйдут из списка, установленные копии останутся"))
            }
            Text(verbatim: Self.line(source)).font(.caption).foregroundStyle(source.error == nil ? Color.secondary : Color.orange)
        }
    }

    static func line(_ source: SkillCatalog.RemoteSource) -> String {
        if let error = source.error { return SkillSourceText.failure(error) }
        guard let sha = source.commitSHA else { return String(localized: "Ещё не проверен") }
        let when = source.checkedAt.flatMap(ISO8601DateFormatter.flexible).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? ""
        return String(localized: "Скиллов: \(source.skills) · коммит \(String(sha.prefix(7))) · \(when)")
    }

    private func add(_ text: String) {
        failure = nil
        newSource = ""
        Task {
            if case .failure(let refusal) = await skills.addSource(text) { failure = SkillSourceText.failure(refusal.code) }
        }
    }
}

/// «GitHub · owner/repo ★ N» beside a skill from a source.
struct SkillOriginBadge: View {
    let row: SkillCatalog.Row

    var body: some View {
        if row.source == "github", let slug = SkillCatalog.GitHubRepo.parse(row.repoURL)?.slug {
            HStack(spacing: 3) {
                if row.official { Image(systemName: "checkmark.seal.fill").foregroundStyle(Color.accentColor) }
                Text(verbatim: slug)
                if let stars = row.stars { Text(verbatim: "★ \(Self.short(stars))") }
            }
            .scaledFont(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help(row.official ? String(localized: "Официальный: репозиторий разработчика агента") : String(localized: "Из источника на GitHub"))
        }
    }

    static func short(_ stars: Int) -> String { stars >= 1000 ? String(format: "%.1fk", Double(stars) / 1000) : "\(stars)" }
}

/// On a card of a skill from a source: where it comes from, at which commit, and a link to it.
struct SkillOriginLine: View {
    let row: SkillCatalog.Row

    var body: some View {
        if row.source == "github", let repo = SkillCatalog.GitHubRepo.parse(row.repoURL) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
                Text(verbatim: Self.text(row, repo)).scaledFont(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Button { NSWorkspace.shared.open(Self.link(row, repo)) } label: { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(.borderless)
                    .help(String(localized: "Открыть на GitHub"))
            }
        }
    }

    static func text(_ row: SkillCatalog.Row, _ repo: SkillCatalog.GitHubRepo) -> String {
        var parts = [repo.slug + ((row.repoPath ?? "").isEmpty ? "" : "/" + (row.repoPath ?? ""))]
        if let sha = row.commitSHA { parts.append(String(localized: "коммит \(String(sha.prefix(7)))")) }
        if let stars = row.stars { parts.append("★ \(stars.formatted())") }
        return parts.joined(separator: " · ")
    }

    /// The folder at the commit the catalog checked: what is shown is what would be installed.
    static func link(_ row: SkillCatalog.Row, _ repo: SkillCatalog.GitHubRepo) -> URL {
        let path = (row.repoPath ?? "").split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        let sha = (row.commitSHA ?? "").filter(\.isHexDigit)
        return URL(string: sha.isEmpty ? repo.url : "\(repo.url)/tree/\(sha)/\(path)") ?? URL(string: repo.url)!
    }
}

/// «Найти источники…»: repositories the awesome lists and Anthropic's plugin marketplace name, and GitHub's search by
/// topic. Each is only a suggestion until it is added; then it is checked like any source.
struct SkillsSourceFinderSheet: View {
    @Environment(SkillStore.self) private var skills
    @Environment(\.dismiss) private var dismiss
    @State private var mode = Mode.lists
    @State private var filter = ""
    @State private var topic = SkillSourceFinder.topics[0]
    @State private var words = ""
    @State private var results: [SkillSourceFinder.Candidate]?
    @State private var searching = false
    @State private var failure: String?

    enum Mode: Hashable { case lists, search }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Где искать источники").font(.headline)
            Picker("", selection: $mode) {
                Text("Из списков").tag(Mode.lists)
                Text("Поиск на GitHub").tag(Mode.search)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch mode {
            case .lists: lists
            case .search: search
            }
            Text("Это подсказки из чужих списков и поиска GitHub, а не проверка: ничего не скачивается, пока вы не добавите источник. После добавления его скиллы скачиваются в папку приложения и проверяются сканером, как любой источник.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Готово") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 640, height: 600)
        .task {
            await skills.loadSources()
            await skills.findSources()
        }
    }

    private var added: Set<String> { Set(skills.sources.map { $0.repo.slug.lowercased() }) }

    @ViewBuilder private var lists: some View {
        TextField("", text: $filter, prompt: Text("Искать в списках"))
            .textFieldStyle(.roundedBorder)
        let shown = Self.matching(skills.candidates, filter)
        if skills.findingSources && skills.candidates.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            rows(shown)
        }
        HStack(spacing: 6) {
            Text(verbatim: String(localized: "Репозиториев: \(shown.count) · списки: \(SkillSourceFinder.lists.map(\.repo.slug).joined(separator: ", "))"))
                .lineLimit(3)
            Spacer()
            if skills.findingSources { ProgressView().controlSize(.small) }
            Button("Обновить") { Task { await skills.findSources(force: true) } }.controlSize(.small).disabled(skills.findingSources)
        }
        .font(.caption).foregroundStyle(.secondary)
        ForEach(skills.unreadLists.sorted(by: { $0.key < $1.key }), id: \.key) { slug, reason in
            Text(verbatim: "\(slug): \(SkillSourceText.failure(reason))").font(.caption).foregroundStyle(.orange)
        }
    }

    @ViewBuilder private var search: some View {
        HStack {
            Picker("", selection: $topic) {
                ForEach(SkillSourceFinder.topics, id: \.self) { Text(verbatim: "topic:\($0)").tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            TextField("", text: $words, prompt: Text("Слова, необязательно"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(runSearch)
            Button("Искать", action: runSearch).disabled(searching)
        }
        if searching {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let results {
            if results.isEmpty { Text("Ничего не нашлось.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) } else { rows(results) }
        } else {
            Text("Самые популярные репозитории с этой темой. Без входа GitHub разрешает 10 поисков в минуту.")
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        if let failure { Text(verbatim: failure).font(.caption).foregroundStyle(.orange) }
    }

    private func runSearch() {
        searching = true
        failure = nil
        Task {
            switch await skills.searchSources(topic: topic, words: words) {
            case .success(let found): results = found
            case .failure(let refusal): failure = SkillSourceText.failure(refusal.code)
            }
            searching = false
        }
    }

    private func rows(_ items: [SkillSourceFinder.Candidate]) -> some View {
        List(items) { candidate in row(candidate) }
            .listStyle(.inset)
            .frame(maxHeight: .infinity)
    }

    private func row(_ candidate: SkillSourceFinder.Candidate) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if candidate.official { Image(systemName: "checkmark.seal.fill").foregroundStyle(Color.accentColor).help(String(localized: "Официальный: репозиторий разработчика агента")) }
                    Text(verbatim: candidate.repo.slug).fontWeight(.medium)
                    // One skill's name beside a repository of many would read as the repository's name.
                    if let title = candidate.title, candidate.paths.count <= 1 { Text(verbatim: title).foregroundStyle(.secondary).lineLimit(1) }
                    if let stars = candidate.stars { Text(verbatim: "★ \(stars.formatted())").foregroundStyle(.secondary) }
                }
                if let summary = candidate.summary { Text(verbatim: summary).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                if !candidate.lists.isEmpty {
                    Text(verbatim: Self.where(candidate)).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 6)
            Button { NSWorkspace.shared.open(URL(string: candidate.repo.url)!) } label: { Image(systemName: "arrow.up.right.square") }
                .buttonStyle(.borderless)
                .help(String(localized: "Открыть на GitHub"))
            if added.contains(candidate.id) {
                Label("Добавлен", systemImage: "checkmark").labelStyle(.titleAndIcon).foregroundStyle(.secondary).font(.caption)
            } else {
                Button("Добавить") { Task { _ = await skills.addSource(candidate.repo.slug) } }.controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    static func `where`(_ candidate: SkillSourceFinder.Candidate) -> String {
        var text = String(localized: "В списках: \(candidate.lists.count)") + " — " + candidate.lists.joined(separator: ", ")
        if !candidate.paths.isEmpty { text += " · " + candidate.paths.prefix(3).joined(separator: ", ") + (candidate.paths.count > 3 ? "…" : "") }
        return text
    }

    static func matching(_ items: [SkillSourceFinder.Candidate], _ filter: String) -> [SkillSourceFinder.Candidate] {
        let words = filter.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return items }
        return items.filter { candidate in
            let text = [candidate.repo.slug, candidate.title ?? "", candidate.summary ?? "", candidate.paths.joined(separator: " ")].joined(separator: " ").lowercased()
            return words.allSatisfy(text.contains)
        }
    }
}

/// «Открытые источники» in the Skills section: every repository the open lists name, searchable without downloading
/// anything. «Скачать и проверить» makes one a source (its skills are downloaded and checked); «Показать скиллы» lists them.
struct SkillIndexView: View {
    @Environment(SkillStore.self) private var skills
    @Binding var query: String
    /// Lists the skills of `owner/repo` in the catalog.
    var showRepo: (String) -> Void
    @State private var page = SkillCatalog.IndexPage()
    @State private var adding: Set<String> = []
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Поиск в открытых источниках", text: $query)
                .textFieldStyle(.roundedBorder)
            Text(verbatim: summary)
                .scaledFont(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if page.total == 0 {
                VStack(spacing: 6) {
                    if skills.findingSources { ProgressView().controlSize(.small) }
                    Text(skills.findingSources ? "Читаю списки…" : "Индекс ещё не собран.").scaledFont(.caption).foregroundStyle(.secondary)
                    if !skills.findingSources { Button("Собрать") { Task { await skills.findSources(force: true) } }.controlSize(.small) }
                }
                .frame(maxWidth: .infinity)
            } else if page.entries.isEmpty {
                Text("Ничего не нашлось.").scaledFont(.caption).foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(page.entries) { entry in
                        row(entry)
                        Divider()
                    }
                }
                if page.matches > page.entries.count {
                    Text(verbatim: String(localized: "Показаны первые \(page.entries.count) из \(page.matches): уточните поиск."))
                        .scaledFont(.caption2).foregroundStyle(.secondary)
                }
            }
            if let failure { Text(verbatim: failure).scaledFont(.caption).foregroundStyle(.orange) }
        }
        .task(id: "\(query)|\(skills.indexVersion)|\(skills.sources.count)|\(skills.checking.count)") {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            page = await skills.index(query: query)
        }
        .task {
            await skills.loadSources()
            skills.refreshIndexIfStale()
        }
    }

    private var summary: String {
        var text = String(localized: "Репозиториев в индексе: \(page.total). Это подсказки из открытых списков: файлы скачиваются и проверяются, только когда вы попросите.")
        if let fetched = page.fetchedAt.flatMap(ISO8601DateFormatter.flexible) {
            text += " " + String(localized: "Обновлён \(fetched.formatted(date: .abbreviated, time: .shortened)).")
        }
        return text
    }

    private func row(_ entry: SkillCatalog.IndexEntry) -> some View {
        let candidate = entry.candidate
        return HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if candidate.official { Image(systemName: "checkmark.seal.fill").foregroundStyle(Color.accentColor).help(String(localized: "Официальный: репозиторий разработчика агента")) }
                    Text(verbatim: candidate.repo.slug).scaledFont(.callout, weight: .medium).lineLimit(1).truncationMode(.middle)
                }
                if let title = candidate.title, candidate.paths.count <= 1 {
                    Text(verbatim: title).scaledFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let summary = candidate.summary {
                    Text(verbatim: summary).scaledFont(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(verbatim: String(localized: "В списках: \(candidate.lists.count)")).scaledFont(.caption2).foregroundStyle(.tertiary)
                if let id = entry.sourceID, let error = skills.sources.first(where: { $0.id == id })?.error {
                    Text(verbatim: SkillSourceText.failure(error)).scaledFont(.caption2).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 4) {
                if entry.sourceID != nil {
                    if let id = entry.sourceID, skills.checking.contains(id) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(String(localized: "Скиллы: \(entry.skills)")) { showRepo(candidate.repo.slug) }
                            .controlSize(.small)
                            .disabled(entry.skills == 0)
                            .help(String(localized: "Показать скиллы этого источника"))
                    }
                } else if adding.contains(candidate.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Скачать и проверить") { add(candidate) }
                        .controlSize(.small)
                        .help(String(localized: "Добавить репозиторий в источники: его скиллы скачаются в папку приложения и проверятся сканером"))
                }
                Button { NSWorkspace.shared.open(URL(string: candidate.repo.url)!) } label: { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(.borderless)
                    .help(String(localized: "Открыть на GitHub"))
            }
        }
        .padding(.vertical, 5)
    }

    private func add(_ candidate: SkillSourceFinder.Candidate) {
        failure = nil
        adding.insert(candidate.id)
        Task {
            if case .failure(let refusal) = await skills.addSource(candidate.repo.slug) { failure = SkillSourceText.failure(refusal.code) }
            adding.remove(candidate.id)
            page = await skills.index(query: query)
        }
    }
}
