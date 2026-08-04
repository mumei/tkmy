import AppKit
import Combine
import SwiftUI
import UpdateSupport
import UsageDomain
import UsageUI

@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let detailPanel: AnchoredDetailPanel
    private let viewModel: SourceUsageViewModel
    private let updateController: UpdateController
    private let settings: AppSettings
    private let openSettings: (NSScreen?) -> Void
    private let statusItemsDidChange: () -> Void
    private let closeOtherPopovers: (StatusItemController) -> Void
    private var hoverTimer: Timer?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []

    init(
        viewModel: SourceUsageViewModel,
        updateController: UpdateController,
        settings: AppSettings,
        openSettings: @escaping (NSScreen?) -> Void,
        statusItemsDidChange: @escaping () -> Void,
        closeOtherPopovers: @escaping (StatusItemController) -> Void
    ) {
        self.viewModel = viewModel
        self.updateController = updateController
        self.settings = settings
        self.openSettings = openSettings
        self.statusItemsDidChange = statusItemsDidChange
        self.closeOtherPopovers = closeOtherPopovers
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let rootView: AnyView = switch viewModel.source {
        case .codex: AnyView(CodexUsagePopoverView(viewModel: viewModel))
        case .claudeCode: AnyView(ClaudeCodeUsagePopoverView(viewModel: viewModel))
        }
        detailPanel = AnchoredDetailPanel(
            contentViewController: NSHostingController(rootView: rootView),
            contentSize: NSSize(width: 640, height: 560)
        )
        super.init()
        detailPanel.closeRequested = { [weak self] in self?.close() }

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemPressed(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = L10n.text("token_usage_tooltip", viewModel.source.displayName)
            button.addTrackingArea(NSTrackingArea(
                rect: button.bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            ))
        }

        viewModel.$dailyUsage
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateTitle() }
            .store(in: &cancellables)
        viewModel.$usageLimit
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateTitle() }
            .store(in: &cancellables)
        menuVisibilityPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] isVisible in
                guard let self else { return }
                if !isVisible { self.close() }
                self.statusItem.isVisible = isVisible
                self.statusItemsDidChange()
            }
            .store(in: &cancellables)
        settings.$menuMeterStyle
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateTitle() }
            .store(in: &cancellables)
        settings.$showsRemainingPercentage
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateTitle() }
            .store(in: &cancellables)
        settings.$showsMenuLabel
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateTitle() }
            .store(in: &cancellables)
        settings.$meterContentOrder
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateTitle() }
            .store(in: &cancellables)
        settings.$appLanguage
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateTitle() }
            .store(in: &cancellables)
        updateTitle()
    }

    func close() {
        hoverTimer?.invalidate()
        detailPanel.orderOut(nil)
        removeClickMonitors()
    }

    func repositionIfShown() {
        guard detailPanel.isVisible, let button = statusItem.button else { return }
        positionDetailPanel(relativeTo: button)
    }

    @objc func mouseEntered(with event: NSEvent) {
        guard settings.opensDetailsOnHover else { return }
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.showPopover(activateApplication: false) }
        }
    }

    @objc func mouseExited(with event: NSEvent) {
        hoverTimer?.invalidate()
    }

    @objc private func statusItemPressed(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu(from: sender)
        } else if detailPanel.isVisible {
            close()
        } else {
            showPopover(activateApplication: true)
        }
    }

    private func showPopover(activateApplication: Bool) {
        guard let button = statusItem.button, !detailPanel.isVisible else { return }
        closeOtherPopovers(self)
        positionDetailPanel(relativeTo: button)
        installClickMonitors()
        if activateApplication {
            NSApp.activate(ignoringOtherApps: true)
            detailPanel.makeKeyAndOrderFront(nil)
        } else {
            detailPanel.orderFrontRegardless()
        }
    }

    private func showMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        let refresh = NSMenuItem(title: L10n.text("refresh"), action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: L10n.text("settings"), action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let update = NSMenuItem(title: L10n.text("check_for_updates"), action: #selector(checkForUpdates), keyEquivalent: "")
        update.target = self
        update.isEnabled = updateController.isConfigured
        menu.addItem(update)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: L10n.text("quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        statusItem.menu = menu
        button.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func refreshNow() {
        Task { await viewModel.refresh() }
    }

    @objc private func checkForUpdates() {
        updateController.checkForUpdates()
    }

    @objc private func showSettings() {
        close()
        openSettings(statusItem.button?.window?.screen)
    }

    private func updateTitle() {
        let total = viewModel.todayUsage?.tokens.total
        if let limit = viewModel.usageLimit {
            let remaining = Self.percentageText(limit.remainingPercent)
            let used = Self.percentageText(limit.usedPercent)
            applyMeterStyle(remainingPercent: limit.remainingPercent, label: remaining)

            var details = [L10n.text("weekly_remaining", remaining), L10n.text("used_format", used)]
            if let resetsAt = limit.resetsAt {
                let resetDate = resetsAt.formatted(.dateTime.month().day().locale(L10n.locale))
                details.append(L10n.text("reset_format", resetDate))
            }
            if let total {
                details.append(L10n.text("today_tokens", total.formatted(.number.locale(L10n.locale))))
            }
            let detail = details.joined(separator: "・")
            statusItem.button?.toolTip = detail
            statusItem.button?.setAccessibilityLabel("\(shortName)、\(detail)")
        } else {
            applyMeterStyle(remainingPercent: 0, label: "—")
            let tokenDetail = total.map {
                "・" + L10n.text("today_tokens", $0.formatted(.number.locale(L10n.locale)))
            } ?? ""
            let detail = L10n.text("no_limit") + tokenDetail
            statusItem.button?.toolTip = detail
            statusItem.button?.setAccessibilityLabel("\(shortName)、\(detail)")
        }
        statusItem.length = NSStatusItem.variableLength
        statusItemsDidChange()
    }

    private func applyMeterStyle(remainingPercent: Double, label: String) {
        guard let button = statusItem.button else { return }
        let image = MenuMeterRenderer.image(
            style: settings.menuMeterStyle,
            percentage: remainingPercent,
            source: viewModel.source
        )
        let sourceLabel = settings.showsMenuLabel ? shortName : ""
        let remainingLabel = settings.showsRemainingPercentage ? L10n.text("remaining_format", label) : ""
        var title = [sourceLabel, remainingLabel].filter { !$0.isEmpty }.joined(separator: " ")

        // A text-only style must retain one visible, clickable status item.
        if image == nil, title.isEmpty {
            title = shortName
        }

        button.image = image
        button.title = title
        if image != nil {
            button.imagePosition = settings.meterContentOrder == .graphLeading
                ? .imageLeading
                : .imageTrailing
            button.imageScaling = .scaleNone
        } else {
            button.imagePosition = .noImage
        }
    }

    private func positionDetailPanel(relativeTo button: NSStatusBarButton) {
        guard let statusWindow = button.window else { return }
        button.layoutSubtreeIfNeeded()
        let buttonInWindow = button.convert(button.bounds, to: nil)
        let anchor = statusWindow.convertToScreen(buttonInWindow)
        guard let screen = statusWindow.screen ?? NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) else {
            return
        }

        let inset: CGFloat = 8
        let gap: CGFloat = 6
        let visibleFrame = screen.visibleFrame
        let panelSize = detailPanel.frame.size
        let minimumX = visibleFrame.minX + inset
        let maximumX = max(minimumX, visibleFrame.maxX - panelSize.width - inset)
        let x = min(max(anchor.midX - panelSize.width / 2, minimumX), maximumX)

        let below = anchor.minY - panelSize.height - gap
        let minimumY = visibleFrame.minY + inset
        let maximumY = max(minimumY, visibleFrame.maxY - panelSize.height - inset)
        let y = min(max(below, minimumY), maximumY)
        detailPanel.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
    }

    private func installClickMonitors() {
        removeClickMonitors()
        let events: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]

        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            guard let self else { return event }
            let statusItemWindow = self.statusItem.button?.window
            guard event.window !== self.detailPanel, event.window !== statusItemWindow else {
                return event
            }
            self.close()
            return event
        }

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    private func removeClickMonitors() {
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
    }

    private var shortName: String {
        viewModel.source == .codex ? "Codex" : "Claude"
    }

    private var menuVisibilityPublisher: AnyPublisher<Bool, Never> {
        switch viewModel.source {
        case .codex: settings.$showsCodexMenu.eraseToAnyPublisher()
        case .claudeCode: settings.$showsClaudeMenu.eraseToAnyPublisher()
        }
    }

    private static func percentageText(_ value: Double) -> String {
        "\(Int(min(100, max(0, value)).rounded()))%"
    }

}
