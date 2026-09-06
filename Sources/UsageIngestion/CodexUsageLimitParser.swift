import Foundation
import UsageDomain

/// Streaming parser for Codex quota observations. It deliberately emits no
/// token events; callers can use it for bounded historical backfills.
public final class CodexUsageLimitParser: @unchecked Sendable {
    private let now: Date
    private var buffer = JSONLUsageStreamBuffer()

    public init(now: Date = Date(), startsInsideLine: Bool = false) {
        self.now = now
        self.buffer = JSONLUsageStreamBuffer(discardingOversizedLine: startsInsideLine)
    }

    public func consume(_ data: Data, isFinal: Bool) -> UsageParseResult {
        buffer.consume(data, isFinal: isFinal, transform: { _ in nil }, limitTransform: {
            CodexAdapter.limitSnapshots(from: $0, now: self.now)
        }, maxPendingLineBytes: 1_048_576)
    }
}
