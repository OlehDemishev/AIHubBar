import Foundation
import Testing
@testable import ClaudePult

/// SPEC-profiles stage 5: «Не спать».
struct KeepAwakeTests {
    typealias Situation = KeepAwakeRules.Situation

    @Test func rulesInOrder() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var rules = KeepAwakeRules()
        #expect(rules.whileClaudeWorks && !rules.whileOnPower && !rules.keepDisplayOn, "only «пока работает Claude» is on by default")
        #expect(rules.reason(manualUntil: nil, situation: Situation(), now: now) == nil)
        #expect(rules.reason(manualUntil: nil, situation: Situation(claudeWorking: true), now: now) == .claude)
        #expect(rules.reason(manualUntil: nil, situation: Situation(onPower: true, externalDisplay: true), now: now) == nil, "rules that are off")

        rules.whileOnPower = true
        rules.whileExternalDisplay = true
        rules.whileApps = [.init(bundleID: "com.apple.FinalCut", name: "Final Cut Pro")]
        #expect(rules.reason(manualUntil: nil, situation: Situation(onPower: true), now: now) == .power)
        #expect(rules.reason(manualUntil: nil, situation: Situation(externalDisplay: true), now: now) == .display)
        #expect(rules.reason(manualUntil: nil, situation: Situation(runningApps: ["com.apple.FinalCut"]), now: now) == .app("Final Cut Pro"))

        // A manual hold comes first; a timed one ends by itself.
        #expect(rules.reason(manualUntil: .some(nil), situation: Situation(claudeWorking: true), now: now) == .manual(until: nil))
        let until = now.addingTimeInterval(60)
        #expect(rules.reason(manualUntil: .some(until), situation: Situation(), now: now) == .manual(until: until))
        #expect(rules.reason(manualUntil: .some(until), situation: Situation(), now: until.addingTimeInterval(1)) == nil)
    }

    @Test func oldSettingsDecode() throws {
        let rules = try JSONDecoder().decode(KeepAwakeRules.self, from: Data(#"{"whileOnPower": true, "future": 1}"#.utf8))
        #expect(rules.whileOnPower && rules.whileClaudeWorks && rules.whileApps.isEmpty)
    }

    @Test func statusText() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(KeepAwakeText.status(.manual(until: now.addingTimeInterval(47 * 60 + 10)), now: now).contains("47"))
        #expect(KeepAwakeText.status(.app("Xcode")).contains("Xcode"))
    }

    @Test func menuBarCup() {
        var config = MenuBarConfig.make(.minimum)
        config.set(.icon) { $0.enabled = false }
        config.set(.keepAwake) { $0.enabled = true }
        var data = MenuBarData()
        #expect(MenuBarComposer.groups(config, data) == [[.symbol("sparkle")]], "nothing while the Mac may sleep")
        data.keepingAwake = true
        #expect(MenuBarComposer.groups(config, data) == [[.symbol("cup.and.saucer.fill")]])
    }

    @Test func developersGetItByDefault() throws {
        var draft = AssistantDraft(firstLaunch: false, menuBar: .make(.limits), hiddenBlocks: [], reminderHours: [24])
        let developer = try #require(ModeTemplate.loadAll(language: .ru).first { $0.id == "developer" })
        draft.choose(developer)
        #expect(draft.hasModule(.keepAwake))
        draft.choose(nil)
        #expect(!draft.hasModule(.keepAwake), "other templates leave it to the person")
    }
}

@MainActor
struct KeepAwakeControllerTests {
    @Test func nothingWithoutTheModule() {
        let name = "claudepult-keepawake-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let controller = KeepAwakeController(settings: AppSettings(defaults: defaults))
        controller.claudeWorking = { true }
        controller.holdManually(for: nil)
        #expect(controller.reason == nil && controller.manualUntil == nil, "not installed: nothing is held")
    }
}
