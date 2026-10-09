import Darwin
import Foundation
import UsageDomain

public enum ClaudeAccountRateLimitResult: Sendable, Equatable {
    case available([UsageLimitSnapshot])
    case identified(QuotaAccount, [UsageLimitSnapshot])
    case unavailable
    case failed
}

/// Uses the official Agent SDK's experimental get_usage control request.
/// Claude Code owns authentication. No prompts, credentials, or transcripts are
/// read by this provider; unsupported CLIs fail closed to an unknown quota.
public struct ClaudeAccountRateLimitProvider: Sendable {
    private let executableURL: URL?
    private let environment: [String: String]
    private let timeout: TimeInterval

    public init(
        executableURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = 10
    ) {
        self.environment = environment
        self.executableURL = executableURL ?? Self.findExecutable(environment: environment)
        self.timeout = timeout.isFinite ? max(1, timeout) : 10
    }

    public func fetch(observedAt: Date = Date()) async -> ClaudeAccountRateLimitResult {
        guard let executableURL else { return .unavailable }
        return await Task.detached(priority: .utility) {
            guard let before = Self.readIdentity(executableURL: executableURL, environment: environment, timeout: timeout) else { return .unavailable }
            let result = Self.fetchSynchronously(executableURL: executableURL, environment: environment, timeout: timeout, observedAt: observedAt)
            guard let after = Self.readIdentity(executableURL: executableURL, environment: environment, timeout: timeout), before.id == after.id else { return .unavailable }
            if case let .available(samples) = result { return .identified(after, samples.map(after.assigning)) }
            return result
        }.value
    }

    public func identity() async -> QuotaAccount? {
        guard let executableURL else { return nil }
        return await Task.detached(priority: .utility) {
            Self.readIdentity(executableURL: executableURL, environment: environment, timeout: timeout)
        }.value
    }

    static func account(from data: Data) -> QuotaAccount? {
        guard let value = IngestionSupport.jsonObject(data),
              let loggedIn = value["loggedIn"] as? NSNumber,
              CFGetTypeID(loggedIn) == CFBooleanGetTypeID(), loggedIn.boolValue,
              value["authMethod"] as? String == "claude.ai",
              let email = value["email"] as? String, !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        if let provider = value["apiProvider"], provider as? String != "firstParty" { return nil }
        if let orgID = value["orgId"] as? String, nonempty(orgID) == nil { return nil }
        // Missing/null organization fields are valid for personal subscriptions.
        // Wrong types must never collapse an organization into a personal account.
        for key in ["orgId", "orgName", "subscriptionType"] {
            if let field = value[key], !(field is NSNull), !(field is String) { return nil }
        }
        return QuotaAccount(source: .claudeCode, email: email,
                            organizationID: nonempty(value["orgId"] as? String),
                            organizationName: nonempty(value["orgName"] as? String),
                            subscriptionType: nonempty(value["subscriptionType"] as? String))
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func readIdentity(executableURL: URL, environment: [String: String], timeout: TimeInterval) -> QuotaAccount? {
        guard let data = ReadOnlyCommand.capture(executableURL: executableURL, arguments: ["auth", "status"], environment: environment, timeout: timeout) else { return nil }
        return account(from: data)
    }

    static func result(from responseData: Data, observedAt: Date) -> ClaudeAccountRateLimitResult {
        guard let object = IngestionSupport.jsonObject(responseData),
              object["type"] as? String == "control_response",
              let envelope = object["response"] as? [String: Any],
              envelope["request_id"] as? String == "tkmy-usage",
              envelope["subtype"] as? String == "success",
              let response = envelope["response"] as? [String: Any],
              let available = response["rate_limits_available"] as? NSNumber,
              CFGetTypeID(available) == CFBooleanGetTypeID()
        else { return .failed }
        guard available.boolValue else { return .unavailable }
        guard let limits = response["rate_limits"] as? [String: Any] else { return .failed }
        // Model-specific buckets and extra spend are not the general allowance.
        let windows: [(String, Int)] = [("five_hour", 300), ("seven_day", 10_080)]
        let snapshots = windows.compactMap { key, minutes -> UsageLimitSnapshot? in
            guard let window = limits[key] as? [String: Any],
                  let number = window["utilization"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, (0...100).contains(number.doubleValue),
                  let resetString = window["resets_at"] as? String,
                  let reset = IngestionSupport.date(resetString),
                  reset > observedAt,
                  Int64(exactly: (reset.timeIntervalSince1970 * 1_000).rounded()) != nil
            else { return nil }
            return UsageLimitSnapshot(
                source: .claudeCode, limitID: "claude-code",
                usedPercent: number.doubleValue, windowMinutes: minutes,
                resetsAt: reset, observedAt: observedAt
            )
        }
        return snapshots.isEmpty ? .failed : .available(snapshots)
    }

    private static func fetchSynchronously(
        executableURL: URL, environment: [String: String],
        timeout: TimeInterval, observedAt: Date
    ) -> ClaudeAccountRateLimitResult {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tkmy-quota-" + UUID().uuidString)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { return .failed }
        defer { try? FileManager.default.removeItem(at: directory) }

        // Pin the oldest contract actually reviewed. Earlier experimental
        // implementations may ignore skip_behaviors and scan local transcripts.
        guard let version = cliVersion(executableURL: executableURL, environment: environment, directory: directory, timeout: timeout)
        else { return .failed }
        guard supportsUsageRequest(version) else { return .unavailable }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let collector = ClaudeQuotaControlResponses()
        process.executableURL = executableURL
        process.currentDirectoryURL = directory
        process.arguments = [
            "--print", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--no-session-persistence", "--setting-sources=", "--tools", "",
            "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
            "--settings", "{\"disableAllHooks\":true}",
        ]
        var childEnvironment = environment
        childEnvironment["DISABLE_AUTOUPDATER"] = "1"
        process.environment = childEnvironment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { collector.finish() } else { collector.append(data) }
        }
        process.terminationHandler = { _ in collector.finish() }
        defer {
            try? input.fileHandleForWriting.close()
            output.fileHandleForReading.readabilityHandler = nil
            if process.isRunning {
                process.terminate()
                let deadline = Date().addingTimeInterval(1)
                while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            }
            if process.processIdentifier > 0 { process.waitUntilExit() }
        }

        do {
            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            try input.fileHandleForWriting.write(contentsOf: request(id: "tkmy-init", body: ["subtype": "initialize", "hooks": [:]]))
            guard let initialized = collector.wait(for: "tkmy-init", until: deadline),
                  let object = IngestionSupport.jsonObject(initialized),
                  let response = object["response"] as? [String: Any],
                  response["subtype"] as? String == "success" else { return .failed }
            try input.fileHandleForWriting.write(contentsOf: request(
                id: "tkmy-usage", body: ["subtype": "get_usage", "skip_behaviors": true]
            ))
            guard let response = collector.wait(for: "tkmy-usage", until: deadline) else { return .failed }
            return result(from: response, observedAt: observedAt)
        } catch { return .failed }
    }

    private static func request(id: String, body: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: ["type": "control_request", "request_id": id, "request": body])
        data.append(0x0A)
        return data
    }

    static func supportsUsageRequest(_ version: String) -> Bool {
        let components = version.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").first?
            .split(separator: ".") ?? []
        guard components.count == 3 else { return false }
        let parts = components.compactMap { Int($0) }
        guard parts.count == 3 else { return false }
        return !parts.lexicographicallyPrecedes([2, 1, 289])
    }

    private static func cliVersion(
        executableURL: URL, environment: [String: String], directory: URL, timeout: TimeInterval
    ) -> String? {
        let process = Process()
        let output = Pipe()
        let collector = ClaudeQuotaVersionOutput()
        process.executableURL = executableURL
        process.currentDirectoryURL = directory
        process.arguments = ["--version"]
        var childEnvironment = environment
        childEnvironment["DISABLE_AUTOUPDATER"] = "1"
        process.environment = childEnvironment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { handle in collector.append(handle.availableData) }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            if process.isRunning {
                process.terminate()
                let deadline = Date().addingTimeInterval(1)
                while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            }
            if process.processIdentifier > 0 { process.waitUntilExit() }
        }
        do { try process.run() } catch { return nil }
        return collector.wait(timeout: min(3, timeout))
    }

    static func findExecutable(environment: [String: String]) -> URL? {
        var candidates: [String] = []
        if let override = environment["TKMY_CLAUDE_EXECUTABLE"], !override.isEmpty { candidates.append(override) }
        if let path = environment["PATH"] { candidates += path.split(separator: ":").map { "\($0)/claude" } }
        let home = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        candidates += ["\(home)/.local/bin/claude", "\(home)/.bun/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
}

private final class ClaudeQuotaVersionOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var data = Data()

    func append(_ chunk: Data) {
        let done = lock.withLock {
            guard data.count < 16_384 else { return true }
            data.append(chunk.prefix(16_384 - data.count))
            return chunk.isEmpty || data.contains(0x0A) || data.count == 16_384
        }
        if done { semaphore.signal() }
    }

    func wait(timeout: TimeInterval) -> String? {
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        return lock.withLock { String(data: data, encoding: .utf8) }
    }
}

private final class ClaudeQuotaControlResponses: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var remainder = Data()
    private var responses: [String: Data] = [:]
    private var receivedBytes = 0
    private var finished = false

    func append(_ data: Data) {
        lock.withLock {
            guard !finished else { return }
            receivedBytes += data.count
            guard receivedBytes <= 1_048_576 else { finished = true; return }
            remainder.append(data)
            while let newline = remainder.firstIndex(of: 0x0A) {
                let line = Data(remainder[..<newline])
                remainder.removeSubrange(...newline)
                guard let object = IngestionSupport.jsonObject(line),
                      object["type"] as? String == "control_response",
                      let envelope = object["response"] as? [String: Any],
                      let id = envelope["request_id"] as? String,
                      id == "tkmy-init" || id == "tkmy-usage" else { continue }
                responses[id] = line
            }
        }
        semaphore.signal()
    }

    func finish() {
        lock.withLock { finished = true }
        semaphore.signal()
    }

    func wait(for id: String, until deadline: Date) -> Data? {
        while true {
            let state = lock.withLock { (responses[id], finished) }
            if let response = state.0 { return response }
            guard !state.1, deadline > Date() else { return nil }
            guard semaphore.wait(timeout: .now() + deadline.timeIntervalSinceNow) == .success else { return nil }
        }
    }
}
