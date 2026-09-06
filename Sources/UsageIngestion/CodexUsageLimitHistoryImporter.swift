import Foundation
import UsageDomain
import UsageStore

/// Backfills quota observations independently of the token-event cursor. Work
/// is bounded per refresh, and completed files are not read again until changed.
public actor CodexUsageLimitHistoryImporter {
    public struct Progress: Equatable, Sendable {
        public var bytesRead = 0
        public var filesExamined = 0
        public var unreadableFiles = 0
    }

    private static let parserVersion = 1
    private let store: SQLiteUsageStore
    private let byteBudget: Int
    private let fileBudget: Int
    private var nextFile: URL?
    private var active: ActiveRead?

    public init(store: SQLiteUsageStore, byteBudget: Int = 4 * 1_048_576, fileBudget: Int = 16) {
        self.store = store
        self.byteBudget = max(1, byteBudget)
        self.fileBudget = max(1, fileBudget)
    }

    public func refresh(files: [URL], now: Date) async throws -> Progress {
        try await store.pruneUsageLimitHistory(now: now)
        var progress = Progress()
        // Discovery is shared with token ingestion. Newest path dates are visited
        // first, then a rotating position prevents large histories from starving.
        let ordered = files.sorted { $0.path > $1.path }
        var index = nextFile.flatMap { ordered.firstIndex(of: $0) } ?? 0
        let candidateBudget = min(fileBudget, ordered.count)

        while progress.bytesRead < byteBudget {
            if active == nil {
                guard progress.filesExamined < candidateBudget else { break }
                let file = ordered[index]
                index = (index + 1) % ordered.count
                nextFile = ordered[index]
                progress.filesExamined += 1
                do {
                    active = try await open(file, now: now)
                } catch {
                    progress.unreadableFiles += 1
                }
                if active == nil { continue }
            }
            guard let read = active else { continue }
            do {
                // A replaced/truncated file must never inherit a partial JSONL
                // buffer from its previous contents.
                guard files.contains(read.url), try read.isStillValid() else {
                    active = nil
                    continue
                }
                let handle = try FileHandle(forReadingFrom: read.url)
                defer { try? handle.close() }
                try handle.seek(toOffset: read.readOffset)
                let count = min(byteBudget - progress.bytesRead, 262_144, Int(read.size - read.readOffset))
                let chunk = count > 0 ? try handle.read(upToCount: count) ?? Data() : Data()
                read.readOffset += UInt64(chunk.count)
                progress.bytesRead += chunk.count
                let finished = read.readOffset >= read.size || chunk.isEmpty
                let result = read.parser.consume(chunk, isFinal: finished)
                try await store.upsertUsageLimits(result.usageLimits, now: now)
                try await store.saveCursor(
                    FileCursor(
                        inode: read.inode,
                        size: read.size,
                        modifiedAtMilliseconds: read.modifiedAtMilliseconds,
                        byteOffset: read.baseOffset + UInt64(result.consumedByteCount),
                        contentSignature: read.signature + (finished ? ":done" : ""),
                        parserVersion: Self.parserVersion
                    ),
                    source: .codex,
                    pathHash: read.pathHash
                )
                if finished { active = nil }
            } catch {
                active = nil
                progress.unreadableFiles += 1
                // Move on to the next file rather than retrying forever in one refresh.
            }
        }
        return progress
    }

    private func open(_ url: URL, now: Date) async throws -> ActiveRead? {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let modified = attributes[.modificationDate] as? Date ?? .distantPast
        guard modified >= UsageLimitHistoryPolicy.cutoff(relativeTo: now) else { return nil }
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modifiedMS = Int64((modified.timeIntervalSince1970 * 1_000).rounded())
        let pathHash = "quota:" + UsagePathIdentity.sha256(for: url)
        let signature = try Self.signature(of: url, size: size)
        let cursor = try await store.cursor(for: .codex, pathHash: pathHash)
        var start: UInt64 = 0
        if let cursor,
           cursor.parserVersion == Self.parserVersion,
           cursor.inode == inode,
           size >= cursor.size,
           cursor.byteOffset <= cursor.size {
            let previousSignature = cursor.contentSignature.replacingOccurrences(of: ":done", with: "")
            let samePrefix = try Self.signature(of: url, size: cursor.size) == previousSignature
            if samePrefix {
                if size == cursor.size,
                   modifiedMS == cursor.modifiedAtMilliseconds,
                   cursor.contentSignature.hasSuffix(":done") { return nil }
                start = cursor.byteOffset
            }
        }
        return ActiveRead(
            url: url, pathHash: pathHash, inode: inode, size: size,
            modifiedAtMilliseconds: modifiedMS, signature: signature,
            baseOffset: start,
            parser: CodexUsageLimitParser(now: now, startsInsideLine: try Self.isInsideLine(url, offset: start))
        )
    }

    private static func isInsideLine(_ url: URL, offset: UInt64) throws -> Bool {
        guard offset > 0 else { return false }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset - 1)
        return try handle.read(upToCount: 1)?.first != 0x0A
    }

    private static func signature(of url: URL, size: UInt64) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = try handle.read(upToCount: Int(min(size, 4_096))) ?? Data()
        if size > 4_096 {
            try handle.seek(toOffset: size - 4_096)
            data.append(try handle.read(upToCount: 4_096) ?? Data())
        }
        var encodedSize = size.bigEndian
        data.append(Data(bytes: &encodedSize, count: MemoryLayout<UInt64>.size))
        return UsagePathIdentity.sha256(data: data)
    }

    private final class ActiveRead {
        let url: URL
        let pathHash: String
        let inode: UInt64
        let size: UInt64
        let modifiedAtMilliseconds: Int64
        let signature: String
        let baseOffset: UInt64
        var readOffset: UInt64
        let parser: CodexUsageLimitParser

        init(url: URL, pathHash: String, inode: UInt64, size: UInt64,
             modifiedAtMilliseconds: Int64, signature: String, baseOffset: UInt64,
             parser: CodexUsageLimitParser) {
            self.url = url
            self.pathHash = pathHash
            self.inode = inode
            self.size = size
            self.modifiedAtMilliseconds = modifiedAtMilliseconds
            self.signature = signature
            self.baseOffset = baseOffset
            self.readOffset = baseOffset
            self.parser = parser
        }

        func isStillValid() throws -> Bool {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let currentInode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            let currentSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            guard currentInode == inode, currentSize >= size else { return false }
            return try CodexUsageLimitHistoryImporter.signature(of: url, size: size) == signature
        }
    }
}
