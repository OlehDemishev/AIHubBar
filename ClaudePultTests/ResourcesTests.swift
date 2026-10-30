import Foundation
import Testing
@testable import ClaudePult

/// SPEC-profiles stage 4: «Ресурсы Mac», the first optional module.
struct ResourcesTests {
    private func snapshot(cpu: Double = 10, pressure: SystemSnapshot.Pressure = .normal, diskFree: Int64 = 100_000_000_000,
                          battery: SystemSnapshot.Battery? = nil) -> SystemSnapshot {
        SystemSnapshot(cpu: cpu, memoryUsed: 8 << 30, memoryTotal: 16 << 30, pressure: pressure, diskFree: diskFree,
                       diskTotal: 500_000_000_000, networkIn: 0, networkOut: 0, battery: battery, gpu: nil)
    }

    @Test func alertsOncePerEvent() {
        var alerts = ResourceAlerts()
        let start = Date(timeIntervalSince1970: 1_000_000)
        #expect(alerts.evaluate(snapshot(cpu: 95), diskBelowGB: 20, now: start).isEmpty, "a spike is not a reason")
        #expect(alerts.evaluate(snapshot(cpu: 92), diskBelowGB: 20, now: start.addingTimeInterval(4 * 60)).isEmpty)
        #expect(alerts.evaluate(snapshot(cpu: 93), diskBelowGB: 20, now: start.addingTimeInterval(5 * 60)) == [.cpu])
        #expect(alerts.evaluate(snapshot(cpu: 93), diskBelowGB: 20, now: start.addingTimeInterval(6 * 60)).isEmpty, "once")
        _ = alerts.evaluate(snapshot(cpu: 30), diskBelowGB: 20, now: start.addingTimeInterval(7 * 60))
        _ = alerts.evaluate(snapshot(cpu: 95), diskBelowGB: 20, now: start.addingTimeInterval(8 * 60))
        #expect(alerts.evaluate(snapshot(cpu: 95), diskBelowGB: 20, now: start.addingTimeInterval(13 * 60)) == [.cpu], "again after it cleared")

        #expect(alerts.evaluate(snapshot(pressure: .critical), diskBelowGB: 20) == [.memory])
        #expect(alerts.evaluate(snapshot(pressure: .warning), diskBelowGB: 20).isEmpty, "not cleared until normal")
        #expect(alerts.evaluate(snapshot(pressure: .critical), diskBelowGB: 20).isEmpty)

        #expect(alerts.evaluate(snapshot(diskFree: 15_000_000_000), diskBelowGB: 20) == [.disk(15_000_000_000)])
        #expect(alerts.evaluate(snapshot(diskFree: 21_000_000_000), diskBelowGB: 20).isEmpty, "a little above the limit is not cleared yet")
        _ = alerts.evaluate(snapshot(diskFree: 30_000_000_000), diskBelowGB: 20)
        #expect(alerts.evaluate(snapshot(diskFree: 10_000_000_000), diskBelowGB: 20) == [.disk(10_000_000_000)])

        let low = SystemSnapshot.Battery(percent: 12, charging: false, onAC: false, minutesLeft: 20)
        #expect(alerts.evaluate(snapshot(battery: low), diskBelowGB: 20) == [.battery(12)])
        var plugged = low
        plugged.onAC = true
        #expect(alerts.evaluate(snapshot(battery: plugged), diskBelowGB: 20).isEmpty, "no alert while charging")
    }

    @Test func topProcessesFromPs() {
        let output = """
         45,3 Xcode
         12.0 Safari
          0.0 launchd
        bad line
        """
        let top = SystemMonitor.parseProcesses(output, limit: 2)
        #expect(top == [.init(name: "Xcode", cpu: 45.3), .init(name: "Safari", cpu: 12)])
    }

    @Test func aRealReadingIsSane() async throws {
        var sampler = SystemSampler()
        _ = sampler.sample()
        try await Task.sleep(for: .milliseconds(300))
        let reading = sampler.sample()
        #expect((0...100).contains(reading.cpu))
        #expect(reading.memoryTotal > 0 && reading.memoryUsed <= reading.memoryTotal)
        #expect(reading.diskTotal > 0 && reading.diskFree <= reading.diskTotal)
        #expect(reading.networkIn >= 0 && reading.networkOut >= 0)
    }

    @Test func menuBarShowsProcessorAndMemory() {
        var config = MenuBarConfig.make(.minimum)
        config.set(.icon) { $0.enabled = false }
        config.set(.cpu) { $0.enabled = true }
        config.set(.memory) { $0.enabled = true; $0.style = .bar; $0.showAbove = 80 }
        var data = MenuBarData()
        data.cpu = 23
        data.memory = 71
        #expect(MenuBarComposer.groups(config, data) == [[.labeled(symbol: "cpu", text: "23%", .level(23))]], "memory below its 80 %")
        data.memory = 85
        #expect(MenuBarComposer.groups(config, data).last == [.symbol("memorychip"), .bar(85, .level(85))])
        #expect(MenuBarComposer.groups(config, MenuBarData()) == [[.symbol("sparkle")]], "nothing without the module")
    }
}

@MainActor
struct OptionalModuleTests {
    private func store() -> (ModeStore, AppSettings, URL) {
        let name = "claudepult-optional-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let settings = AppSettings(defaults: defaults)
        settings.projectsDirectory = NSHomeDirectory() + "/Projects"
        settings.dailyReportDirectory = NSHomeDirectory() + "/Projects/_daily-report"
        let dir = FileManager.default.temporaryDirectory.appending(path: name)
        return (ModeStore(settings: settings, directory: dir), settings, dir)
    }

    @Test func installAddsToTheCurrentProfileAndRemoveTakesItEverywhere() throws {
        let (store, settings, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try #require(store.current)
        let second = try #require(store.duplicate(first.id))
        store.install(.resources)
        #expect(store.installedModules.contains(.resources))
        #expect(store.current?.modules?.last == ProfileModule(.resources))
        #expect(store.panelModules.last == .resources)
        #expect(store.modes.first { $0.id == second.id }?.modules?.contains { $0.kind == .resources } == false, "only the current profile")

        store.addModule(.resources, to: second.id)
        var moved = try #require(store.current)
        moved.modules = [ProfileModule(.resources)] + (moved.modules ?? []).filter { $0.kind != .resources }
        store.update(moved)
        #expect(store.current?.modules?.first?.kind == .resources, "an optional module keeps the place it was given")

        store.removeModule(.resources, from: first.id)
        #expect(store.installedModules.contains(.resources), "removed from a profile, still installed")
        store.uninstall(.resources)
        #expect(!store.installedModules.contains(.resources))
        #expect(store.modes.allSatisfy { !($0.modules ?? []).contains { $0.kind == .resources } })
        #expect(ModeStore(settings: settings, directory: dir).installedModules.contains(.resources) == false)
        store.install(.limits)
        #expect(store.current?.modules?.filter { $0.kind == .limits }.count == 1, "built-in modules are not installed by hand")
    }

    @Test func theAssistantInstallsTickedOptionalModules() {
        var draft = AssistantDraft(firstLaunch: false, menuBar: .make(.limits), hiddenBlocks: [], reminderHours: [24])
        draft.setModule(.resources, true)
        #expect(draft.hasModule(.resources) && draft.extraModules == [.resources])
        draft.setModule(.resources, false)
        #expect(draft.extraModules.isEmpty)
    }
}
