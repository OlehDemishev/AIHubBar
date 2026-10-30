import Foundation

enum UsageError: LocalizedError, Equatable {
    case noCredentials
    case expired
    case keychainDenied
    case http(Int)
    /// HTTP 429: the server asks to slow down; `retryAfter` from its `Retry-After` header, if any.
    case rateLimited(retryAfter: TimeInterval?)
    case network(Int)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .noCredentials: String(localized: "Войдите в Claude Code: claude → /login")
        // Claude Code renews the token itself the next time `claude` runs in a terminal; a new login is rarely needed.
        case .expired: String(localized: "Вход Claude Code устарел — обновится при следующем запуске claude в Терминале (если нет: claude → /login)")
        case .keychainDenied: String(localized: "Нет доступа к связке ключей: разрешите AI Hub Bar читать «Claude Code-credentials»")
        case let .http(code) where code == 401 || code == 403: String(localized: "Сессия Claude Code истекла (HTTP \(code)): claude → /login")
        case let .http(code): String(localized: "Лимиты недоступны (HTTP \(code))")
        case .rateLimited: String(localized: "Сервер лимитов просит запрашивать реже")
        case let .network(code): String(localized: "Лимиты недоступны: нет связи (\(code))")
        case .badResponse: String(localized: "Лимиты недоступны: ответ в неизвестном формате")
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
        request.setValue("AIHubBar", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 429 {
                let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
                throw UsageError.rateLimited(retryAfter: Self.retryAfter(header))
            }
            guard status == 200 else { throw UsageError.http(status) }
            return data
        } catch let error as UsageError {
            throw error
        } catch let error as URLError {
            throw UsageError.network(error.code.rawValue)
        }
    }

    /// `Retry-After` is either seconds or an HTTP date (RFC 9110 §10.2.3).
    static func retryAfter(_ header: String?, now: Date = .now) -> TimeInterval? {
        guard let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty else { return nil }
        if let seconds = TimeInterval(header) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: header).map { max(0, $0.timeIntervalSince(now)) }
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
