import Foundation
import WidgetKit

/// What the «Сессии и проекты» widget and the «Не спать» control show: written by the app to
/// `widget-status.json` (the widget is sandboxed and only reads Application Support/ClaudePult).
struct WidgetStatus: Codable, Equatable, Sendable {
    /// Projects whose sessions wait for an answer.
    var waiting: [String]
    var running: Int
    /// Projects whose health is red.
    var problems: [String]
    var keepAwake: Bool
    var keepAwakeInstalled: Bool

    static let url = SessionFiles.supportDirectory.appending(path: "widget-status.json")
    /// The control asks the app through a Darwin notification: a sandboxed extension can't write the app's files.
    static let keepAwakeOn = "com.demishev.claudepult.keepawake.on"
    static let keepAwakeOff = "com.demishev.claudepult.keepawake.off"
}

/// Keeps `widget-status.json` current and tells WidgetKit when it changed; takes the control's requests.
@MainActor
final class WidgetStatusWriter {
    private var last: WidgetStatus?
    private var loop: Task<Void, Never>?
    private let make: () -> WidgetStatus

    init(make: @escaping () -> WidgetStatus) {
        self.make = make
    }

    func start(onKeepAwake: @escaping (Bool) -> Void) {
        guard loop == nil else { return }
        KeepAwakeRequests.handler = onKeepAwake
        KeepAwakeRequests.listen()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.update()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    /// Also called right after the control changed something, so it doesn't wait for the next tick.
    func update() {
        let status = make()
        guard status != last else { return }
        last = status
        try? FileManager.default.createDirectory(at: WidgetStatus.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(status).write(to: WidgetStatus.url, options: .atomic)
        WidgetCenter.shared.reloadTimelines(ofKind: "ClaudePultStatus")
        if #available(macOS 26.0, *) {
            ControlCenter.shared.reloadControls(ofKind: "com.demishev.claudepult.keepawake")
        }
    }
}

/// Darwin notifications carry no payload: «on» and «off» are two names.
@MainActor
enum KeepAwakeRequests {
    static var handler: ((Bool) -> Void)?
    private static var listening = false

    static func listen() {
        guard !listening else { return }
        listening = true
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        for name in [WidgetStatus.keepAwakeOn, WidgetStatus.keepAwakeOff] {
            CFNotificationCenterAddObserver(center, nil, { _, _, name, _, _ in
                let on = (name?.rawValue as String?) == WidgetStatus.keepAwakeOn
                DispatchQueue.main.async { MainActor.assumeIsolated { KeepAwakeRequests.handler?(on) } }
            }, name as CFString, nil, .deliverImmediately)
        }
    }
}
