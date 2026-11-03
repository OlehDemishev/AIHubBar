import AppKit
import SwiftUI

/// SwiftUI makes the Settings window fixed-size and takes `.resizable` away again after each layout pass; this puts
/// it back every time it goes, so the window can grow (SPEC-settings §2).
@MainActor
enum ResizableSettingsWindow {
    private static var observed: [ObjectIdentifier: NSKeyValueObservation] = [:]

    static func keep(_ window: NSWindow, minSize: CGSize, size: CGSize) {
        let id = ObjectIdentifier(window)
        guard observed[id] == nil else { return }
        observed[id] = window.observe(\.styleMask, options: [.new]) { window, _ in
            // AppKit changes the style mask on the main thread.
            MainActor.assumeIsolated {
                guard !window.styleMask.contains(.resizable) else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { window.styleMask.formUnion(.resizable) } }
            }
        }
        DispatchQueue.main.async {
            window.styleMask.formUnion(.resizable)
            window.contentMinSize = minSize
            if window.frame.width < size.width || window.frame.height < size.height { window.setContentSize(size) }
        }
    }
}

/// No title strip above the pages: the page header already names the page, as in System Settings. Only the title
/// and the bar's background go — hiding the whole window toolbar takes the close / minimise buttons with it.
struct NoWindowToolbar: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .toolbar(removing: .title)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            content
        }
    }
}
