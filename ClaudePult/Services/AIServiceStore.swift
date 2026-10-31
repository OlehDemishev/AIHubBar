import Foundation
import Observation

/// API keys in the login Keychain, service «ClaudePult API key», account = provider. Written and read with Apple's
/// `security` tool, like the Claude Code token: its Keychain permission survives ClaudePult rebuilds. The key goes
/// to `security` on stdin, never as an argument (arguments are visible to other processes), and is never logged.
enum APIKeyStore {
    static let service = "ClaudePult API key"

    enum KeyError: LocalizedError, Equatable {
        case invalid
        case failed(Int32)

        var errorDescription: String? {
            switch self {
            case .invalid: String(localized: "Ключ выглядит неправильно: только латиница, цифры и . _ - ~ + / = :, от 8 символов")
            case let .failed(code): String(localized: "Связка ключей не сохранила ключ (код \(code))")
            }
        }
    }

    /// Keys are plain tokens; anything else (spaces, quotes) is a copy-paste accident and would also break
    /// `security -i` parsing.
    static func isValid(_ key: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-~+/=:")
        return (8...512).contains(key.count) && key.unicodeScalars.allSatisfy(allowed.contains)
    }

    static func save(_ key: String, for provider: APIProvider) async throws {
        try await save(key, account: provider.rawValue, label: provider.title)
    }

    static func read(_ provider: APIProvider) async -> String? { await read(account: provider.rawValue) }

    /// Whether a key is stored, without reading it (no Keychain prompt).
    static func exists(_ provider: APIProvider) async -> Bool { await exists(account: provider.rawValue) }

    static func delete(_ provider: APIProvider) async { await delete(account: provider.rawValue) }

    // Any secret of ClaudePult's: the account names it (a provider, `telegram-approvals`).

    static func save(_ key: String, account: String, label: String) async throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValid(key) else { throw KeyError.invalid }
        let command = "add-generic-password -U -s \"\(service)\" -a \(account) -l \"AI Hub Bar: \(label)\" -w \(key)\n"
        let result = try await ProcessRunner.run("/usr/bin/security", ["-i"], input: Data(command.utf8), timeout: .seconds(60))
        guard result.exitCode == 0, !result.stderrText.contains("error") else { throw KeyError.failed(result.exitCode) }
        AppLog.info("Key saved for \(account)")
    }

    static func read(account: String) async -> String? {
        guard let result = try? await ProcessRunner.run(
            "/usr/bin/security", ["find-generic-password", "-s", service, "-a", account, "-w"], timeout: .seconds(120)
        ), result.exitCode == 0 else { return nil }
        let key = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    static func exists(account: String) async -> Bool {
        guard let result = try? await ProcessRunner.run(
            "/usr/bin/security", ["find-generic-password", "-s", service, "-a", account], timeout: .seconds(20)
        ) else { return false }
        return result.exitCode == 0
    }

    static func delete(account: String) async {
        _ = try? await ProcessRunner.run(
            "/usr/bin/security", ["delete-generic-password", "-s", service, "-a", account], timeout: .seconds(20)
        )
        AppLog.info("Key deleted for \(account)")
    }
}

/// Which services are usable on this Mac: installed agents with versions, stored API keys, check results.
@MainActor
@Observable
final class AIServiceStore {
    struct AgentInfo: Equatable, Sendable {
        var path: String
        var version: String?
    }

    private(set) var agents: [AgentKind: AgentInfo] = [:]
    private(set) var hasKey: Set<APIProvider> = []
    private(set) var checks: [APIProvider: APICheck] = [:]
    private(set) var checking: Set<APIProvider> = []
    private(set) var isScanning = false
    /// At least one scan finished — until then «nothing found» would be premature.
    private(set) var hasScanned = false

    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// Services a mode can pick: Claude Code always, other agents when installed, APIs with a key (or the local server).
    var available: [AIService] {
        var services: [AIService] = [.claudeCode]
        services += AgentKind.allCases.filter { $0 != .claudeCode && agents[$0] != nil }.map(AIService.agent)
        services += APIProvider.allCases.filter { hasKey.contains($0) || ($0 == .compatible && checks[$0] != nil) }.map(AIService.api)
        return services
    }

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        agents = await Self.findAgents()
        hasKey = await Self.storedKeys()
        hasScanned = true
    }

    nonisolated static func findAgents() async -> [AgentKind: AgentInfo] {
        var found: [AgentKind: AgentInfo] = [:]
        for kind in AgentKind.allCases {
            let path = kind.detect()
            guard let path else { continue }
            let result = try? await ProcessRunner.run(path, kind.versionArguments, timeout: .seconds(10))
            let version = result.flatMap { $0.exitCode == 0 ? $0.stdoutText : nil }.flatMap(kind.version(fromOutput:))
            found[kind] = AgentInfo(path: path, version: version)
        }
        return found
    }

    nonisolated static func storedKeys() async -> Set<APIProvider> {
        var keys: Set<APIProvider> = []
        for provider in APIProvider.allCases where await APIKeyStore.exists(provider) { keys.insert(provider) }
        return keys
    }

    func saveKey(_ key: String, for provider: APIProvider) async throws {
        try await APIKeyStore.save(key, for: provider)
        hasKey.insert(provider)
        checks[provider] = nil
        await check(provider)
    }

    func deleteKey(_ provider: APIProvider) async {
        await APIKeyStore.delete(provider)
        hasKey.remove(provider)
        checks[provider] = nil
    }

    /// Lists the provider's models — a request that costs no tokens.
    func check(_ provider: APIProvider) async {
        checking.insert(provider)
        defer { checking.remove(provider) }
        let result = await Self.check(provider, baseURL: settings.aiServices.baseURL(provider))
        checks[provider] = result
        if case let .ok(models) = result, let first = models.first,
           settings.aiServices.model(provider).map({ !models.contains($0) }) ?? true {
            settings.aiServices.models[provider.rawValue] = Self.preferredModel(models) ?? first
        }
    }

    nonisolated static func check(_ provider: APIProvider, baseURL: String) async -> APICheck {
        let key = await APIKeyStore.read(provider)
        if provider.keyRequired, key == nil { return .noKey }
        guard let request = provider.modelsRequest(baseURL: baseURL, key: key) else { return .failed(String(localized: "Неверный адрес сервера")) }
        let result: APICheck
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            result = APICheck.from(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
        } catch {
            result = .failed(provider == .compatible ? String(localized: "Сервер не отвечает — запущен ли он?") : String(localized: "Нет связи"))
        }
        AppLog.info("API check \(provider.rawValue): \(result.text)")
        return result
    }

    /// A sensible default from a list: not an embedding / audio / image model.
    nonisolated static func preferredModel(_ models: [String]) -> String? {
        let skip = ["embed", "tts", "whisper", "audio", "image", "dall-e", "moderation", "transcribe", "realtime", "search"]
        return models.first { model in !skip.contains { model.lowercased().contains($0) } }
    }
}
