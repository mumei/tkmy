import Foundation
import UsageDomain

public struct CodexAdapter: UsageSourceAdapter {
    public let source: UsageSource = .codex
    private let codexHome: URL

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        if let override = environment["CODEX_HOME"], !override.isEmpty {
            codexHome = URL(fileURLWithPath: override).standardizedFileURL
        } else {
            codexHome = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        }
    }

    public func discoverLogFiles() throws -> [URL] {
        let activeRoot = codexHome.appendingPathComponent("sessions", isDirectory: true)
        let archiveRoot = codexHome.appendingPathComponent("archived_sessions", isDirectory: true)
        var selected: [String: URL] = [:]

        for url in IngestionSupport.jsonlFiles(under: [archiveRoot]) {
            selected[relativePath(of: url, below: archiveRoot)] = url
        }
        for url in IngestionSupport.jsonlFiles(under: [activeRoot]) {
            selected[relativePath(of: url, below: activeRoot)] = url
        }
        return selected.values.sorted { $0.path < $1.path }
    }

    public func parse(_ data: Data, at sourceURL: URL) -> UsageParseResult {
        makeStreamParser(at: sourceURL).consume(data, isFinal: false)
    }

    public func makeStreamParser(at sourceURL: URL) -> any UsageStreamParser {
        CodexStreamParser(sourceURL: sourceURL)
    }

    /// Reads the newest Codex-provided account limit snapshot without calling a
    /// private network endpoint. Recent file tails are enough because Codex
    /// records the current limit alongside token-count events.
    public func latestUsageLimit(in files: [URL], maximumFiles: Int = 32) -> UsageLimitSnapshot? {
        let recentFiles = files
            .map { url in
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                let date = values?.contentModificationDate ?? .distantPast
                return (url, date)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(max(1, maximumFiles))

        var latest: UsageLimitSnapshot?
        for (url, _) in recentFiles {
            guard let data = try? tailData(from: url),
                  let candidate = latestUsageLimit(in: data)
            else { continue }
            if latest == nil || candidate.observedAt > latest!.observedAt {
                latest = candidate
            }
        }
        return latest
    }

    public func latestUsageLimit(in data: Data) -> UsageLimitSnapshot? {
        var buffer = data
        if buffer.last != 0x0A { buffer.append(0x0A) }
        let lines = IncrementalJSONLParser.parse(buffer).completeLines
        var latest: UsageLimitSnapshot?

        for line in lines {
            guard let object = IngestionSupport.jsonObject(line),
                  let payload = object["payload"] as? [String: Any],
                  let limits = payload["rate_limits"] as? [String: Any],
                  IngestionSupport.string(limits, "limit_id", "limitId") == "codex",
                  let observedAt = IngestionSupport.date(object["timestamp"] ?? payload["timestamp"]),
                  let window = longestWindow(in: limits)
            else { continue }

            let candidate = UsageLimitSnapshot(
                source: .codex,
                limitID: "codex",
                usedPercent: window.usedPercent,
                windowMinutes: window.minutes,
                resetsAt: window.resetsAt,
                observedAt: observedAt
            )
            if latest == nil || candidate.observedAt > latest!.observedAt {
                latest = candidate
            }
        }
        return latest
    }

    private func relativePath(of url: URL, below root: URL) -> String {
        let rootPath = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : url.lastPathComponent
    }

    private func longestWindow(in limits: [String: Any]) -> (usedPercent: Double, minutes: Int, resetsAt: Date?)? {
        ["primary", "secondary"]
            .compactMap { key -> (usedPercent: Double, minutes: Int, resetsAt: Date?)? in
                guard let value = limits[key] as? [String: Any],
                      let usedPercent = (value["used_percent"] ?? value["usedPercent"]) as? NSNumber,
                      let minutes = (value["window_minutes"] ?? value["windowMinutes"]) as? NSNumber
                else { return nil }
                let resetValue = value["resets_at"] ?? value["resetsAt"]
                return (
                    usedPercent.doubleValue,
                    minutes.intValue,
                    IngestionSupport.date(resetValue)
                )
            }
            .max { $0.minutes < $1.minutes }
    }

    private func tailData(from url: URL, maximumBytes: UInt64 = 1_048_576) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let start = size > maximumBytes ? size - maximumBytes : 0
        try handle.seek(toOffset: start)
        var data = try handle.readToEnd() ?? Data()

        if start > 0, let firstNewline = data.firstIndex(of: 0x0A) {
            data = Data(data[data.index(after: firstNewline)...])
        }
        return data
    }

    fileprivate static func tokens(from value: [String: Any]) -> TokenBreakdown {
        let input = IngestionSupport.int64(value, "input_tokens", "inputTokens")
        let cached = IngestionSupport.int64(value, "cached_input_tokens", "cachedInputTokens", "cache_read_input_tokens")
        return TokenBreakdown(
            input: max(0, input - cached),
            cacheRead: cached,
            output: IngestionSupport.int64(value, "output_tokens", "outputTokens"),
            reasoningOutput: IngestionSupport.int64(value, "reasoning_output_tokens", "reasoningOutputTokens")
        )
    }

    fileprivate static func subtract(_ current: TokenBreakdown, _ previous: TokenBreakdown?) -> TokenBreakdown {
        guard let previous else { return current }
        if current.input < previous.input || current.cacheRead < previous.cacheRead || current.output < previous.output {
            return current
        }
        return TokenBreakdown(
            input: max(0, current.input - previous.input),
            cacheCreate5m: max(0, current.cacheCreate5m - previous.cacheCreate5m),
            cacheCreate1h: max(0, current.cacheCreate1h - previous.cacheCreate1h),
            cacheRead: max(0, current.cacheRead - previous.cacheRead),
            output: max(0, current.output - previous.output),
            reasoningOutput: max(0, current.reasoningOutput - previous.reasoningOutput)
        )
    }

    fileprivate static func tokenDictionary(_ value: TokenBreakdown) -> [String: Int64] {
        ["input": value.input, "cacheRead": value.cacheRead, "output": value.output, "reasoning": value.reasoningOutput]
    }
}

private final class CodexStreamParser: UsageStreamParser {
    private let pathHash: String
    private var sessionID: String?
    private var model: String?
    private var previousTotal: TokenBreakdown?
    private var buffer = JSONLUsageStreamBuffer()

    init(sourceURL: URL) {
        pathHash = IngestionSupport.pathHash(sourceURL)
        sessionID = sourceURL.deletingPathExtension().lastPathComponent
    }

    func consume(_ data: Data, isFinal: Bool) -> UsageParseResult {
        buffer.consume(data, isFinal: isFinal) { [weak self] object in
            self?.event(from: object)
        }
    }

    private func event(from object: [String: Any]) -> NormalizedUsageEvent? {
        guard let payload = object["payload"] as? [String: Any] else { return nil }
        let outerType = object["type"] as? String
        let payloadType = payload["type"] as? String
        if outerType == "session_meta" || payloadType == "session_meta" {
            sessionID = IngestionSupport.string(payload, "id", "session_id", "sessionId") ?? sessionID
        }
        model = IngestionSupport.string(payload, "model", "model_name", "modelName") ?? model
        if let info = payload["info"] as? [String: Any] {
            model = IngestionSupport.string(info, "model", "model_name", "modelName") ?? model
        }

        guard outerType == "event_msg", payloadType == "token_count",
              let info = payload["info"] as? [String: Any],
              let occurredAt = IngestionSupport.date(object["timestamp"] ?? payload["timestamp"])
        else { return nil }

        let totalDictionary = (info["total_token_usage"] ?? info["totalTokenUsage"]) as? [String: Any]
        let lastDictionary = (info["last_token_usage"] ?? info["lastTokenUsage"]) as? [String: Any]
        let total = totalDictionary.map(CodexAdapter.tokens(from:))
        let delta: TokenBreakdown
        if let lastDictionary {
            delta = CodexAdapter.tokens(from: lastDictionary)
        } else if let total {
            delta = CodexAdapter.subtract(total, previousTotal)
        } else {
            return nil
        }
        if let total { previousTotal = total }
        guard delta.total > 0 || delta.reasoningOutput > 0 else { return nil }

        let identity: [String: Any] = [
            "session": sessionID ?? "",
            "timestamp": occurredAt.timeIntervalSince1970,
            "tokens": CodexAdapter.tokenDictionary(delta),
            "model": model ?? "",
        ]
        return NormalizedUsageEvent(
            eventKey: "codex:" + IngestionSupport.stableHash(identity),
            source: .codex,
            sessionID: sessionID,
            occurredAt: occurredAt,
            tokens: delta,
            model: model,
            originPathHash: pathHash
        )
    }
}
