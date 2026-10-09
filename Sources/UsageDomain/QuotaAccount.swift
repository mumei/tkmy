import CryptoKit
import Foundation

/// Only display/identity fields, never credentials or raw authentication payloads.
public struct QuotaAccount: Codable, Hashable, Identifiable, Sendable {
    public let source: UsageSource
    public let email: String
    public let organizationID: String?
    public let organizationName: String?
    public let subscriptionType: String?

    public init(source: UsageSource, email: String, organizationID: String? = nil,
                organizationName: String? = nil, subscriptionType: String? = nil) {
        self.source = source
        self.email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        self.organizationID = organizationID
        self.organizationName = organizationName
        self.subscriptionType = subscriptionType
    }

    public var id: String {
        // Length-prefix UTF-8 fields so delimiters in names cannot collide.
        let identity = [source.rawValue, email, organizationID ?? ""].map {
            "\($0.utf8.count):\($0)"
        }.joined()
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public var limitID: String { (source == .codex ? "codex" : "claude-code") + "@" + id }
    public var displayName: String {
        [email, organizationName ?? organizationID, subscriptionType].compactMap { $0 }.joined(separator: " · ")
    }
    public func assigning(_ sample: UsageLimitSnapshot) -> UsageLimitSnapshot {
        UsageLimitSnapshot(source: source, limitID: limitID, usedPercent: sample.usedPercent,
                           windowMinutes: sample.windowMinutes, resetsAt: sample.resetsAt,
                           observedAt: sample.observedAt, lastObservedAt: sample.lastObservedAt,
                           resetEpochID: sample.resetEpochID)
    }
}

public extension UsageLimitSnapshot {
    var quotaAccountID: String? {
        let prefix = source == .codex ? "codex@" : "claude-code@"
        guard limitID.hasPrefix(prefix) else { return nil }
        return String(limitID.dropFirst(prefix.count))
    }
}
