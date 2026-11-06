import Foundation

/// Whether Anthropic reports trouble, asked only after the limits failed in a way an outage could explain: it tells
/// an outage from a problem on this Mac. Anthropic's public status page, no account or token involved.
enum ServiceStatus {
    static let page = URL(string: "https://status.claude.com")!
    private static let summary = URL(string: "https://status.claude.com/api/v2/status.json")!

    /// The page's own words when something is wrong, nil when all is well or the answer can't be read.
    static func problem(in data: Data) -> String? {
        struct Response: Decodable {
            struct Status: Decodable {
                var indicator: String
                var description: String
            }
            var status: Status
        }
        guard let status = (try? JSONDecoder().decode(Response.self, from: data))?.status, status.indicator != "none" else { return nil }
        return status.description
    }

    /// Nil also when the page can't be reached: without internet, nothing is known about Anthropic.
    static func check() async -> String? {
        var request = URLRequest(url: summary, timeoutInterval: 10)
        request.setValue("AIHubBar", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return problem(in: data)
    }
}
