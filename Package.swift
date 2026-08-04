// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TKMY",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TKMY", targets: ["TKMYApp"]),
        .library(name: "UsageDomain", targets: ["UsageDomain"]),
        .library(name: "UsagePricing", targets: ["UsagePricing"]),
        .library(name: "UsageIngestion", targets: ["UsageIngestion"]),
        .library(name: "UsageStore", targets: ["UsageStore"]),
        .library(name: "UsageUI", targets: ["UsageUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.5"),
    ],
    targets: [
        .target(name: "UsageDomain"),
        .target(
            name: "UsagePricing",
            dependencies: ["UsageDomain"],
            resources: [.process("Resources")]
        ),
        .target(name: "UsageIngestion", dependencies: ["UsageDomain"]),
        .target(name: "UsageStore", dependencies: ["UsageDomain"]),
        .target(name: "UsageUI", dependencies: ["UsageDomain"]),
        .target(
            name: "UpdateSupport",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")]
        ),
        .executableTarget(
            name: "TKMYApp",
            dependencies: [
                "UsageDomain",
                "UsagePricing",
                "UsageIngestion",
                "UsageStore",
                "UsageUI",
                "UpdateSupport",
            ],
            path: "Sources/MacTokenApp",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .testTarget(name: "UsageDomainTests", dependencies: ["UsageDomain"]),
        .testTarget(name: "UsagePricingTests", dependencies: ["UsagePricing", "UsageDomain"]),
        .testTarget(name: "UsageIngestionTests", dependencies: ["UsageIngestion", "UsageDomain"]),
        .testTarget(name: "UsageStoreTests", dependencies: ["UsageStore", "UsageDomain"]),
        .testTarget(name: "UsageUITests", dependencies: ["UsageUI", "UsageDomain"]),
    ]
)
