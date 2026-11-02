import Foundation
import Testing
@testable import ClaudePult

/// SPEC-notch stage 5: a file or folder dropped on the island runs the profile's AI commands on it.
struct NotchFileDropTests {
    private func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "drop-\(UUID().uuidString)/Сценарий ролика")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "Текст".write(to: dir.appending(path: "черновик.md"), atomically: true, encoding: .utf8)
        return dir
    }

    @Test func aFileRunsInItsFolder() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let project = FolderProject.dropped(dir.appending(path: "черновик.md"))
        #expect(project.path == dir.path && project.name == "Сценарий ролика")
        #expect(project.mainFile == "черновик.md", "the file is what «{файл}» and the main-file commands get")
        let context = CommandContext(projectName: project.name, projectPath: project.path, file: project.mainFile, text: "сократи")
        #expect(CommandText.fill(CommandTemplate.customTask.task, context) == "сократи")
        let name = CommandText.uniqueName(CommandText.outputName("<файл>-итог.md", context)) {
            FileManager.default.fileExists(atPath: dir.appending(path: $0).path)
        }
        #expect(name == "черновик-итог.md", "the result is a new file next to it")
    }

    @Test func aFolderIsTheProject() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let project = FolderProject.dropped(dir)
        #expect(project.path == dir.path && project.mainFile == nil)
    }

    @Test func settingIsOnByDefault() throws {
        #expect(NotchSettings().fileDrop)
        let old = try JSONDecoder().decode(NotchSettings.self, from: Data(#"{"liveActivity":false}"#.utf8))
        #expect(old.fileDrop && !old.liveActivity)
    }
}
