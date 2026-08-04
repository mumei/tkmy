import Foundation
import UsageDomain

public struct ClaudeCodeAdapter: UsageSourceAdapter {
    public let source: UsageSource = .claudeCode
    private let projectRoots: [URL]

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        var roots: [URL] = []
        if let configured = environment["CLAUDE_CONFIG_DIR"], !configured.isEmpty {
            roots.append(URL(fileURLWithPath: configured).appendingPathComponent("projects", isDirectory: true))
        }
        roots.append(homeDirectory.appendingPathComponent(".claude/projects", isDirectory: true))
        roots.append(homeDirectory.appendingPathComponent(".config/claude/projects", isDirectory: true))
        var seen = Set<String>()
        projectRoots = roots.map(\.standardizedFileURL).filter { seen.insert($0.path).inserted }
    }

    public func discoverLogFiles() throws -> [URL] {
        IngestionSupport.jsonlFiles(under: projectRoots)
    }

    public func parse(_ data: Data, at sourceURL: URL) -> UsageParseResult {
        let parsed = IncrementalJSONLParser.parse(data)
        let pathHash = IngestionSupport.pathHash(sourceURL)
        var events: [NormalizedUsageEvent] = []
        var seen = Set<String>()

        for line in parsed.completeLines {
            guard let object = IngestionSupport.jsonObject(line),
                  (object["type"] as? String) == "assistant",
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let occurredAt = IngestionSupport.date(object["timestamp"] ?? message["timestamp"])
            else { continue }

            let tokens = tokens(from: usage)
            guard tokens.total > 0 || tokens.reasoningOutput > 0 else { continue }
            let sessionID = IngestionSupport.string(object, "sessionId", "session_id")
            let messageID = IngestionSupport.string(message, "id", "message_id")
            let requestID = IngestionSupport.string(object, "requestId", "request_id", "uuid")
            let model = IngestionSupport.string(message, "model")

            // Message/request IDs survive transcript replay across files. When absent,
            // use exact event contents so only byte-semantic duplicates collapse.
            let identity: [String: Any] = [
                "message": messageID ?? "",
                "request": requestID ?? "",
                "session": sessionID ?? "",
                "timestamp": occurredAt.timeIntervalSince1970,
                "tokens": tokenDictionary(tokens),
                "model": model ?? "",
                "sidechain": (object["isSidechain"] as? Bool) ?? false,
            ]
            let eventKey = "claude-code:" + IngestionSupport.stableHash(identity)
            guard seen.insert(eventKey).inserted else { continue }

            events.append(NormalizedUsageEvent(
                eventKey: eventKey,
                source: .claudeCode,
                sessionID: sessionID,
                occurredAt: occurredAt,
                tokens: tokens,
                model: model,
                sourceCostMicrosUSD: costMicros(object),
                originPathHash: pathHash
            ))
        }

        return UsageParseResult(
            events: events,
            consumedByteCount: parsed.consumedByteCount,
            remainder: parsed.remainder,
            malformedLineCount: parsed.malformedLineCount
        )
    }

    private func tokens(from usage: [String: Any]) -> TokenBreakdown {
        let creation = usage["cache_creation"] as? [String: Any] ?? [:]
        let split5m = IngestionSupport.int64(creation, "ephemeral_5m_input_tokens", "ephemeral5mInputTokens")
        let split1h = IngestionSupport.int64(creation, "ephemeral_1h_input_tokens", "ephemeral1hInputTokens")
        let unsplitCreation = IngestionSupport.int64(usage, "cache_creation_input_tokens", "cacheCreationInputTokens")
        return TokenBreakdown(
            input: IngestionSupport.int64(usage, "input_tokens", "inputTokens"),
            cacheCreate5m: split5m > 0 || split1h > 0 ? split5m : unsplitCreation,
            cacheCreate1h: split1h,
            cacheRead: IngestionSupport.int64(usage, "cache_read_input_tokens", "cacheReadInputTokens"),
            output: IngestionSupport.int64(usage, "output_tokens", "outputTokens"),
            reasoningOutput: IngestionSupport.int64(usage, "reasoning_output_tokens", "reasoningOutputTokens")
        )
    }

    private func costMicros(_ object: [String: Any]) -> Int64? {
        let raw = object["costUSD"] ?? object["cost_usd"]
        if let number = raw as? NSNumber { return Int64((number.doubleValue * 1_000_000).rounded()) }
        if let string = raw as? String, let value = Decimal(string: string) {
            var decimal = value * Decimal(1_000_000)
            var rounded = Decimal()
            NSDecimalRound(&rounded, &decimal, 0, .plain)
            return NSDecimalNumber(decimal: rounded).int64Value
        }
        return nil
    }

    private func tokenDictionary(_ value: TokenBreakdown) -> [String: Int64] {
        [
            "input": value.input,
            "cache5m": value.cacheCreate5m,
            "cache1h": value.cacheCreate1h,
            "cacheRead": value.cacheRead,
            "output": value.output,
            "reasoning": value.reasoningOutput,
        ]
    }
}
