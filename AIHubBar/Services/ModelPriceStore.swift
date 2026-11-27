import Foundation
import Observation

/// The price list of «Экономика AI»: downloaded from models.dev when the window asks for it, kept for a day in
/// `model-prices.json`. Nothing is asked while the window stays closed, and nothing of the person's goes with the
/// request — it is a plain download of a public file.
@MainActor
@Observable
final class ModelPriceStore {
    private(set) var list: ModelPriceList?
    private(set) var isLoading = false
    /// Why the last download failed, in the person's language; the old list stays on screen.
    private(set) var failure: String?

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let fetch: @Sendable () async throws -> Data
    /// The demo copy asks no one for anything: it shows the sample it was given.
    @ObservationIgnored private var isDemo = false

    init(
        fileURL: URL = SessionFiles.supportDirectory.appending(path: "model-prices.json"),
        fetch: @escaping @Sendable () async throws -> Data = ModelPriceStore.download
    ) {
        self.fileURL = fileURL
        self.fetch = fetch
        if let data = try? Data(contentsOf: fileURL) {
            list = try? Self.decoder.decode(ModelPriceList.self, from: data)
        }
    }

    func showDemo(_ list: ModelPriceList) {
        isDemo = true
        self.list = list
    }

    /// The window appeared: download when there is no list yet or it is a day old.
    func refreshIfStale(now: Date = .now) async {
        guard list?.isStale(now: now) ?? true else { return }
        await refresh(now: now)
    }

    func refresh(now: Date = .now) async {
        guard !isLoading, !isDemo else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let data = try await fetch()
            let models = await Task.detached { ModelPriceParser.parse(data) }.value
            guard !models.isEmpty else {
                failure = String(localized: "Список цен пришёл в незнакомом виде.")
                AppLog.error("Model prices: nothing recognised in \(data.count) bytes")
                return
            }
            let fresh = ModelPriceList(fetchedAt: now, models: models)
            list = fresh
            failure = nil
            if let encoded = try? Self.encoder.encode(fresh) {
                try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? encoded.write(to: fileURL, options: .atomic)
            }
            AppLog.info("Model prices: \(models.count) models")
        } catch {
            failure = error.localizedDescription
            AppLog.error("Model prices: \(error.localizedDescription)")
        }
    }

    nonisolated static func download() async throws -> Data {
        var request = URLRequest(url: ModelPriceParser.sourceURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
