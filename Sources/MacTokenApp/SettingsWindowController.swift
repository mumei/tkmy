import AppKit
import SwiftUI
import UpdateSupport

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let settings: AppSettings

    init(settings: AppSettings, updateController: UpdateController) {
        self.settings = settings
        let hostingController = NSHostingController(
            rootView: SettingsView(settings: settings, updateController: updateController)
        )
        let window = NSWindow(contentViewController: hostingController)
        window.title = "TKMY 設定"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 520, height: 470))
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showSettings(on sourceScreen: NSScreen?) {
        settings.refreshLaunchAtLoginStatus()
        positionWindow(on: sourceScreen ?? screenContainingPointer ?? NSScreen.main)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var screenContainingPointer: NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
    }

    private func positionWindow(on screen: NSScreen?) {
        guard let window, let screen else { return }
        let visibleFrame = screen.visibleFrame
        let origin = NSPoint(
            x: visibleFrame.midX - window.frame.width / 2,
            y: visibleFrame.midY - window.frame.height / 2
        )
        window.setFrameOrigin(origin)
    }
}
