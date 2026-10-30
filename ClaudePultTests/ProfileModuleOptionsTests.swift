import Foundation
import Testing
@testable import ClaudePult

/// A profile's own choices inside a module: which metrics, commands and toggles, and the keep-awake timers.
struct ProfileModuleOptionsTests {
    @Test func toggledKeepsNilForEverything() {
        let all = ["cpu", "memory", "disk"]
        // From «everything» one item off → an explicit list in the catalog's order.
        #expect(ProfileModule.toggled("memory", in: nil, all: all) == ["cpu", "disk"])
        // Back on → nil again, so new metrics added later show up by themselves.
        #expect(ProfileModule.toggled("memory", in: ["cpu", "disk"], all: all) == nil)
        #expect(ProfileModule.toggled("cpu", in: ["disk"], all: all) == ["cpu", "disk"])
        #expect(ProfileModule.includes("x", in: nil) && !ProfileModule.includes("x", in: ["y"]))
    }

    @Test func optionsSurviveSavingAndOldFilesStillLoad() throws {
        var resources = ProfileModule(.resources)
        resources.metrics = ["cpu", "battery"]
        var timers = ProfileModule(.keepAwake)
        timers.showTimers = false
        let data = try JSONEncoder().encode([resources, timers, ProfileModule(.limits)])
        let decoded = try JSONDecoder().decode(ModuleList.self, from: data).modules
        #expect(decoded[0].metrics == ["cpu", "battery"] && decoded[1].showTimers == false)
        // The plain module writes none of the new keys, so older versions read it as before.
        let plain = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(ProfileModule(.limits))) as? [String: Any])
        #expect(Set(plain.keys) == ["kind", "shown"])
        let old = try JSONDecoder().decode(ModuleList.self, from: Data(#"[{"kind":"resources","shown":true}]"#.utf8)).modules
        #expect(old.first?.metrics == nil)
    }
}
