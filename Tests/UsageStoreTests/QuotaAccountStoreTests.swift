import Foundation
import Testing
import UsageDomain
@testable import UsageStore

@Test func quotaAccountsPersistIsolatedHistoriesAndKeepLegacyUnassigned() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("usage.sqlite3")
    let store = try SQLiteUsageStore(databaseURL: url)
    let now = Date()
    let accounts = [
        QuotaAccount(source: .claudeCode, email: "a@example.com"),
        QuotaAccount(source: .claudeCode, email: "a@example.com", organizationID: "org-a", organizationName: "A"),
        QuotaAccount(source: .claudeCode, email: "a@example.com", organizationID: "org-b"),
        QuotaAccount(source: .codex, email: "a@example.com"),
        QuotaAccount(source: .codex, email: "b@example.com"),
    ]
    let legacy = UsageLimitSnapshot(source: .claudeCode, limitID: "claude-code", usedPercent: 25, windowMinutes: 300, resetsAt: now.addingTimeInterval(3600), observedAt: now)
    try await store.upsertUsageLimits([legacy] + accounts.map { $0.assigning(legacy) }, now: now)
    for account in accounts { try await store.saveQuotaAccount(account) }
    let renamed = QuotaAccount(source: .claudeCode, email: "a@example.com", organizationID: "org-a", organizationName: "Renamed")
    try await store.saveQuotaAccount(renamed)
    let reopened = try SQLiteUsageStore(databaseURL: url)
    #expect(try await reopened.quotaAccounts(source: .claudeCode).count == 3)
    #expect(try await reopened.quotaAccounts(source: .codex).count == 2)
    #expect(try await reopened.quotaAccounts(source: .claudeCode).contains(renamed))
    let claudeHistory = try await reopened.usageLimitHistory(source: .claudeCode, from: now.addingTimeInterval(-1), through: now.addingTimeInterval(1))
    #expect(claudeHistory.count == 4)
    #expect(claudeHistory.filter { $0.quotaAccountID == nil }.count == 1)
    #expect(Set(claudeHistory.map(\.limitID)).count == 4)
    try await reopened.deleteHistory()
    #expect(try await reopened.quotaAccounts(source: .claudeCode).isEmpty)
    #expect(try await reopened.quotaAccounts(source: .codex).isEmpty)
}
