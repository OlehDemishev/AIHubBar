import Testing
@testable import ClaudePult

struct ReadinessTests {
    func input(claude: String? = "2.1.0", others: [String] = [], hooks: HookStatus = .installed,
               notifications: Readiness.Notifications = .allowed, loginItem: LoginItemState = .enabled) -> Readiness.Input {
        Readiness.Input(claudeVersion: claude, otherServices: others, hooks: hooks, notifications: notifications, loginItem: loginItem)
    }

    func item(_ id: ReadinessItem.ID, _ input: Readiness.Input) -> ReadinessItem {
        Readiness.items(input).first { $0.id == id }!
    }

    @Test func everythingDone() {
        let items = Readiness.items(input())
        #expect(items.map(\.id) == [.service, .hooks, .notifications, .loginItem])
        #expect(items.allSatisfy { $0.state == .done && $0.action == nil })
        #expect(Readiness.isReady(items))
        #expect(items[0].detail.contains("Claude Code 2.1.0"))
    }

    @Test func service() {
        let none = item(.service, input(claude: nil))
        #expect(none.state == .todo && none.action == .openServices)
        let other = item(.service, input(claude: nil, others: ["OpenAI"]))
        #expect(other.state == .done && other.detail.contains("OpenAI"), "another service is enough to start")
        #expect(item(.service, input(claude: "")).detail.contains("Claude Code."), "unknown version")
        #expect(item(.service, input(claude: "2.1.312 (Claude Code)")).detail.contains("Claude Code 2.1.312."))
        var scanning = input(claude: nil)
        scanning.servicesChecked = false
        #expect(item(.service, scanning).state == .optional && item(.service, scanning).action == nil, "no verdict before the first scan")
    }

    @Test func hooksNeedClaudeCode() {
        #expect(item(.hooks, input(claude: nil, hooks: .notInstalled)).state == .optional)
        #expect(item(.hooks, input(hooks: .notInstalled)).action == .installHooks)
        #expect(item(.hooks, input(hooks: .outdated)).action == .updateHooks)
    }

    @Test func notificationsAndLoginItem() {
        #expect(item(.notifications, input(notifications: .notAsked)).action == .allowNotifications)
        #expect(item(.notifications, input(notifications: .denied)).action == .openNotificationSettings)
        let off = input(loginItem: .disabled)
        #expect(item(.loginItem, off).state == .optional && item(.loginItem, off).action == .enableLoginItem)
        #expect(Readiness.isReady(Readiness.items(off)), "an optional row is not something left to do")
        #expect(item(.loginItem, input(loginItem: .requiresApproval)).action == .openLoginItems)
        #expect(!Readiness.isReady(Readiness.items(input(notifications: .denied))))
    }
}
