import Darwin
import Foundation
import IOKit
import IOKit.ps
import Observation

/// One reading of the Mac's resources (SPEC-profiles §4.1). Nothing here needs a permission.
struct SystemSnapshot: Equatable, Sendable {
    enum Pressure: Int, Sendable {
        case normal = 1, warning = 2, critical = 4
    }

    struct Battery: Equatable, Sendable {
        var percent: Int
        var charging: Bool
        var onAC: Bool
        /// Minutes to empty while on battery; nil while macOS is still estimating.
        var minutesLeft: Int?
    }

    var cpu: Double
    var memoryUsed: UInt64
    var memoryTotal: UInt64
    var pressure: Pressure
    var diskFree: Int64
    var diskTotal: Int64
    /// Bytes per second over all network interfaces except loopback.
    var networkIn: Double
    var networkOut: Double
    var battery: Battery?
    /// Graphics load, when macOS reports it.
    var gpu: Double?

    var memoryPercent: Double { memoryTotal == 0 ? 0 : Double(memoryUsed) / Double(memoryTotal) * 100 }
}

/// Reads the counters. The processor and network numbers are differences between two readings, so the first
/// reading only primes them.
struct SystemSampler: Sendable {
    private var cpuTicks: (busy: UInt64, total: UInt64)?
    private var network: (bytesIn: [String: UInt32], bytesOut: [String: UInt32], at: Date)?

    mutating func sample(now: Date = .now) -> SystemSnapshot {
        let memory = Self.memory()
        let disk = Self.disk()
        let (netIn, netOut) = networkRates(now: now)
        return SystemSnapshot(
            cpu: cpuUsage(), memoryUsed: memory.used, memoryTotal: memory.total, pressure: Self.pressure(),
            diskFree: disk.free, diskTotal: disk.total, networkIn: netIn, networkOut: netOut,
            battery: Self.battery(), gpu: Self.gpu()
        )
    }

    // MARK: Processor

    private mutating func cpuUsage() -> Double {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return 0 }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)) }
        var busy: UInt64 = 0, total: UInt64 = 0
        for cpu in 0..<Int(count) {
            let base = cpu * Int(CPU_STATE_MAX)
            let user = UInt64(info[base + Int(CPU_STATE_USER)]), system = UInt64(info[base + Int(CPU_STATE_SYSTEM)])
            let nice = UInt64(info[base + Int(CPU_STATE_NICE)]), idle = UInt64(info[base + Int(CPU_STATE_IDLE)])
            busy += user + system + nice
            total += user + system + nice + idle
        }
        defer { cpuTicks = (busy, total) }
        guard let previous = cpuTicks, total > previous.total else { return 0 }
        return Double(busy &- previous.busy) / Double(total - previous.total) * 100
    }

    // MARK: Memory

    /// «Used» as Activity Monitor counts it: app memory + wired + compressed.
    static func memory() -> (used: UInt64, total: UInt64) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        let total = ProcessInfo.processInfo.physicalMemory
        guard result == KERN_SUCCESS else { return (0, total) }
        let page = UInt64(getpagesize())
        let app = UInt64(stats.internal_page_count) - min(UInt64(stats.internal_page_count), UInt64(stats.purgeable_count))
        return ((app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page, total)
    }

    static func pressure() -> SystemSnapshot.Pressure {
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        return SystemSnapshot.Pressure(rawValue: Int(level)) ?? .normal
    }

    // MARK: Disk

    static func disk() -> (free: Int64, total: Int64) {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        return (values?.volumeAvailableCapacityForImportantUsage ?? 0, Int64(values?.volumeTotalCapacity ?? 0))
    }

    // MARK: Network

    /// Interface counters are 32-bit and wrap around; each interface is followed on its own.
    private mutating func networkRates(now: Date) -> (Double, Double) {
        var bytesIn: [String: UInt32] = [:], bytesOut: [String: UInt32] = [:]
        var list: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&list) == 0, let first = list {
            defer { freeifaddrs(list) }
            var pointer: UnsafeMutablePointer<ifaddrs>? = first
            while let entry = pointer?.pointee {
                defer { pointer = entry.ifa_next }
                let flags = Int32(entry.ifa_flags)
                guard entry.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), flags & IFF_LOOPBACK == 0, flags & IFF_UP != 0,
                      let data = entry.ifa_data?.assumingMemoryBound(to: if_data.self).pointee else { continue }
                let name = String(cString: entry.ifa_name)
                bytesIn[name] = data.ifi_ibytes
                bytesOut[name] = data.ifi_obytes
            }
        }
        defer { network = (bytesIn, bytesOut, now) }
        guard let previous = network, now > previous.at else { return (0, 0) }
        func delta(_ new: [String: UInt32], _ old: [String: UInt32]) -> Double {
            new.reduce(0) { sum, item in
                guard let before = old[item.key] else { return sum }
                return sum + Double(item.value &- before) // wraps correctly for 32-bit counters
            }
        }
        let seconds = now.timeIntervalSince(previous.at)
        return (delta(bytesIn, previous.bytesIn) / seconds, delta(bytesOut, previous.bytesOut) / seconds)
    }

    // MARK: Battery and graphics

    static func battery() -> SystemSnapshot.Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let minutes = description[kIOPSTimeToEmptyKey] as? Int
            return SystemSnapshot.Battery(
                percent: current * 100 / max,
                charging: description[kIOPSIsChargingKey] as? Bool ?? false,
                onAC: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                minutesLeft: minutes.flatMap { $0 > 0 ? $0 : nil }
            )
        }
        return nil
    }

    static func gpu() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: Double?
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer {
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }
            guard let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
                let value = (stats["Device Utilization %"] as? NSNumber)?.doubleValue else { continue }
            best = max(best ?? 0, value)
        }
        return best
    }
}

/// When to notify about resources (SPEC-profiles §4.1): each alert once per event, again only after it cleared.
struct ResourceAlerts: Sendable {
    enum Alert: Equatable, Sendable {
        case cpu, memory, disk(Int64), battery(Int)
    }

    static let cpuHigh = 90.0, cpuClear = 70.0
    static let cpuSustained: TimeInterval = 5 * 60
    static let batteryLow = 15, batteryClear = 20

    private var cpuHighSince: Date?
    private var fired: Set<String> = []

    mutating func evaluate(_ snapshot: SystemSnapshot, diskBelowGB: Int, now: Date = .now) -> [Alert] {
        var alerts: [Alert] = []
        func once(_ key: String, when active: Bool, clearedWhen cleared: Bool, _ alert: Alert) {
            if active, !fired.contains(key) {
                fired.insert(key)
                alerts.append(alert)
            } else if cleared {
                fired.remove(key)
            }
        }
        if snapshot.cpu >= Self.cpuHigh {
            if cpuHighSince == nil { cpuHighSince = now }
        } else if snapshot.cpu < Self.cpuClear {
            cpuHighSince = nil
        }
        once("cpu", when: cpuHighSince.map { now.timeIntervalSince($0) >= Self.cpuSustained } ?? false,
             clearedWhen: cpuHighSince == nil, .cpu)
        once("memory", when: snapshot.pressure == .critical, clearedWhen: snapshot.pressure == .normal, .memory)
        let limit = Int64(diskBelowGB) * 1_000_000_000
        once("disk", when: snapshot.diskFree > 0 && snapshot.diskFree < limit, clearedWhen: snapshot.diskFree >= limit + 2_000_000_000,
             .disk(snapshot.diskFree))
        if let battery = snapshot.battery {
            once("battery", when: !battery.onAC && battery.percent < Self.batteryLow,
                 clearedWhen: battery.onAC || battery.percent >= Self.batteryClear, .battery(battery.percent))
        }
        return alerts
    }
}

/// The «Ресурсы Mac» module: reads every 2 s while the panel is open, every 30 s otherwise (for the menu bar and the
/// alerts), and only while the module is installed.
@MainActor
@Observable
final class SystemMonitor {
    struct ProcessUsage: Equatable, Sendable {
        var name: String
        var cpu: Double
    }

    private(set) var snapshot: SystemSnapshot?
    private(set) var topProcesses: [ProcessUsage] = []
    var isPanelOpen = false {
        didSet { if isPanelOpen, !oldValue { loop?.cancel(); loop = nil; start() } }
    }
    /// Set by the app: whether «Ресурсы Mac» is installed.
    var isActive: () -> Bool = { false }

    private let settings: AppSettings
    private var sampler = SystemSampler()
    private var alerts = ResourceAlerts()
    private var loop: Task<Void, Never>?
    private var lastTopProcesses: Date?

    init(settings: AppSettings) {
        self.settings = settings
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await tick()
                try? await Task.sleep(for: .seconds(isPanelOpen ? 2 : 30))
            }
        }
    }

    private func tick() async {
        guard isActive() else {
            snapshot = nil
            topProcesses = []
            return
        }
        let reading = sampler.sample()
        // The first reading has no difference for the processor and the network yet.
        if snapshot == nil {
            try? await Task.sleep(for: .seconds(1))
            snapshot = sampler.sample()
        } else {
            snapshot = reading
        }
        if isPanelOpen, lastTopProcesses.map({ Date.now.timeIntervalSince($0) >= 5 }) ?? true {
            lastTopProcesses = .now
            topProcesses = await Self.topProcesses()
        }
        guard let snapshot, settings.resourceAlerts else { return }
        for alert in alerts.evaluate(snapshot, diskBelowGB: settings.resourceDiskBelowGB) { notify(alert) }
    }

    private func notify(_ alert: ResourceAlerts.Alert) {
        switch alert {
        case .cpu:
            Notifier.post(id: "resources-cpu", title: String(localized: "Процессор загружен"),
                          body: String(localized: "Больше 90 % уже 5 минут. Кто нагружает — в панели, блок «Ресурсы Mac»."))
        case .memory:
            Notifier.post(id: "resources-memory", title: String(localized: "Памяти не хватает"),
                          body: String(localized: "macOS сообщает о критической нехватке памяти. Закройте лишние приложения."))
        case let .disk(free):
            Notifier.post(id: "resources-disk", title: String(localized: "Мало места на диске"),
                          body: String(localized: "Свободно \(ResourceText.bytes(free))."))
        case let .battery(percent):
            Notifier.post(id: "resources-battery", title: String(localized: "Батарея садится"),
                          body: String(localized: "Осталось \(percent) %. Подключите зарядку."))
        }
    }

    /// The five processes using the most processor right now, by `ps` (no permission needed).
    nonisolated static func topProcesses() async -> [ProcessUsage] {
        guard let result = try? await ProcessRunner.run("/bin/ps", ["-Aceo", "pcpu=,comm=", "-r"], timeout: .seconds(5)),
              result.exitCode == 0 else { return [] }
        return parseProcesses(result.stdoutText)
    }

    nonisolated static func parseProcesses(_ output: String, limit: Int = 5) -> [ProcessUsage] {
        output.split(separator: "\n").compactMap { line -> ProcessUsage? in
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let cpu = Double(parts[0].replacingOccurrences(of: ",", with: ".")) else { return nil }
            let name = parts[1].trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : ProcessUsage(name: name, cpu: cpu)
        }
        .prefix(limit)
        .map { $0 }
    }
}

enum ResourceText {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func memory(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        String(localized: "\(ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file))/с")
    }
}
