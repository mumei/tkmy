import AppKit
import XCTest
import UpdateSupport
import UsageUI
@testable import TKMYApp

final class StatusItemTrackingSelectorTests: XCTestCase {
    @MainActor
    func testTrackingOwnerRespondsToAppKitEventSelectors() {
        // NSTrackingArea dispatches these Objective-C selectors to its owner.
        // Inspect the real compiled class rather than its source text.
        for name in ["mouseEntered:", "mouseExited:"] {
            XCTAssertTrue(StatusItemController.instancesRespond(to: NSSelectorFromString(name)), name)
        }
        XCTAssertEqual(NSStringFromSelector(#selector(StatusItemController.mouseEntered(with:))), "mouseEntered:")
        XCTAssertEqual(NSStringFromSelector(#selector(StatusItemController.mouseExited(with:))), "mouseExited:")
    }

    @MainActor
    func testTrackingEventsDispatchToRealOwnerWithHoverEnabledAndDisabled() throws {
        _ = NSApplication.shared
        let suite = "TKMYTrackingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let controller = StatusItemController(
            viewModel: SourceUsageViewModel(source: .codex),
            updateController: UpdateController(),
            settings: settings,
            openSettings: { _ in },
            statusItemsDidChange: {},
            closeOtherPopovers: { _ in }
        )
        defer { controller.close() }
        for enabled in [false, true] {
            settings.opensDetailsOnHover = enabled
            for type in [NSEvent.EventType.mouseEntered, .mouseExited] {
                let name = type == .mouseEntered ? "mouseEntered:" : "mouseExited:"
                let selector = NSSelectorFromString(name)
                let event = try XCTUnwrap(NSEvent.enterExitEvent(
                    with: type, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 1, userData: nil
                ))
                XCTAssertTrue(controller.responds(to: selector), name)
                guard controller.responds(to: selector) else { continue }
                // Send precisely the message NSTrackingArea sends, with a real NSEvent.
                controller.perform(selector, with: event)
            }
        }
    }
}
