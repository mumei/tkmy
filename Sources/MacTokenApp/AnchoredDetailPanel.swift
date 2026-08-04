import AppKit

@MainActor
final class AnchoredDetailPanel: NSPanel {
    var closeRequested: (() -> Void)?

    init(contentViewController: NSViewController, contentSize: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        self.contentViewController = contentViewController
        setContentSize(contentSize)
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isMovable = false
        animationBehavior = .none
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        contentView?.wantsLayer = true
        contentView?.layer?.cornerRadius = 12
        contentView?.layer?.cornerCurve = .continuous
        contentView?.layer?.masksToBounds = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            closeRequested?()
        } else {
            super.keyDown(with: event)
        }
    }
}
