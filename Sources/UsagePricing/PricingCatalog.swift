import Foundation

public struct PricingCatalog: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let effectiveDate: String
    public let provenance: [PricingProvenance]
    public let models: [ModelPricing]

    public init(
        schemaVersion: Int,
        effectiveDate: String,
        provenance: [PricingProvenance],
        models: [ModelPricing]
    ) {
        self.schemaVersion = schemaVersion
        self.effectiveDate = effectiveDate
        self.provenance = provenance
        self.models = models
    }

    public static func decode(from data: Data, decoder: JSONDecoder = JSONDecoder()) throws -> PricingCatalog {
        try decoder.decode(PricingCatalog.self, from: data)
    }

    public static func bundled() throws -> PricingCatalog {
        guard let url = packagedCatalogURL
            ?? Bundle.module.url(forResource: "model-pricing", withExtension: "json") else {
            throw PricingCatalogError.bundledCatalogMissing
        }
        return try decode(from: Data(contentsOf: url))
    }

    /// SwiftPM looks for resource bundles beside the executable, while a
    /// packaged macOS app stores them in Contents/Resources. Check the app's
    /// standard resource directory before falling back to SwiftPM's accessor.
    private static var packagedCatalogURL: URL? {
        packagedCatalogURL(in: Bundle.main.resourceURL)
    }

    static func packagedCatalogURL(in resources: URL?) -> URL? {
        guard let resources else { return nil }
        let url = resources
            .appendingPathComponent("TKMY_UsagePricing.bundle", isDirectory: true)
            .appendingPathComponent("model-pricing.json", isDirectory: false)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func validated() throws -> PricingCatalog {
        guard schemaVersion == 1 else {
            throw PricingCatalogError.unsupportedSchemaVersion(schemaVersion)
        }

        var names = Set<String>()
        for model in models {
            guard !model.canonicalName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PricingCatalogError.emptyModelName
            }
            for rate in model.rates.allRates where rate < 0 {
                throw PricingCatalogError.negativeRate(model.canonicalName)
            }
            for name in [model.canonicalName] + model.aliases {
                let normalized = Self.normalize(name)
                guard !normalized.isEmpty else { throw PricingCatalogError.emptyAlias(model.canonicalName) }
                guard names.insert(normalized).inserted else {
                    throw PricingCatalogError.duplicateModelOrAlias(name)
                }
            }
        }
        return self
    }

    public func pricing(for modelName: String) -> ModelPricing? {
        let requested = Self.normalize(modelName)
        let requestedWithoutSnapshot = Self.removingSnapshotDate(from: requested)
        return models.first { model in
            let names = [model.canonicalName] + model.aliases
            return names.contains {
                let candidate = Self.normalize($0)
                return candidate == requested || Self.removingSnapshotDate(from: candidate) == requestedWithoutSnapshot
            }
        }
    }

    static func normalize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func removingSnapshotDate(from name: String) -> String {
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) {
            return parts.dropLast().joined(separator: "-")
        }
        if parts.count >= 4 {
            let tail = parts.suffix(3)
            if tail[tail.startIndex].count == 4,
               tail[tail.index(after: tail.startIndex)].count == 2,
               tail[tail.index(tail.startIndex, offsetBy: 2)].count == 2,
               tail.joined().allSatisfy(\.isNumber) {
                return parts.dropLast(3).joined(separator: "-")
            }
        }
        return name
    }
}

public struct PricingProvenance: Codable, Equatable, Sendable {
    public let provider: String
    public let url: String
    public let retrievedAt: String
    public let note: String

    public init(provider: String, url: String, retrievedAt: String, note: String) {
        self.provider = provider
        self.url = url
        self.retrievedAt = retrievedAt
        self.note = note
    }
}

public struct ModelPricing: Codable, Equatable, Sendable {
    public let canonicalName: String
    public let aliases: [String]
    public let rates: TokenRates

    public init(canonicalName: String, aliases: [String] = [], rates: TokenRates) {
        self.canonicalName = canonicalName
        self.aliases = aliases
        self.rates = rates
    }
}

/// Rates are integer micro-USD per one million tokens.
/// This representation keeps the catalog lossless for prices expressed in USD / 1M tokens.
public struct TokenRates: Codable, Equatable, Sendable {
    public let input: Int64
    public let output: Int64
    public let cacheCreate5m: Int64
    public let cacheCreate1h: Int64
    public let cacheRead: Int64

    public init(
        input: Int64,
        output: Int64,
        cacheCreate5m: Int64,
        cacheCreate1h: Int64,
        cacheRead: Int64
    ) {
        self.input = input
        self.output = output
        self.cacheCreate5m = cacheCreate5m
        self.cacheCreate1h = cacheCreate1h
        self.cacheRead = cacheRead
    }

    var allRates: [Int64] { [input, output, cacheCreate5m, cacheCreate1h, cacheRead] }
}

public enum PricingCatalogError: Error, Equatable {
    case bundledCatalogMissing
    case unsupportedSchemaVersion(Int)
    case emptyModelName
    case emptyAlias(String)
    case duplicateModelOrAlias(String)
    case negativeRate(String)
}
