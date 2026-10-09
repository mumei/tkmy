import AppKit
import Foundation
import SwiftUI
import Testing
import UsageDomain
@testable import UsageUI

@MainActor
@Test(arguments: [UsageSource.codex, .claudeCode])
func quotaOverlayKeepsWindowsAndAccountsInSeparateSeries(source: UsageSource) throws {
    let now = Date()
    let a = QuotaAccount(source: source, email: "a@example.com")
    let b = QuotaAccount(source: source, email: "b@example.com")
    let history = [a, b].flatMap { account in
        [300, 10_080].flatMap { minutes in
            [20, 10].map { ago in
                UsageLimitSnapshot(source: source, limitID: account.limitID, usedPercent: Double(40 - ago), windowMinutes: minutes, resetsAt: now.addingTimeInterval(7200), observedAt: now.addingTimeInterval(-Double(ago) * 60))
            }
        }
    }
    let series = UsageLimitHistoryChart.series(observations: history, range: .oneHour, now: now, extendLatest: false)
    #expect(series.count == 4)
    for (_, values) in series {
        #expect(values.observations.count == 2)
        #expect(values.strokes.count == 1)
        #expect(!values.strokes.contains { $0.style == .extended })
    }
    #expect(UsageLimitHistoryChart.color(for: UsageLimitHistoryBucket(limitID: a.limitID, windowMinutes: 300)) != UsageLimitHistoryChart.color(for: UsageLimitHistoryBucket(limitID: a.limitID, windowMinutes: 10_080)))
    let currentSeries = UsageLimitHistoryChart.series(observations: history, range: .oneHour, now: now, extendLatest: true)
    #expect(currentSeries.allSatisfy { $0.1.strokes.contains { $0.style == .extended } })
}

@MainActor
@Test(arguments: [UsageSource.codex, .claudeCode])
func accountSelectionSurvivesRefreshAndDoesNotCrossSources(source: UsageSource) {
    let a = QuotaAccount(source: source, email: "a@example.com")
    let b = QuotaAccount(source: source, email: "b@example.com")
    let other = QuotaAccount(source: source == .codex ? .claudeCode : .codex, email: "other@example.com")
    let model = SourceUsageViewModel(source: source)
    let initial = SourceUsageSnapshot(source: source, dailyUsage: [], quotaAccounts: [a, b, other], activeQuotaAccountID: a.id)
    model.apply(.ready(initial))
    #expect(model.selectedQuotaAccountID == a.id)
    #expect(model.quotaAccounts == [a, b])
    model.selectedQuotaAccountID = b.id
    model.selectedQuotaHistoryRange = .twelveHours
    model.setLoading()
    model.apply(.partialFailure(snapshot: initial, unreadableFileCount: 1))
    #expect(model.selectedQuotaAccountID == b.id)
    #expect(model.activeQuotaAccountID == a.id)
    #expect(model.selectedQuotaHistoryRange == .twelveHours)
}

@MainActor
@Test("Account quota overlay renders current and historical accounts", arguments: [UsageSource.codex, .claudeCode])
func quotaOverlayAccountScreenshots(source: UsageSource) throws {
    _ = NSApplication.shared
    let now = Date()
    let current = QuotaAccount(source: source, email: "current@example.com", organizationID: source == .claudeCode ? "org-team" : nil, organizationName: source == .claudeCode ? "Team" : nil, subscriptionType: "team")
    let previous = QuotaAccount(source: source, email: "previous@example.com", subscriptionType: "pro")
    var history: [UsageLimitSnapshot] = []
    for account in [current, previous] {
        for minutes in [300, 10_080] {
            for index in 0..<20 {
                let percent = Double(index) + (minutes == 300 ? 30.0 : 10.0)
                let reset = now.addingTimeInterval(Double(minutes) * 60)
                let observed = now.addingTimeInterval(-Double(20 - index) * 300)
                history.append(UsageLimitSnapshot(source: source, limitID: account.limitID, usedPercent: percent, windowMinutes: minutes, resetsAt: reset, observedAt: observed))
            }
        }
    }
    let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/ui-snapshots")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for selected in [current, previous] {
        let model = SourceUsageViewModel(source: source)
        model.apply(.ready(SourceUsageSnapshot(source: source, dailyUsage: [], usageLimitHistory: history, quotaAccounts: [current, previous], activeQuotaAccountID: current.id)))
        model.selectedQuotaAccountID = selected.id
        model.selectedQuotaHistoryRange = .sixHours
        let view = SourceUsagePopoverView(viewModel: model, expectedSource: source, initialPane: .quotaHistory)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: SourceUsagePopoverSizing.width, height: SourceUsagePopoverSizing.contentHeight(for: []))
        host.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: folder.appendingPathComponent("overlay-\(source.rawValue)-\(selected.id == current.id ? "current" : "historical").png"))
    }
}
