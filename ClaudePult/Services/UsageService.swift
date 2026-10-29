import Foundation

enum UsageError: LocalizedError, Equatable {
    case noCredentials
    case expired
    case keychainDenied
    case http(Int)
    case network(Int)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .noCredentials, .expired: "Войдите в Claude Code: claude → /login"
        case .keychainDenied: "Нет доступа к связке ключей: разрешите ClaudePult читать «Claude Code-credentials»"
        case let .http(code) where code == 401 || code == 403: "Сессия Claude Code истекла (HTTP \(code)): claude → /login"
        case let .http(code): "Лимиты недоступны (HTTP \(code))"
        case let .network(code): "Лимиты недоступны: нет связи (\(code))"
        case .badResponse: "Лимиты недоступны: ответ в неизвестном формате"
        }
    }
}

/// Subscription limits from the same endpoint Claude Code uses (docs/SPEC.md §2.8). The endpoint is undocumented,
/// so decoding is tolerant and every failure becomes «лимиты недоступны». The OAuth token is read from the
/// Keychain for each request and never stored, logged or refreshed.
enum UsageService {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let keychainService = "Claude Code-credentials"

    struct Credentials: Sendable {
        var accessToken: String
        var expiresAt: Date?
    }

    /// Reads the token with Apple's `security` tool: its Keychain permission survives ClaudePult rebuilds
    /// (an ad-hoc signed app would be asked again after every build).
    static func credentials() async throws -> Credentials {
        let result: ProcessResult
        do {
            result = try await ProcessRunner.run(
                "/usr/bin/security", ["find-generic-password", "-s", keychainService, "-w"], timeout: .seconds(120)
            )
        } catch {
            throw UsageError.keychainDenied
        }
        switch result.exitCode {
        case 0: break
        case 44: throw UsageError.noCredentials // errSecItemNotFound
        default: throw UsageError.keychainDenied
        }
        guard let credentials = parseCredentials(result.stdout) else { throw UsageError.noCredentials }
        if let expiresAt = credentials.expiresAt, expiresAt < .now { throw UsageError.expired }
        return credentials
    }

    /// `{"claudeAiOauth": {"accessToken": "...", "expiresAt": <ms>}}` as Claude Code stores it.
    static func parseCredentials(_ data: Data) -> Credentials? {
        let trimmed = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        let expires = (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return Credentials(accessToken: token, expiresAt: expires)
    }

    static func fetchData() async throws -> Data {
        let credentials = try await credentials()
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudePult", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw UsageError.http(status) }
            return data
        } catch let error as UsageError {
            throw error
        } catch let error as URLError {
            throw UsageError.network(error.code.rawValue)
        }
    }

    static func fetch() async throws -> UsageSnapshot {
        let data = try await fetchData()
        guard let snapshot = UsageSnapshot.decode(data, fetchedAt: .now) else {
            AppLog.error("Usage response in an unknown format (\(data.count) bytes)")
            throw UsageError.badResponse
        }
        return snapshot
    }
}
