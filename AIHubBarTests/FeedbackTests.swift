import Foundation
import Testing
@testable import AIHubBar

struct FeedbackTests {
    static let bundleID = "com.demishev.claudepult"

    /// A crash report as macOS writes it, cut down to the fields the parser reads.
    static func ips(bundleID: String = bundleID, images: [String] = ["AIHubBar", "libswiftCore.dylib"],
                    asi: Bool = true) -> String {
        let header = #"{"app_name":"AIHubBar","app_version":"0.2.2","build_version":"345","bundleID":"\#(bundleID)","os_version":"macOS 27.2 (26B123)","bug_type":"309"}"#
        let body = """
        {
          "exception" : {"type" : "EXC_BREAKPOINT", "signal" : "SIGTRAP"},
          "termination" : {"indicator" : "Trace/BPT trap: 5"},
          \(asi ? #""asi" : {"libswiftCore.dylib" : ["Fatal error: Index out of range"]},"# : "")
          "faultingThread" : 1,
          "threads" : [
            {"frames" : [{"imageIndex" : 1, "imageOffset" : 10}]},
            {"triggered" : true, "frames" : [
              {"imageIndex" : 1, "symbol" : "_assertionFailure(_:_:file:line:flags:)", "symbolLocation" : 236},
              {"imageIndex" : 0, "symbol" : "ProjectStore.refresh()", "symbolLocation" : 120},
              {"imageIndex" : 0, "imageOffset" : 4096}
            ]}
          ],
          "usedImages" : [\(images.map { #"{"name" : "\#($0)"}"# }.joined(separator: ", "))]
        }
        """
        return header + "\n" + body
    }

    static let file = URL(fileURLWithPath: "/tmp/AIHubBar-2026-11-02-154329.ips")
    static let date = Date(timeIntervalSince1970: 1_793_000_000)

    @Test func parsesTheCrashedThread() throws {
        let report = try #require(CrashReport.parse(Self.ips(), file: Self.file, date: Self.date, bundleID: Self.bundleID))
        #expect(report.appVersion == "0.2.2 (345)")
        #expect(report.system == "macOS 27.2 (26B123)")
        #expect(report.exception == "EXC_BREAKPOINT (SIGTRAP)")
        #expect(report.message == "Fatal error: Index out of range")
        #expect(report.frames == [
            "libswiftCore.dylib  _assertionFailure(_:_:file:line:flags:) + 236",
            "AIHubBar  ProjectStore.refresh() + 120",
            "AIHubBar  + 4096",
        ])
        #expect(report.title == "Crash: EXC_BREAKPOINT (SIGTRAP) in AIHubBar ProjectStore.refresh() + 120", "the app's own frame")
        #expect(report.summary.contains("What I was doing:"))
        #expect(report.summary.contains("Fatal error: Index out of range\nlibswiftCore.dylib"))
    }

    @Test func skipsOtherReports() {
        #expect(CrashReport.parse(Self.ips(bundleID: "com.example.other"), file: Self.file, date: Self.date, bundleID: Self.bundleID) == nil)
        #expect(CrashReport.parse(Self.ips(images: ["AIHubBar", "AIHubBarTests"]), file: Self.file, date: Self.date, bundleID: Self.bundleID) == nil,
                "unit tests run inside the app")
        #expect(CrashReport.parse("not a report", file: Self.file, date: Self.date, bundleID: Self.bundleID) == nil)
        let plain = CrashReport.parse(Self.ips(asi: false), file: Self.file, date: Self.date, bundleID: Self.bundleID)
        #expect(plain?.message == nil)
    }

    @Test func findsNewReportsInAFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "crash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func write(_ name: String, _ text: String, age: TimeInterval) throws {
            let url = folder.appending(path: name)
            try text.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        try write("AIHubBar-new.ips", Self.ips(), age: 60)
        try write("ClaudePult-newer.ips", Self.ips(), age: 10)
        try write("AIHubBar-old.ips", Self.ips(), age: 7_200)
        try write("Safari-new.ips", Self.ips(), age: 10)
        try write("AIHubBar-new.txt", Self.ips(), age: 10)

        let found = CrashReports.reports(in: folder, since: .now.addingTimeInterval(-3_600), bundleID: Self.bundleID)
        #expect(found.map(\.file.lastPathComponent) == ["ClaudePult-newer.ips", "AIHubBar-new.ips"], "newest first, ours only")
    }

    @Test func issueLinkFillsTheForm() throws {
        let url = Feedback.issueURL(.bug, title: "Crash: a & b", fields: ["version": "0.2.2 (345)", "what": "строка 1\nстрока 2"])
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(url.absoluteString.hasPrefix("https://github.com/OlehDemishev/AIHubBar/issues/new?"))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items == ["template": "bug_report.yml", "title": "Crash: a & b", "version": "0.2.2 (345)", "what": "строка 1\nстрока 2"])
        #expect(Feedback.issueURL(.idea).absoluteString.hasSuffix("issues/new?template=feature_request.yml"))
    }

    @Test func longLogIsCutToFitTheLink() throws {
        let report = try #require(CrashReport.parse(Self.ips(), file: Self.file, date: Self.date, bundleID: Self.bundleID))
        let lines = (1...200).map { "2026-11-02T16:46:0\($0 % 10) INFO Проект «Видео \($0)» обновлён" }
        let url = CrashReports.issueURL(report, log: lines.joined(separator: "\n"))
        #expect(url.absoluteString.count <= CrashReports.maxURLLength)
        let log = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "log" }?.value)
        #expect(log.hasSuffix("«Видео 200» обновлён"), "the newest lines stay")
        #expect(!log.contains("«Видео 1»"))
        let short = CrashReports.issueURL(report, log: "one line")
        #expect(short.absoluteString.contains("log=one%20line"))
    }

    @Test func removesTheHomeFolder() {
        let text = "/Users/oleh/Projects/x and /Users/oleh/Library and /Users/other"
        #expect(Feedback.redacted(text, home: "/Users/oleh/Projects", user: "oleh") == "~/x and /Users/USER/Library and /Users/other")
        #expect(Feedback.system.hasPrefix("macOS "))
    }
}
