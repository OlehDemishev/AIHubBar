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
