import Foundation
import UsageDomain

public struct UsageParseResult: Sendable, Equatable {
    public let events: [NormalizedUsageEvent]
    public let consumedByteCount: Int
    public let remainder: Data
    public let malformedLineCount: Int

    public init(
        events: [NormalizedUsageEvent],
        consumedByteCount: Int,
        remainder: Data,
        malformedLineCount: Int
    ) {
        self.events = events
        self.consumedByteCount = consumedByteCount
        self.remainder = remainder
        self.malformedLineCount = malformedLineCount
    }
}

public protocol UsageSourceAdapter: Sendable {
    var source: UsageSource { get }
    func discoverLogFiles() throws -> [URL]
    func parse(_ data: Data, at sourceURL: URL) -> UsageParseResult
    func makeStreamParser(at sourceURL: URL) -> any UsageStreamParser
}

/// Stateful parser used when a transcript is too large to load as one `Data` value.
/// Each result only owns the events produced by the supplied chunk.
public protocol UsageStreamParser: AnyObject {
    func consume(_ data: Data, isFinal: Bool) -> UsageParseResult
}

public enum UsagePathIdentity {
    public static func sha256(for url: URL) -> String {
        IngestionSupport.pathHash(url)
    }

    public static func sha256(data: Data) -> String {
        SHA256.hex(data)
    }
}

public struct IncrementalJSONLResult: Sendable, Equatable {
    public let completeLines: [Data]
    public let consumedByteCount: Int
    public let remainder: Data
    public let malformedLineCount: Int
}

/// Splits an append-only JSONL buffer without consuming its unfinished final line.
/// Pass `previousRemainder + newlyReadBytes` on the next invocation.
public enum IncrementalJSONLParser {
    public static func parse(_ buffer: Data) -> IncrementalJSONLResult {
        var completeLines: [Data] = []
        var malformedLineCount = 0
        var lineStart = buffer.startIndex

        for newline in buffer.indices where buffer[newline] == 0x0A {
            var line = buffer[lineStart..<newline]
            if line.last == 0x0D { line = line.dropLast() }
            let data = Data(line)
            if !data.isEmpty {
                if (try? JSONSerialization.jsonObject(with: data)) != nil {
                    completeLines.append(data)
                } else {
                    malformedLineCount += 1
                }
            }
            lineStart = buffer.index(after: newline)
        }

        return IncrementalJSONLResult(
            completeLines: completeLines,
            consumedByteCount: lineStart,
            remainder: Data(buffer[lineStart...]),
            malformedLineCount: malformedLineCount
        )
    }
}

/// Keeps only an unfinished JSONL line between chunks and decodes each complete
/// object once. This bounds ingestion memory independently of transcript size.
struct JSONLUsageStreamBuffer {
    private var pending = Data()
    private var consumedByteCount = 0

    mutating func consume(
        _ data: Data,
        isFinal: Bool,
        transform: ([String: Any]) -> NormalizedUsageEvent?
    ) -> UsageParseResult {
        pending.append(data)
        var events: [NormalizedUsageEvent] = []
        var malformedLineCount = 0
        var lineStart = pending.startIndex

        for newline in pending.indices where pending[newline] == 0x0A {
            var line = pending[lineStart..<newline]
            if line.last == 0x0D { line = line.dropLast() }
            if !line.isEmpty {
                autoreleasepool {
                    let bytes = Data(line)
                    if let object = IngestionSupport.jsonObject(bytes) {
                        if let event = transform(object) { events.append(event) }
                    } else {
                        malformedLineCount += 1
                    }
                }
            }
            lineStart = pending.index(after: newline)
        }

        let consumedNow = pending.distance(from: pending.startIndex, to: lineStart)
        consumedByteCount += consumedNow
        pending = Data(pending[lineStart...])

        // A closed transcript may contain a valid final JSON object without a newline.
        // Keep an invalid tail so a writer can finish it during the next refresh.
        if isFinal, !pending.isEmpty {
            var finalized = false
            autoreleasepool {
                if let object = IngestionSupport.jsonObject(pending) {
                    if let event = transform(object) { events.append(event) }
                    finalized = true
                }
            }
            if finalized {
                consumedByteCount += pending.count
                pending.removeAll(keepingCapacity: false)
            }
        }

        return UsageParseResult(
            events: events,
            consumedByteCount: consumedByteCount,
            remainder: pending,
            malformedLineCount: malformedLineCount
        )
    }
}

enum IngestionSupport {
    static func pathHash(_ url: URL) -> String {
        SHA256.hex(Data(url.standardizedFileURL.path.utf8))
    }

    static func stableHash(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return SHA256.hex(Data(String(describing: object).utf8)) }
        return SHA256.hex(data)
    }

    static func date(_ value: Any?) -> Date? {
        if let seconds = value as? Double { return Date(timeIntervalSince1970: seconds) }
        if let seconds = value as? Int { return Date(timeIntervalSince1970: Double(seconds)) }
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    static func int64(_ dictionary: [String: Any], _ keys: String...) -> Int64 {
        for key in keys {
            if let value = dictionary[key] as? NSNumber { return value.int64Value }
            if let value = dictionary[key] as? String, let parsed = Int64(value) { return parsed }
        }
        return 0
    }

    static func string(_ dictionary: [String: Any], _ keys: String...) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func jsonlFiles(under roots: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "jsonl" {
                let values = try? url.resourceValues(forKeys: Set(keys))
                guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
                let path = url.standardizedFileURL.path
                if seen.insert(path).inserted { result.append(url) }
            }
        }
        return result.sorted { $0.path < $1.path }
    }
}

enum SHA256 {
    private static let constants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func hex(_ data: Data) -> String {
        var bytes = Array(data)
        let bitLength = UInt64(bytes.count) * 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        bytes.append(contentsOf: withUnsafeBytes(of: bitLength.bigEndian, Array.init))
        var state: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]

        for offset in stride(from: 0, to: bytes.count, by: 64) {
            var words = [UInt32](repeating: 0, count: 64)
            for index in 0..<16 {
                let start = offset + index * 4
                words[index] = UInt32(bytes[start]) << 24 | UInt32(bytes[start + 1]) << 16 | UInt32(bytes[start + 2]) << 8 | UInt32(bytes[start + 3])
            }
            for index in 16..<64 {
                let a = words[index - 15]
                let b = words[index - 2]
                let s0 = rotate(a, 7) ^ rotate(a, 18) ^ (a >> 3)
                let s1 = rotate(b, 17) ^ rotate(b, 19) ^ (b >> 10)
                words[index] = words[index - 16] &+ s0 &+ words[index - 7] &+ s1
            }
            var work = state
            for index in 0..<64 {
                let s1 = rotate(work[4], 6) ^ rotate(work[4], 11) ^ rotate(work[4], 25)
                let choice = (work[4] & work[5]) ^ (~work[4] & work[6])
                let temp1 = work[7] &+ s1 &+ choice &+ constants[index] &+ words[index]
                let s0 = rotate(work[0], 2) ^ rotate(work[0], 13) ^ rotate(work[0], 22)
                let majority = (work[0] & work[1]) ^ (work[0] & work[2]) ^ (work[1] & work[2])
                let temp2 = s0 &+ majority
                work = [temp1 &+ temp2, work[0], work[1], work[2], work[3] &+ temp1, work[4], work[5], work[6]]
            }
            for index in 0..<8 { state[index] &+= work[index] }
        }
        return state.map { String(format: "%08x", $0) }.joined()
    }

    private static func rotate(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }
}
