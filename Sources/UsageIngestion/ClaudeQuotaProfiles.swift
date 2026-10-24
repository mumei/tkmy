import Foundation
import UsageDomain

/// Explicit references to existing Claude configuration folders, never credentials.
public struct ClaudeQuotaProfile: Hashable, Identifiable, Sendable {
    public let configDirectory: String?
    public var id: String { configDirectory ?? "system" }
    public init(configDirectory: String? = nil) {
        self.configDirectory = configDirectory
    }
}

public struct ClaudeQuotaProfileConfiguration: Equatable, Sendable {
    public let profiles: [ClaudeQuotaProfile]
    public let selectedProfileID: String
    public init(directories: String = "", selectedProfileID: String = "system") {
        var profiles = [ClaudeQuotaProfile()]
        for line in directories.split(whereSeparator: \.isNewline) {
            let path = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            // No relative paths, shell expansion, credential discovery, or silent truncation.
            guard path.hasPrefix("/") else { continue }
            let profile = ClaudeQuotaProfile(configDirectory: URL(fileURLWithPath: path).standardizedFileURL.path)
            if !profiles.contains(profile) { profiles.append(profile) }
        }
        self.profiles = profiles
        self.selectedProfileID = profiles.contains { $0.id == selectedProfileID } ? selectedProfileID : "system"
    }
}

public struct ClaudeQuotaProfileBatch: Sendable {
    public let accounts: [QuotaAccount]
    public let historySamples: [UsageLimitSnapshot]
    public let selectedAccount: QuotaAccount?
    public let selectedSamples: [UsageLimitSnapshot]
}

/// Each configuration folder has its own identity check, throttle and bounded cache.
public actor ClaudeQuotaProfileReader {
    public typealias IdentityFetch = @Sendable (ClaudeQuotaProfile) async -> QuotaAccount?
    public typealias QuotaFetch = @Sendable (ClaudeQuotaProfile, Date) async -> ClaudeAccountRateLimitResult
    private let identityFetch: IdentityFetch
    private let quotaFetch: QuotaFetch
    private struct Entry {
        var account: QuotaAccount?
        var attemptedAt: Date?
        var succeededAt: Date?
        var samples: [UsageLimitSnapshot] = []
    }
    private var entries: [String: Entry] = [:]

    public init(identityFetch: @escaping IdentityFetch, quotaFetch: @escaping QuotaFetch) {
        self.identityFetch = identityFetch
        self.quotaFetch = quotaFetch
    }

    public func read(_ configuration: ClaudeQuotaProfileConfiguration, now: Date) async -> ClaudeQuotaProfileBatch {
        entries = entries.filter { key, _ in configuration.profiles.contains { $0.id == key } }
        var accounts: [QuotaAccount] = []
        var history: [UsageLimitSnapshot] = []
        var selectedAccount: QuotaAccount?
        var selectedSamples: [UsageLimitSnapshot] = []
        for profile in configuration.profiles {
            let entry = await read(profile, now: now)
            if let account = entry.account { accounts.append(account) }
            history.append(contentsOf: entry.samples)
            if profile.id == configuration.selectedProfileID {
                selectedAccount = entry.account
                selectedSamples = entry.samples
            }
        }
        return ClaudeQuotaProfileBatch(accounts: Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest }).values.sorted { $0.id < $1.id }, historySamples: history,
                                       selectedAccount: selectedAccount, selectedSamples: selectedSamples)
    }

    private func read(_ profile: ClaudeQuotaProfile, now: Date) async -> Entry {
        guard let identity = await identityFetch(profile), identity.source == .claudeCode else {
            entries[profile.id] = nil
            return Entry()
        }
        var entry = entries[profile.id] ?? Entry()
        if entry.account?.id != identity.id { entry = Entry(account: identity) }
        entry.account = identity
        entry.samples = entry.samples.filter { ($0.resetsAt ?? .distantPast) > now }
        if let attempted = entry.attemptedAt, now.timeIntervalSince(attempted) < 60 {
            entries[profile.id] = entry
            return entry
        }
        entry.attemptedAt = now
        let result = await quotaFetch(profile, now)
        guard let after = await identityFetch(profile), after.id == identity.id else {
            entries[profile.id] = nil
            return Entry()
        }
        entry.account = after
        switch result {
        case let .identified(account, samples) where account.id == identity.id:
            entry.samples = samples.filter { sample in
                sample.source == .claudeCode && sample.quotaAccountID == account.id
                    && (sample.limitID == account.limitID || sample.isFableQuota)
                    && [300, 10_080].contains(sample.windowMinutes)
                    && (sample.resetsAt ?? .distantPast) > now
            }
            entry.succeededAt = now
        case let .available(samples):
            // Compatibility for injected synthetic providers; production returns identified.
            entry.samples = samples.filter {
                $0.source == .claudeCode && ["claude-code", "claude-code-fable"].contains($0.limitID)
                    && [300, 10_080].contains($0.windowMinutes) && ($0.resetsAt ?? .distantPast) > now
            }.map(after.assigning)
            entry.succeededAt = now
        case .failed:
            if entry.succeededAt.map({ now.timeIntervalSince($0) > 600 }) ?? true { entry.samples = [] }
        case .unavailable:
            entry.samples = []
            entry.succeededAt = nil
        case .identified:
            entries[profile.id] = nil
            return Entry()
        }
        entries[profile.id] = entry
        return entry
    }
}
