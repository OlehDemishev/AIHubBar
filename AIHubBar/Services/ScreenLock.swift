import CoreGraphics
import Foundation

/// «Заблокировать экран». macOS has no public call for it, so the first step is the system's own private one, the one
/// behind the Apple menu's item. A private call can stop working with a macOS update, even if it is still there, so
/// each step is judged by whether the screen did lock.
@MainActor
enum ScreenLock {
    struct Step {
        let name: String
        let action: @MainActor () async -> Void
    }

    /// Whether the screen is locked now. Tries each way in turn, so false means none of them locked it.
    static func lock() async -> Bool {
        await run(steps, isLocked: { isLocked }, settle: .seconds(2))
    }

    static func run(_ steps: [Step], isLocked: @MainActor () -> Bool, settle: Duration) async -> Bool {
        let clock = ContinuousClock()
        for step in steps {
            await step.action()
            let deadline = clock.now + settle
            repeat {
                if isLocked() {
                    AppLog.info("Lock screen: done by \(step.name)")
                    return true
                }
                try? await Task.sleep(for: .milliseconds(100))
            } while clock.now < deadline
            AppLog.error("Lock screen: \(step.name) did not lock it")
        }
        return false
    }

    private static let steps = [
        Step(name: "the login framework") { _ = privateLock()?() },
        // The Apple menu's shortcut, by key code: `keystroke "q"` depends on the keyboard layout.
        Step(name: "⌃⌘Q") {
            _ = await QuickToolsController.osascript("tell application \"System Events\" to key code 12 using {control down, command down}")
        },
        // Locks only with «Require password immediately» on; otherwise the check below says it didn't.
        Step(name: "the display's sleep") { _ = await QuickToolsController.displaySleep() },
    ]

    /// The system's own call, from the login framework; nil once a macOS drops it. Calling it locks this Mac at once.
    nonisolated static func privateLock() -> (@convention(c) () -> Int32)? {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
              let symbol = dlsym(handle, "SACLockScreenImmediate") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) () -> Int32).self)
    }

    private static var isLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}
