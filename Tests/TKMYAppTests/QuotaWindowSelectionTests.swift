import AppKit
import SwiftUI
import XCTest
import UsageDomain
@testable import UsageUI
import UpdateSupport
@testable import TKMYApp

final class QuotaWindowSelectionTests: XCTestCase {
    @MainActor
    func testIndependentSettingsPersistAndInvalidStoredCodexFableFallsBack() throws {
        let name = "TKMYQuotaSelection.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.codexQuotaWindow, .weekly)
        settings.codexQuotaWindow = .shortTerm
        settings.claudeQuotaWindow = .fable
        let restored = AppSettings(defaults: defaults)
        XCTAssertEqual(restored.codexQuotaWindow, .shortTerm)
        XCTAssertEqual(restored.claudeQuotaWindow, .fable)
        defaults.set("fable", forKey: "codexQuotaWindow")
        XCTAssertEqual(AppSettings(defaults: defaults).codexQuotaWindow, .weekly)
    }

    @MainActor
    func testSelectionDoesNotSubstituteMissingExpiredOrOtherServiceWindows() {
        let now = Date()
        let samples = [sample(.codex, 300, 15, now), sample(.codex, 10080, 41, now),
                       sample(.claudeCode, 10080, 82, now, fable: true)]
        XCTAssertEqual(AppSettings.QuotaWindow.shortTerm.selectedLimit(in: samples, source: .codex, now: now)?.usedPercent, 15)
        XCTAssertEqual(AppSettings.QuotaWindow.weekly.selectedLimit(in: samples, source: .codex, now: now)?.usedPercent, 41)
        XCTAssertNil(AppSettings.QuotaWindow.weekly.selectedLimit(in: samples, source: .claudeCode, now: now))
        XCTAssertNil(AppSettings.QuotaWindow.fable.selectedLimit(in: samples, source: .codex, now: now))
        XCTAssertNil(AppSettings.QuotaWindow.shortTerm.selectedLimit(in: samples, source: .codex, now: now.addingTimeInterval(120)))
    }

    @MainActor
    func testNativeButtonChangesSelectedWindowClearsOnUnavailableAndExpires() throws {
        _ = NSApplication.shared
        let name = "TKMYQuotaButton.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        let model = SourceUsageViewModel(source: .claudeCode)
        let controller = StatusItemController(viewModel: model, updateController: UpdateController(), settings: settings,
            openSettings: { _ in }, statusItemsDidChange: {}, closeOtherPopovers: { _ in })
        defer { controller.close() }
        let button = try XCTUnwrap(controller.statusItem.button)
        let now = Date()
        let samples = [sample(.claudeCode, 300, 20, now), sample(.claudeCode, 10080, 40, now),
                       sample(.claudeCode, 10080, 70, now, fable: true)]
        let snapshot = SourceUsageSnapshot(source: .claudeCode, dailyUsage: [], currentUsageLimits: samples)
        model.apply(.ready(snapshot))
        flush()
        XCTAssertTrue(button.title.contains("60%"), button.title)
        settings.claudeQuotaWindow = .shortTerm
        flush()
        XCTAssertTrue(button.title.contains("80%"), button.title)
        settings.claudeQuotaWindow = .fable
        flush()
        XCTAssertTrue(button.title.contains("30%"), button.title)
        XCTAssertTrue(button.toolTip?.contains("Fable") == true)
        // Missing current data cannot be replaced by stored history or another account.
        model.apply(.ready(SourceUsageSnapshot(source: .claudeCode, dailyUsage: [], usageLimitHistory: samples)))
        flush()
        XCTAssertTrue(button.title.contains("—"), button.title)
        let expired = UsageLimitSnapshot(source: .claudeCode, limitID: "claude-code-fable", usedPercent: 100,
            windowMinutes: 10080, resetsAt: Date().addingTimeInterval(0.2), observedAt: now)
        model.apply(.ready(SourceUsageSnapshot(source: .claudeCode, dailyUsage: [], currentUsageLimits: [expired])))
        flush()
        XCTAssertTrue(button.title.contains("0%"))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(button.title.contains("—"), button.title)
        model.apply(.ready(snapshot))
        model.setUnavailable()
        flush()
        XCTAssertTrue(button.title.contains("—"), button.title)
    }

    @MainActor
    func testSettingsAndFableHistoryRenderOffscreen() throws {
        _ = NSApplication.shared
        let name = "TKMYQuotaSettingsQA.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.codexQuotaWindow = .shortTerm
        settings.claudeQuotaWindow = .fable
        let settingsView = SettingsView(settings: settings, updateController: UpdateController())
        try capture(NSHostingView(rootView: settingsView), name: "quota-window-settings", width: 520, height: 520)
        let account = QuotaAccount(source: .claudeCode, email: "synthetic@example.com")
        let now = Date()
        let samples = [sample(.claudeCode, 300, 20, now), sample(.claudeCode, 10080, 40, now), sample(.claudeCode, 10080, 70, now, fable: true)].map(account.assigning)
        let model = SourceUsageViewModel(source: .claudeCode)
        model.apply(.ready(SourceUsageSnapshot(source: .claudeCode, dailyUsage: [], currentUsageLimits: samples,
            usageLimitHistory: samples, quotaAccounts: [account], activeQuotaAccountID: account.id)))
        let view = SourceUsagePopoverView(viewModel: model, expectedSource: .claudeCode, initialPane: .quotaHistory)
        try capture(NSHostingView(rootView: view), name: "quota-fable-history", width: SourceUsagePopoverSizing.width, height: SourceUsagePopoverSizing.contentHeight(for: []))
    }

    @MainActor private func flush() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    private func sample(_ source: UsageSource, _ minutes: Int, _ used: Double, _ now: Date, fable: Bool = false) -> UsageLimitSnapshot {
        UsageLimitSnapshot(source: source, limitID: fable ? "claude-code-fable" : (source == .codex ? "codex" : "claude-code"), usedPercent: used,
            windowMinutes: minutes, resetsAt: now.addingTimeInterval(60), observedAt: now)
    }
    @MainActor private func capture<V: View>(_ host: NSHostingView<V>, name: String, width: CGFloat, height: CGFloat) throws {
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.appearance = NSAppearance(named: .aqua)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/ui-snapshots")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(name + ".png"))
    }
}
