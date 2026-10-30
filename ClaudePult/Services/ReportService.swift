import Foundation

enum ReportError: LocalizedError {
    case scriptMissing(String)
    case failed(exitCode: Int32, stderr: String)
    case badJSON(String)

    var errorDescription: String? {
        switch self {
        case let .scriptMissing(path): String(localized: "Не найден report.py: \(path). Проверьте путь к _daily-report в настройках.")
        case let .failed(code, _): String(localized: "report.py завершился с ошибкой (код \(code)). Подробности в журнале.")
        case .badJSON: String(localized: "Не удалось разобрать ответ report.py. Подробности в журнале.")
        }
    }
}

/// Loads project data by running `report.py --json` (the logic lives there, not in Swift).
enum ReportService {
    static func arguments(script: String, projectsDirectory: String, fetch: Bool) -> [String] {
        var args = ["python3", script, "--json", "--projects-dir", projectsDirectory]
        if !fetch { args.append("--no-fetch") }
        return args
    }

    static func load(script: String, projectsDirectory: String, fetch: Bool) async throws -> ProjectsReport {
        guard FileManager.default.fileExists(atPath: script) else { throw ReportError.scriptMissing(script) }

        let started = ContinuousClock.now
        let result = try await ProcessRunner.run(
            "/usr/bin/env",
            arguments(script: script, projectsDirectory: projectsDirectory, fetch: fetch),
            currentDirectory: URL(fileURLWithPath: script).deletingLastPathComponent(),
            timeout: fetch ? .seconds(300) : .seconds(90)
        )
        let elapsed = (ContinuousClock.now - started).formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1)))

        guard result.exitCode == 0 else {
            AppLog.error("report.py exited with \(result.exitCode) after \(elapsed): \(result.stderrText.suffix(500))")
            throw ReportError.failed(exitCode: result.exitCode, stderr: result.stderrText)
        }
        do {
            let report = try decode(result.stdout)
            AppLog.info("report.py\(fetch ? " (fetch)" : ""): \(report.projects.count) projects in \(elapsed)")
            return report
        } catch {
            AppLog.error("report.py JSON decode failed: \(error)")
            throw ReportError.badJSON(String(describing: error))
        }
    }

    static func decode(_ data: Data) throws -> ProjectsReport {
        try JSONDecoder().decode(ProjectsReport.self, from: data)
    }
}
