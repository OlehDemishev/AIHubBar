import AppKit
import SwiftUI

/// «Ресурсы Mac» in the panel (SPEC-profiles §4.1): processor, memory, disk, network, battery, graphics and the
/// apps using the most processor right now.
struct ResourcesView: View {
    @Environment(SystemMonitor.self) private var monitor
    @AppStorage("collapsedBlocks") private var collapsedRaw = ""

    private var collapsed: Bool { PanelBlock.collapsed(in: collapsedRaw).contains(.resources) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                BlockTitle(block: .resources, title: "Ресурсы Mac")
                if collapsed, let snapshot = monitor.snapshot {
                    Text(verbatim: "CPU \(UsageText.percent(snapshot.cpu)) · RAM \(UsageText.percent(snapshot.memoryPercent))")
                        .scaledFont(.caption, weight: .semibold)
                        .monospacedDigit()
                }
                Spacer()
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                } label: {
                    Image(systemName: "chart.bar.xaxis")
                }
                .buttonStyle(.borderless)
                .help("Открыть Мониторинг системы")
            }
            if !collapsed {
                if let snapshot = monitor.snapshot {
                    details(snapshot)
                } else {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Считаю…").scaledFont(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func details(_ snapshot: SystemSnapshot) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 5) {
            gauge(String(localized: "Процессор"), snapshot.cpu, detail: nil)
            gauge(String(localized: "Память"), snapshot.memoryPercent,
                  detail: "\(ResourceText.memory(snapshot.memoryUsed)) / \(ResourceText.memory(snapshot.memoryTotal))",
                  warning: pressureText(snapshot.pressure))
            if let gpu = snapshot.gpu { gauge(String(localized: "Графика"), gpu, detail: nil) }
            let diskUsed = snapshot.diskTotal > 0 ? Double(snapshot.diskTotal - snapshot.diskFree) / Double(snapshot.diskTotal) * 100 : 0
            gauge(String(localized: "Диск"), diskUsed, detail: String(localized: "свободно \(ResourceText.bytes(snapshot.diskFree))"))
            GridRow {
                label(String(localized: "Сеть"))
                Text(verbatim: "↓ \(ResourceText.speed(snapshot.networkIn))   ↑ \(ResourceText.speed(snapshot.networkOut))")
                    .gridCellColumns(2)
                    .monospacedDigit()
            }
            .scaledFont(.caption)
            if let battery = snapshot.battery {
                GridRow {
                    label(String(localized: "Батарея"))
                    Text(batteryText(battery))
                        .foregroundStyle(!battery.onAC && battery.percent < ResourceAlerts.batteryLow ? .red : .primary)
                        .gridCellColumns(2)
                }
                .scaledFont(.caption)
            }
        }
        if !monitor.topProcesses.isEmpty {
            Text(monitor.topProcesses.prefix(3).map { "\($0.name) \(UsageText.percent($0.cpu))" }.joined(separator: " · "))
                .scaledFont(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(monitor.topProcesses.map { "\($0.name) — \(UsageText.percent($0.cpu))" }.joined(separator: "\n"))
        }
    }

    private func gauge(_ title: String, _ value: Double, detail: String?, warning: String? = nil) -> some View {
        GridRow {
            label(title)
            ProgressView(value: min(max(value, 0), 100), total: 100)
                .progressViewStyle(.linear)
                .tint(UsageWindow.color(for: value))
                .controlSize(.small)
                .frame(minWidth: 80)
            HStack(spacing: 4) {
                Text(UsageText.percent(value)).monospacedDigit().fontWeight(.semibold)
                if let warning {
                    Text(warning).foregroundStyle(.orange)
                } else if let detail {
                    Text(detail).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
        }
        .scaledFont(.caption)
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).gridColumnAlignment(.leading)
    }

    private func pressureText(_ pressure: SystemSnapshot.Pressure) -> String? {
        switch pressure {
        case .normal: nil
        case .warning: String(localized: "давление повышено")
        case .critical: String(localized: "памяти не хватает")
        }
    }

    private func batteryText(_ battery: SystemSnapshot.Battery) -> String {
        if battery.charging { return String(localized: "\(battery.percent) % · заряжается") }
        if battery.onAC { return String(localized: "\(battery.percent) % · от сети") }
        guard let minutes = battery.minutesLeft else { return "\(battery.percent) %" }
        return String(localized: "\(battery.percent) % · осталось \(minutes / 60) ч \(minutes % 60) мин")
    }
}
