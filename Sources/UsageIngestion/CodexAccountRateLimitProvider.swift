import Darwin
import Foundation
import UsageDomain

/// Reads the account-wide Codex quota through the public app-server protocol.
/// Local session logs remain the fallback because older Codex versions may not
/// provide this method or the executable may not be installed.
public struct CodexAccountRateLimitProvider: Sendable {
    private let executableURL: URL?
    private let environment: [String: String]
    private let timeout: TimeInterval

    public init(
        executableURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = 8
    ) {
        self.environment = environment
        self.executableURL = executableURL ?? Self.findExecutable(environment: environment)
        self.timeout = max(1, timeout)
    }

    public func fetch(observedAt: Date = Date()) async -> [UsageLimitSnapshot] {
        guard let executableURL else { return [] }
        return await Task.detached(priority: .utility) {
            Self.fetchSynchronously(
                executableURL: executableURL,
                environment: environment,
                timeout: timeout,
                observedAt: observedAt
            )
        }.value
    }

    static func snapshots(from responseData: Data, observedAt: Date) -> [UsageLimitSnapshot] {
        for line in responseData.split(separator: 0x0A).reversed() {
            guard let object = IngestionSupport.jsonObject(Data(line)),
                  let id = object["id"] as? NSNumber, id.intValue == 2,
                  let result = object["result"] as? [String: Any]
            else { continue }

            if let byID = result["rateLimitsByLimitId"] as? [String: Any],
               let general = byID["codex"] as? [String: Any] {
                return snapshots(from: general, fallbackLimitID: "codex", observedAt: observedAt)
            }
            if let legacy = result["rateLimits"] as? [String: Any] {
                return snapshots(from: legacy, fallbackLimitID: "codex", observedAt: observedAt)
            }
        }
        return []
    }

    public func identity() async -> QuotaAccount? {
        guard let executableURL else { return nil }
        return await Task.detached(priority: .utility) {
            Self.readSession(executableURL: executableURL, environment: environment, timeout: timeout, observedAt: Date(), identityOnly: true)?.0
        }.value
    }

    public func fetchIdentified(observedAt: Date = Date()) async -> (account: QuotaAccount, snapshots: [UsageLimitSnapshot])? {
        guard let executableURL else { return nil }
        return await Task.detached(priority: .utility) {
            guard let result = Self.readSession(executableURL: executableURL, environment: environment, timeout: timeout, observedAt: observedAt, identityOnly: false),
                  let after = Self.readSession(executableURL: executableURL, environment: environment, timeout: timeout, observedAt: observedAt, identityOnly: true)?.0,
                  result.0.id == after.id else { return nil }
            return (account: after, snapshots: result.1.map(after.assigning))
        }.value
    }

    static func account(from data: Data) -> QuotaAccount? {
        guard let object = IngestionSupport.jsonObject(data),
              let result = object["result"] as? [String: Any],
              let account = result["account"] as? [String: Any],
              account["type"] as? String == "chatgpt",
              let email = account["email"] as? String,
              !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        if let plan = account["planType"], !(plan is NSNull), !(plan is String) { return nil }
        // Public account/read exposes email, not a stable workspace/account ID.
        return QuotaAccount(source: .codex, email: email, subscriptionType: account["planType"] as? String)
    }

    private static func fetchSynchronously(executableURL: URL, environment: [String: String], timeout: TimeInterval, observedAt: Date) -> [UsageLimitSnapshot] {
        readSession(executableURL: executableURL, environment: environment, timeout: timeout, observedAt: observedAt, identityOnly: false)?.1 ?? []
    }

    private static func readSession(executableURL: URL, environment: [String: String], timeout: TimeInterval, observedAt: Date, identityOnly: Bool) -> (QuotaAccount, [UsageLimitSnapshot])? {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let collector = CodexRateLimitOutputCollector()
        process.executableURL = executableURL
        process.arguments = ["app-server", "--disable", "plugins", "--disable", "apps", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.environment = environment.merging(["RUST_LOG": "error", "NO_COLOR": "1"]) { _, new in new }
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { collector.finish() } else { collector.append(chunk) }
        }
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
        func send(_ message: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(0x0A)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        do {
            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "tkmy", "title": "TKMY", "version": "1"], "capabilities": [:]]])
            guard let initialized = collector.wait(for: 1, until: deadline),
                  IngestionSupport.jsonObject(initialized)?["error"] == nil else { return nil }
            try send(["method": "initialized"])
            try send(["id": 3, "method": "account/read", "params": ["refreshToken": false]])
            guard let beforeData = collector.wait(for: 3, until: deadline), let before = account(from: beforeData) else { return nil }
            if identityOnly { return (before, []) }
            try send(["id": 2, "method": "account/rateLimits/read", "params": NSNull()])
            guard let quotaData = collector.wait(for: 2, until: deadline) else { return nil }
            try send(["id": 4, "method": "account/read", "params": ["refreshToken": false]])
            guard let afterData = collector.wait(for: 4, until: deadline), let after = account(from: afterData),
                  before.id == after.id, !collector.accountChanged else { return nil }
            return (after, snapshots(from: quotaData, observedAt: observedAt))
        } catch { return nil }
    }

    private static func snapshots(
        from value: [String: Any],
        fallbackLimitID: String,
        observedAt: Date
    ) -> [UsageLimitSnapshot] {
        let limitID = IngestionSupport.string(value, "limitId", "limit_id") ?? fallbackLimitID
        guard limitID.lowercased() == "codex" else { return [] }
        return ["primary", "secondary"].compactMap { key in
            guard let window = value[key] as? [String: Any],
                  let usedPercent = finiteNumber(window["usedPercent"] ?? window["used_percent"]),
                  (0...100).contains(usedPercent),
                  let minutes = positiveWholeInt(
                      window["windowDurationMins"]
                          ?? window["window_duration_mins"]
                          ?? window["windowMinutes"]
                          ?? window["window_minutes"]
                  )
            else { return nil }
            let resetValue = window["resetsAt"] ?? window["resets_at"]
            return UsageLimitSnapshot(
                source: .codex,
                limitID: limitID,
                usedPercent: usedPercent,
                windowMinutes: minutes,
                resetsAt: safeDate(resetValue),
                observedAt: observedAt
            )
        }
    }

    private static func finiteNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite
        else { return nil }
        return number.doubleValue
    }

    private static func positiveWholeInt(_ value: Any?) -> Int? {
        guard let number = finiteNumber(value), number > 0 else { return nil }
        return Int(exactly: number)
    }

    private static func safeDate(_ value: Any?) -> Date? {
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        guard let date = IngestionSupport.date(value),
              date.timeIntervalSinceReferenceDate.isFinite,
              Int64(exactly: (date.timeIntervalSince1970 * 1_000).rounded()) != nil
        else { return nil }
        return date
    }

    private static func findExecutable(environment: [String: String]) -> URL? {
        let fileManager = FileManager.default
        var candidates: [String] = []
        if let override = environment["TKMY_CODEX_EXECUTABLE"], !override.isEmpty {
            candidates.append(override)
        }
        candidates.append("/Applications/Codex.app/Contents/Resources/codex")
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/codex" })
        }
        if let home = environment["HOME"], !home.isEmpty {
            candidates.append("\(home)/.bun/bin/codex")
            candidates.append("\(home)/.local/bin/codex")
        }
        candidates.append("/opt/homebrew/bin/codex")
        candidates.append("/usr/local/bin/codex")

        for path in candidates {
            let expanded = NSString(string: path).expandingTildeInPath
            if fileManager.isExecutableFile(atPath: expanded) {
                return URL(fileURLWithPath: expanded).standardizedFileURL
            }
        }
        return nil
    }
}

private final class CodexRateLimitOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var remainder = Data()
    private var responses: [Int: Data] = [:]
    private var receivedBytes = 0
    private var finished = false
    private var changed = false
    var accountChanged: Bool { lock.withLock { changed } }

    func append(_ data: Data) {
        lock.withLock {
            guard !finished else { return }
            receivedBytes += data.count
            guard receivedBytes <= 1_048_576 else { finished = true; return }
            remainder.append(data)
            while let newline = remainder.firstIndex(of: 0x0A) {
                let line = Data(remainder[..<newline])
                remainder.removeSubrange(...newline)
                guard let object = IngestionSupport.jsonObject(line) else { continue }
                if object["method"] as? String == "account/updated" { changed = true }
                if let id = object["id"] as? Int, (1...4).contains(id) { responses[id] = line }
            }
        }
        semaphore.signal()
    }
    func finish() { lock.withLock { finished = true }; semaphore.signal() }
    func wait(for id: Int, until deadline: Date) -> Data? {
        while true {
            let state = lock.withLock { (responses[id], finished) }
            if let response = state.0 { return response }
            guard !state.1, deadline > Date(),
                  semaphore.wait(timeout: .now() + deadline.timeIntervalSinceNow) == .success else { return nil }
        }
    }
}
