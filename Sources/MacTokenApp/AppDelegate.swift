import AppKit
import UpdateSupport
import UsageDomain
import UsagePricing
import UsageStore
import UsageUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusControllers: [StatusItemController] = []
    private var watchers: [DirectoryWatcher] = []
    private var coordinator: UsageCoordinator?
    private var viewModels: [SourceUsageViewModel] = []
    private var fallbackRefreshTimer: Timer?
    private var settingsWindowController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let store = try SQLiteUsageStore()
            let calculator = try UsagePriceCalculator.bundled()
            let coordinator = UsageCoordinator(store: store, calculator: calculator)
            self.coordinator = coordinator

            let codexModel = makeViewModel(source: .codex, coordinator: coordinator)
            let claudeModel = makeViewModel(source: .claudeCode, coordinator: coordinator)
            viewModels = [codexModel, claudeModel]

            let updates = UpdateController()
            let settings = AppSettings()
            let settingsWindowController = SettingsWindowController(
                settings: settings,
                updateController: updates
            )
            self.settingsWindowController = settingsWindowController
            for model in viewModels {
                let controller = StatusItemController(
                    viewModel: model,
                    updateController: updates,
                    settings: settings,
                    openSettings: { [weak settingsWindowController] screen in
                        settingsWindowController?.showSettings(on: screen)
                    },
                    statusItemsDidChange: { [weak self] in
                        Task { @MainActor in
                            await Task.yield()
                            self?.statusControllers.forEach { $0.repositionIfShown() }
                        }
                    },
                    closeOtherPopovers: { [weak self] active in
                        self?.statusControllers.filter { $0 !== active }.forEach { $0.close() }
                    }
                )
                statusControllers.append(controller)
            }
            installWatchers(coordinator: coordinator)
            fallbackRefreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.refreshAll() }
            }
            Task { await refreshAll() }
        } catch {
            presentStartupFailure(error)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        watchers.forEach { $0.cancel() }
        fallbackRefreshTimer?.invalidate()
    }

    private func makeViewModel(source: UsageSource, coordinator: UsageCoordinator) -> SourceUsageViewModel {
        SourceUsageViewModel(source: source) {
            try await coordinator.load(source)
        }
    }

    private func installWatchers(coordinator: UsageCoordinator) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var roots = [
            home.appendingPathComponent(".codex/sessions", isDirectory: true),
            home.appendingPathComponent(".codex/archived_sessions", isDirectory: true),
            home.appendingPathComponent(".claude/projects", isDirectory: true),
            home.appendingPathComponent(".config/claude/projects", isDirectory: true),
        ]
        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"] {
            roots.append(URL(fileURLWithPath: codexHome).appendingPathComponent("sessions", isDirectory: true))
            roots.append(URL(fileURLWithPath: codexHome).appendingPathComponent("archived_sessions", isDirectory: true))
        }
        if let claudeHome = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
            roots.append(URL(fileURLWithPath: claudeHome).appendingPathComponent("projects", isDirectory: true))
        }
        let watcher = DirectoryWatcher(urls: roots) { [weak self] in
            guard let self else { return }
            Task {
                await coordinator.scheduleRefresh { [weak self] in
                    await self?.refreshAll()
                }
            }
        }
        watcher.start()
        watchers = [watcher]
    }

    private func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for model in viewModels {
                group.addTask { await model.refresh() }
            }
        }
    }

    private func presentStartupFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = L10n.text("startup_failed")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: L10n.text("exit"))
        alert.runModal()
        NSApp.terminate(nil)
    }
}
