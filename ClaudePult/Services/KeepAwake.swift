import AppKit
import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import Observation

/// «Не спать» rules (SPEC-profiles §4.2): any rule that holds keeps the Mac awake. Stored in UserDefaults.
struct KeepAwakeRules: Codable, Equatable, Sendable {
    struct App: Codable, Equatable, Hashable, Sendable {
        var bundleID: String
        var name: String
    }

    /// While a Claude Code session or a background run is working.
    var whileClaudeWorks = true
    var whileOnPower = false
    var whileExternalDisplay = false
    var whileApps: [App] = []
    /// Keep the display on too, not only the system.
    var keepDisplayOn = false
    /// Also with the lid closed (`LidSleep`; needs the administrator's permission once).
    var lidClosed = false

    enum CodingKeys: String, CodingKey { case whileClaudeWorks, whileOnPower, whileExternalDisplay, whileApps, keepDisplayOn, lidClosed }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        whileClaudeWorks = (try? c.decodeIfPresent(Bool.self, forKey: .whileClaudeWorks)) ?? true
        whileOnPower = (try? c.decodeIfPresent(Bool.self, forKey: .whileOnPower)) ?? false
        whileExternalDisplay = (try? c.decodeIfPresent(Bool.self, forKey: .whileExternalDisplay)) ?? false
        whileApps = (try? c.decodeIfPresent([App].self, forKey: .whileApps)) ?? []
        keepDisplayOn = (try? c.decodeIfPresent(Bool.self, forKey: .keepDisplayOn)) ?? false
        lidClosed = (try? c.decodeIfPresent(Bool.self, forKey: .lidClosed)) ?? false
    }

    /// What is around right now, as the rules see it.
    struct Situation: Equatable, Sendable {
        var claudeWorking = false
        var onPower = false
        var externalDisplay = false
        var runningApps: Set<String> = []
    }

    /// Why the Mac is held awake, or nil. A manual hold comes first; then the rules in the order they're listed.
    enum Reason: Equatable, Sendable {
        case manual(until: Date?)
        case claude
        case power
        case display
        case app(String)
    }

    func reason(manualUntil: Date??, situation: Situation, now: Date = .now) -> Reason? {
        if let manual = manualUntil, manual.map({ $0 > now }) ?? true { return .manual(until: manual) }
        if whileClaudeWorks, situation.claudeWorking { return .claude }
        if whileOnPower, situation.onPower { return .power }
        if whileExternalDisplay, situation.externalDisplay { return .display }
        if let app = whileApps.first(where: { situation.runningApps.contains($0.bundleID) }) { return .app(app.name) }
        return nil
    }
}

/// Holds the Mac awake through a power assertion while a rule says so. Nothing in System Settings changes; when no
/// rule holds, the assertion is released and the Mac sleeps as usual. Only while «Не спать» is installed.
@MainActor
@Observable
final class KeepAwakeController {
    private(set) var reason: KeepAwakeRules.Reason?
    /// A manual hold: `.some(nil)` = until switched off, `.some(date)` = until then, nil = none.
    private(set) var manualUntil: Date??
    /// Set by the app: whether «Не спать» is installed, and whether Claude is working right now.
    var isActive: () -> Bool = { false }
    var claudeWorking: () -> Bool = { false }
    /// Sleep is off with the lid closed while a rule holds (`LidSleep`).
    private(set) var lidHeld = false
    private(set) var lidInstalled = LidSleep.isInstalled
    private var lidBusy = false

    private let settings: AppSettings
    private var systemAssertion: IOPMAssertionID?
    private var displayAssertion: IOPMAssertionID?
    private var loop: Task<Void, Never>?

    init(settings: AppSettings) {
        self.settings = settings
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            // The sessions are read at launch; the first look waits for them.
            try? await Task.sleep(for: .seconds(3))
            while !Task.isCancelled {
                guard let self else { return }
                evaluate()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    /// «на 15 мин», «на 1 ч», «до выключения» (nil).
    func holdManually(for duration: TimeInterval?) {
        manualUntil = .some(duration.map { Date.now.addingTimeInterval($0) })
        evaluate()
    }

    func stopManual() {
        manualUntil = nil
        evaluate()
    }

    func evaluate() {
        guard isActive() else {
            manualUntil = nil
            apply(nil)
            updateLid(holding: false, onPower: true)
            return
        }
        if let manual = manualUntil, let until = manual, until <= .now { manualUntil = nil }
        let situation = KeepAwakeRules.Situation(
            claudeWorking: claudeWorking(),
            onPower: Self.onPower(),
            externalDisplay: Self.externalDisplay(),
            runningApps: Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        )
        apply(settings.keepAwakeRules.reason(manualUntil: manualUntil, situation: situation))
        updateLid(holding: reason != nil, onPower: situation.onPower)
    }

    /// Runs `pmset` only while the lid hold is wanted or was set by ClaudePult; otherwise nothing to do.
    private func updateLid(holding: Bool, onPower: Bool) {
        lidInstalled = LidSleep.isInstalled
        let want = LidSleep.wanted(holding: holding, lidRule: settings.keepAwakeRules.lidClosed, installed: lidInstalled,
                                   onPower: onPower, battery: SystemSampler.battery()?.percent, hasLid: LidSleep.hasLid)
        guard want || LidSleep.ours else {
            lidHeld = false
            return
        }
        guard !lidBusy else { return }
        lidBusy = true
        Task {
            defer { lidBusy = false }
            var disabled = await LidSleep.systemSleepDisabled()
            switch LidSleep.step(want: want, sleepDisabled: disabled, ours: LidSleep.ours) {
            case .disableSleep:
                if await LidSleep.setSleepDisabled(true) {
                    LidSleep.ours = true
                    disabled = true
                    AppLog.info("Keep awake: sleep off with the lid closed")
                }
            case .enableSleep:
                if await LidSleep.setSleepDisabled(false) {
                    LidSleep.ours = false
                    disabled = false
                    AppLog.info("Keep awake: sleep back on with the lid closed")
                }
            case .none:
                // Someone else turned sleep back on: nothing of ours is left to undo.
                if !disabled { LidSleep.ours = false }
            }
            lidHeld = want && disabled
        }
    }

    func installLidPermission() async -> LidSleep.AdminResult {
        let result = await LidSleep.install()
        lidInstalled = LidSleep.isInstalled
        evaluate()
        return result
    }

    /// Sleep goes back on first (while the rule still allows it), then the rule is removed.
    func removeLidPermission() async -> LidSleep.AdminResult {
        if LidSleep.ours, await LidSleep.setSleepDisabled(false) { LidSleep.ours = false }
        lidHeld = false
        let result = await LidSleep.uninstall()
        lidInstalled = LidSleep.isInstalled
        return result
    }

    /// On quit: sleep back on if ClaudePult turned it off.
    func releaseOnQuit() {
        if LidSleep.ours { LidSleep.enableSleepNow() }
    }

    private func apply(_ newReason: KeepAwakeRules.Reason?) {
        if newReason != reason {
            AppLog.info("Keep awake: " + (newReason.map { "\($0)" } ?? "off"))
        }
        reason = newReason
        // Shown by `pmset -g assertions`, which leaves non-ASCII names empty: a fixed technical name.
        let name = "ClaudePult keep awake" as CFString
        if newReason != nil {
            if systemAssertion == nil {
                var id = IOPMAssertionID(0)
                if IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), name, &id) == kIOReturnSuccess {
                    systemAssertion = id
                }
            }
            if settings.keepAwakeRules.keepDisplayOn, displayAssertion == nil {
                var id = IOPMAssertionID(0)
                if IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), name, &id) == kIOReturnSuccess {
                    displayAssertion = id
                }
            } else if !settings.keepAwakeRules.keepDisplayOn, let id = displayAssertion {
                IOPMAssertionRelease(id)
                displayAssertion = nil
            }
        } else {
            if let id = systemAssertion { IOPMAssertionRelease(id) }
            if let id = displayAssertion { IOPMAssertionRelease(id) }
            systemAssertion = nil
            displayAssertion = nil
        }
    }

    static func onPower() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return true }
        return type == kIOPMACPowerKey
    }

    /// A display that is not the Mac's own screen (on a Mac without one, every display counts).
    static func externalDisplay() -> Bool {
        NSScreen.screens.contains { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(number.uint32Value) == 0
        }
    }
}

enum KeepAwakeText {
    static func status(_ reason: KeepAwakeRules.Reason?, now: Date = .now) -> String {
        switch reason {
        case nil: String(localized: "Mac засыпает как обычно")
        case .manual(until: nil)?: String(localized: "держу до выключения")
        case let .manual(until: date?)?: String(localized: "держу ещё \(max(1, Int(date.timeIntervalSince(now) / 60))) мин")
        case .claude?: String(localized: "держу: работает Claude")
        case .power?: String(localized: "держу: подключено питание")
        case .display?: String(localized: "держу: подключён монитор")
        case let .app(name)?: String(localized: "держу: запущено «\(name)»")
        }
    }
}
