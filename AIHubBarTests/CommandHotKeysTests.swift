import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import AIHubBar

/// Quick command shortcuts (SPEC-profiles §4.3): storage, the keys' names, conflicts and what gets registered.
@MainActor
struct CommandHotKeysTests {
    private let controlOption = UInt32(controlKey | optionKey)
    private var controlOptionK: KeyCombo { KeyCombo(keyCode: UInt32(kVK_ANSI_K), modifiers: controlOption) }

    private func settings() -> AppSettings {
        AppSettings(defaults: UserDefaults(suiteName: "command-hot-keys-\(UUID().uuidString)")!)
    }

    @Test func storedWithAndWithoutAShortcut() throws {
        // A library saved before shortcuts existed.
        let old = #"[{"id":"a","title":"Загрузки","symbol":"folder","kind":"open","value":"~/Downloads","confirm":false}]"#
        let decoded = try JSONDecoder().decode([QuickCommand].self, from: Data(old.utf8))
        #expect(decoded.first?.hotKey == nil)
        let plain = try JSONEncoder().encode(decoded)
        #expect(!String(decoding: plain, as: UTF8.self).contains("hotKey"))

        var command = try #require(decoded.first)
        command.hotKey = controlOptionK
        let again = try JSONDecoder().decode(QuickCommand.self, from: JSONEncoder().encode(command))
        #expect(again == command && again.hotKey == controlOptionK)
    }

    @Test func savedInTheSettings() {
        let defaults = UserDefaults(suiteName: "command-hot-keys-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.quickCommands = [QuickCommand(title: "x", kind: .script, value: "true", hotKey: controlOptionK)]
        #expect(AppSettings(defaults: defaults).quickCommands.first?.hotKey == controlOptionK)
    }

    @Test func keyNames() {
        #expect(controlOptionK.title == "⌃⌥K")
        #expect(controlOptionK.spoken == "Control Option K")
        let all = KeyCombo(keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey))
        #expect(all.title == "⌃⌥⇧⌘1")
        #expect(KeyCombo(keyCode: UInt32(kVK_F5), modifiers: 0).title == "F5")
        #expect(KeyCombo(keyCode: UInt32(kVK_LeftArrow), modifiers: controlOption).spoken == "Control Option Left Arrow")
        #expect(KeyCombo.carbon([.command, .option]) == UInt32(cmdKey | optionKey))
        // Caps Lock and other flags are not part of a shortcut.
        #expect(KeyCombo(keyCode: 40, modifiers: UInt32(cmdKey | alphaLock)).modifiers == UInt32(cmdKey))
    }

    @Test func whatCanBeAShortcut() {
        #expect(controlOptionK.isValid)
        #expect(KeyCombo(keyCode: UInt32(kVK_F5), modifiers: 0).isValid)
        #expect(!KeyCombo(keyCode: UInt32(kVK_ANSI_K), modifiers: 0).isValid)
        #expect(!KeyCombo(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(shiftKey)).isValid)
        #expect(!KeyCombo(keyCode: UInt32(kVK_Escape), modifiers: UInt32(cmdKey)).isValid)
    }

    @Test func theAppsOwnKeys() {
        let settings = settings()
        settings.panelHotKey = .controlOptionC
        settings.openPanelHotKey = .off
        settings.notch.hotKeys = false
        #expect(CommandHotKeys.reserved(settings).keys.map(\.title) == ["⌃⌥C"])
        settings.openPanelHotKey = .controlOptionB
        #expect(Set(CommandHotKeys.reserved(settings).keys.map(\.title)) == ["⌃⌥C", "⌃⌥B"])
        settings.openPanelHotKey = .off
        settings.panelHotKey = .off
        settings.notch.hotKeys = true
        #expect(Set(CommandHotKeys.reserved(settings).keys.map(\.title)) == ["⌃⌥Y", "⌃⌥N"])
        settings.notch.hotKeys = false
        settings.quickPrompt.hotKey = .controlOptionP
        #expect(CommandHotKeys.reserved(settings).isEmpty)
        #expect(CommandHotKeys.reserved(settings, quickPrompt: true).keys.map(\.title) == ["⌃⌥P"])
        settings.quickPrompt.hotKey = .off
        #expect(CommandHotKeys.reserved(settings, quickPrompt: true).isEmpty)
    }

    @Test func conflicts() {
        let y = KeyCombo(keyCode: UInt32(kVK_ANSI_Y), modifiers: controlOption)
        let commands = [
            QuickCommand(id: "a", title: "A", kind: .script, value: "a", hotKey: controlOptionK),
            QuickCommand(id: "b", title: "B", kind: .script, value: "b", hotKey: controlOptionK),
            QuickCommand(id: "c", title: "C", kind: .script, value: "c", hotKey: y),
            QuickCommand(id: "d", title: "D", kind: .script, value: "d"),
            QuickCommand(id: "e", title: "E", kind: .script, value: "e", hotKey: KeyCombo(keyCode: UInt32(kVK_ANSI_E), modifiers: 0)),
        ]
        let plan = CommandHotKeys.plan(commands: commands, reserved: [y: "остров"])
        #expect(plan.keys == [.init(command: "a", combo: controlOptionK)])
        #expect(plan.problems == ["b": .command("A"), "c": .app("остров")])
        #expect(plan.problems.values.allSatisfy { $0.blocks })
    }

    @Test func warnings() {
        #expect(CommandHotKeys.warning(for: KeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey))) == .system("Spotlight"))
        #expect(CommandHotKeys.warning(for: KeyCombo(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | shiftKey))) == .appShortcut)
        #expect(CommandHotKeys.warning(for: KeyCombo(keyCode: UInt32(kVK_F5), modifiers: UInt32(cmdKey))) == nil)
        #expect(CommandHotKeys.warning(for: controlOptionK) == nil)
        #expect(!HotKeyProblem.appShortcut.blocks && !HotKeyProblem.system("x").blocks)
    }

    @Test func registrationBookkeeping() {
        let settings = settings()
        settings.panelHotKey = .controlOptionC
        settings.notch.hotKeys = false
        settings.quickCommands = []
        var installed = false
        var calls: [[String]] = []
        var taken: Set<String> = []
        let hotKeys = CommandHotKeys(settings: settings, isInstalled: { installed }) { keys in
            calls.append(keys.map { "\($0.command) \($0.combo.title)" })
            return taken.intersection(keys.map(\.command))
        }
        settings.quickCommands = [QuickCommand(id: "a", title: "A", kind: .script, value: "a", hotKey: controlOptionK)]

        // Not installed: nothing registered.
        hotKeys.refresh()
        #expect(calls == [[]] && hotKeys.registered.isEmpty)

        installed = true
        hotKeys.refresh()
        #expect(calls.last == ["a ⌃⌥K"] && hotKeys.registered == ["a": controlOptionK])

        // A rename or another field changes nothing that is registered.
        settings.quickCommands[0].title = "AA"
        hotKeys.refresh()
        #expect(calls.count == 2)

        // A key another app holds.
        let f6 = KeyCombo(keyCode: UInt32(kVK_F6), modifiers: 0)
        taken = ["b"]
        settings.quickCommands.append(QuickCommand(id: "b", title: "B", kind: .open, value: "~", hotKey: f6))
        hotKeys.refresh()
        #expect(calls.last == ["a ⌃⌥K", "b F6"])
        #expect(hotKeys.registered == ["a": controlOptionK])
        #expect(hotKeys.problem(for: settings.quickCommands[1]) == .taken)

        // The search key moves onto the command's: the app's own wins.
        settings.panelHotKey = .off
        settings.quickCommands[0].hotKey = KeyCombo(keyCode: UInt32(kVK_ANSI_C), modifiers: controlOption)
        settings.panelHotKey = .controlOptionC
        hotKeys.refresh()
        #expect(calls.last == ["b F6"])
        #expect(hotKeys.problem(for: settings.quickCommands[0]) == .app(String(localized: "поиск AI Hub Bar")))

        // Deleted commands and a removed module let their keys go.
        settings.quickCommands.removeAll { $0.id == "b" }
        hotKeys.refresh()
        #expect(calls.last == [] && hotKeys.registered.isEmpty)
        settings.quickCommands[0].hotKey = controlOptionK
        hotKeys.refresh()
        installed = false
        hotKeys.refresh()
        #expect(calls.last == [] && hotKeys.registered.isEmpty)
    }

    @Test func aPressAsksLikeTheButton() {
        let tools = QuickToolsController()
        // An empty command only records «Команда пустая»: enough to see that it ran.
        let asking = QuickCommand(id: "q", title: "Q", kind: .script, value: "", confirm: true)
        var asked = 0
        tools.runFromHotKey(asking) { _ in asked += 1; return false }
        #expect(asked == 1 && tools.results["q"] == nil)
        tools.runFromHotKey(asking) { _ in asked += 1; return true }
        #expect(asked == 2 && tools.results["q"]?.isError == true)

        let direct = QuickCommand(id: "r", title: "R", kind: .script, value: "")
        tools.runFromHotKey(direct) { _ in asked += 1; return false }
        #expect(asked == 2 && tools.results["r"] != nil)
    }
}
