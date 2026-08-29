import AppKit
import Foundation
import SwiftUI
import Testing
import UsageDomain
@testable import UsageUI

@MainActor
@Test("Usage popover renders every supported language without clipping")
func usagePopoverRendersEveryLanguageAndModelRowCount() throws {
    let defaults = UserDefaults.standard
    let previousLanguage = defaults.object(forKey: L10n.defaultsKey)
    defer {
        if let previousLanguage {
            defaults.set(previousLanguage, forKey: L10n.defaultsKey)
        } else {
            defaults.removeObject(forKey: L10n.defaultsKey)
        }
    }

    let snapshotDirectory = try makeSnapshotDirectory()
    for language in AppLanguage.allCases {
        defaults.set(language.rawValue, forKey: L10n.defaultsKey)
        defaults.synchronize()
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        var expectedSelectedDayMinY: CGFloat?
        var expectedSelectedDayHeaderFrame: CGRect?
        var expectedDetailMetricFrames: [CGRect]?

        for modelCount in [0, 4, 5, 8, 9] {
            let rendered = try renderPopover(language: language, modelCount: modelCount)
            let caseName = "\(language.rawValue), \(modelCount) models"
            let expectedRowCount = max(
                1,
                (modelCount + SourceUsagePopoverSizing.modelColumnCount - 1)
                    / SourceUsagePopoverSizing.modelColumnCount
            )

            try rendered.pngData.write(
                to: snapshotDirectory.appendingPathComponent(
                    "codex-\(language.rawValue)-models-\(String(format: "%02d", modelCount)).png"
                ),
                options: .atomic
            )

            if let expectedSelectedDayMinY {
                #expect(
                    abs(rendered.metrics.selectedDayDetailFrame.minY - expectedSelectedDayMinY) <= 0.5,
                    "Selected-day card moved when model rows changed for \(caseName)"
                )
            } else {
                expectedSelectedDayMinY = rendered.metrics.selectedDayDetailFrame.minY
            }
            if let expectedSelectedDayHeaderFrame, let expectedDetailMetricFrames {
                #expect(
                    approximatelyEqual(
                        rendered.metrics.selectedDayHeaderFrame,
                        expectedSelectedDayHeaderFrame
                    ),
                    "Selected-day header changed size or position for \(caseName)"
                )
                #expect(
                    framesAreApproximatelyEqual(
                        rendered.metrics.detailMetricFrames,
                        expectedDetailMetricFrames
                    ),
                    "Fixed detail metrics changed size or position for \(caseName)"
                )
            } else {
                expectedSelectedDayHeaderFrame = rendered.metrics.selectedDayHeaderFrame
                expectedDetailMetricFrames = rendered.metrics.detailMetricFrames
            }
            #expect(
                approximatelyEqual(rendered.metrics.rootFrame.size, rendered.expectedSize),
                "Popover rendered at an unexpected size for \(caseName)"
            )
            #expect(
                approximatelyContains(rendered.metrics.rootFrame, rendered.metrics.selectedDayDetailFrame),
                "Selected-day card escaped the popover for \(caseName)"
            )
            #expect(
                approximatelyContains(
                    rendered.metrics.selectedDayDetailFrame,
                    rendered.metrics.selectedDayHeaderFrame
                ),
                "Selected-day header escaped the card for \(caseName)"
            )
            #expect(
                rendered.metrics.detailMetricFrames.count == 6,
                "Unexpected rendered detail metric count for \(caseName)"
            )
            #expect(
                rendered.metrics.detailMetricFrames.allSatisfy {
                    approximatelyContains(rendered.metrics.selectedDayDetailFrame, $0)
                },
                "A fixed detail metric escaped the card for \(caseName)"
            )
            #expect(
                approximatelyContains(rendered.metrics.rootFrame, rendered.metrics.footerFrame),
                "Footer escaped the popover for \(caseName)"
            )
            #expect(
                approximatelyContains(
                    rendered.metrics.selectedDayDetailFrame,
                    rendered.metrics.modelSectionFrame
                ),
                "Model section escaped the selected-day card for \(caseName)"
            )
            #expect(
                rendered.metrics.modelItemFrames.count == modelCount,
                "Unexpected rendered model count for \(caseName)"
            )
            #expect(
                rendered.metrics.modelItemFrames.allSatisfy {
                    approximatelyContains(rendered.metrics.modelSectionFrame, $0)
                },
                "A model item escaped the model section for \(caseName)"
            )
            #expect(
                !approximatelyIntersects(
                    rendered.metrics.selectedDayDetailFrame,
                    rendered.metrics.footerFrame
                ),
                "Selected-day card overlapped the footer for \(caseName)"
            )
            #expect(
                renderedModelRowCount(rendered.metrics.modelItemFrames) == (modelCount == 0 ? 0 : expectedRowCount),
                "Unexpected model grid row count for \(caseName)"
            )
        }
    }
}

private struct RenderedPopover {
    let metrics: SourceUsagePopoverLayoutMetrics
    let expectedSize: CGSize
    let pngData: Data
}

@MainActor
private func renderPopover(language: AppLanguage, modelCount: Int) throws -> RenderedPopover {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let today = calendar.startOfDay(for: Date())
    let viewModel = SourceUsageViewModel(source: .codex, calendar: calendar)
    let dailyUsage = modelCount == 0
        ? []
        : [
            DailyUsage(
                day: today,
                source: .codex,
                tokens: TokenBreakdown(
                    input: 37_120_332,
                    cacheRead: 1_160_370_304,
                    output: 3_889_813
                ),
                knownCostMicrosUSD: 823_080_000,
                unknownCostEventCount: 641
            ),
        ]
    let snapshot = SourceUsageSnapshot(
        source: .codex,
        dailyUsage: dailyUsage,
        dailyModelUsage: makeModelUsage(count: modelCount, day: today),
        refreshedAt: today,
        pricingUpdatedAt: today
    )
    viewModel.apply(.ready(snapshot))

    var latestMetrics: SourceUsagePopoverLayoutMetrics?
    let height = SourceUsagePopoverSizing.contentHeight(for: viewModel.dailyModelUsage)
    let size = CGSize(width: SourceUsagePopoverSizing.width, height: height)
    let rootView = SourceUsagePopoverView(
        viewModel: viewModel,
        expectedSource: .codex,
        layoutObserver: { metrics in latestMetrics = metrics }
    )
    .environment(\.calendar, calendar)
    .environment(\.locale, Locale(identifier: language.rawValue))
    .environment(\.colorScheme, .dark)
    .environment(\.dynamicTypeSize, .medium)

    let hostingView = NSHostingView(rootView: rootView)
    hostingView.frame = NSRect(origin: .zero, size: size)
    hostingView.appearance = NSAppearance(named: .darkAqua)

    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = hostingView
    window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
    window.orderBack(nil)

    var stableMetrics: SourceUsagePopoverLayoutMetrics?
    var stableMetricsCount = 0
    for _ in 0..<80 {
        hostingView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))

        guard let latestMetrics,
              latestMetrics.modelItemFrames.count == modelCount else {
            continue
        }
        if stableMetrics == latestMetrics {
            stableMetricsCount += 1
        } else {
            stableMetrics = latestMetrics
            stableMetricsCount = 1
        }
        if stableMetricsCount >= 3 {
            break
        }
    }

    let metrics = try #require(
        stableMetricsCount >= 3 ? stableMetrics : nil,
        "Layout did not stabilize for \(language.rawValue), \(modelCount) models"
    )
    for _ in 0..<5 {
        hostingView.needsLayout = true
        hostingView.layoutSubtreeIfNeeded()
        hostingView.needsDisplay = true
        hostingView.displayIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    let imageRepresentation = try #require(
        hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds),
        "Could not allocate a bitmap for \(language.rawValue), \(modelCount) models"
    )
    hostingView.cacheDisplay(in: hostingView.bounds, to: imageRepresentation)
    try #require(
        snapshotContainsVisualVariation(imageRepresentation),
        "Rendered image was blank for \(language.rawValue), \(modelCount) models"
    )
    let pngData = try #require(
        imageRepresentation.representation(using: .png, properties: [:]),
        "Could not encode a PNG for \(language.rawValue), \(modelCount) models"
    )

    window.contentView = nil
    window.close()
    return RenderedPopover(metrics: metrics, expectedSize: size, pngData: pngData)
}

private func makeModelUsage(count: Int, day: Date) -> [DailyModelUsage] {
    let names: [String?] = [
        "gpt-5.6-sol",
        "gpt-5.5",
        "gpt-5.6-terra",
        "gpt-5.6-luna",
        "codex-auto-review",
        nil,
        "gpt-5.4",
        "gpt-5.4-mini",
        "gpt-5.3-codex-spark",
    ]
    return names.prefix(count).enumerated().map { index, name in
        DailyModelUsage(
            day: day,
            source: .codex,
            model: name,
            tokens: TokenBreakdown(
                input: Int64(110_000_000 - (index * 7_250_000)),
                output: Int64(1_000_000 + (index * 31_337))
            )
        )
    }
}

private func makeSnapshotDirectory() throws -> URL {
    let directory: URL
    if let configuredPath = ProcessInfo.processInfo.environment["TKMY_UI_SNAPSHOT_DIR"] {
        directory = URL(fileURLWithPath: configuredPath, isDirectory: true)
    } else {
        directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".build/ui-snapshots", isDirectory: true)
    }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    return directory
}

private func snapshotContainsVisualVariation(_ image: NSBitmapImageRep) -> Bool {
    let stepX = max(1, image.pixelsWide / 40)
    let stepY = max(1, image.pixelsHigh / 40)
    var colors = Set<Int>()
    for y in stride(from: 0, to: image.pixelsHigh, by: stepY) {
        for x in stride(from: 0, to: image.pixelsWide, by: stepX) {
            guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                continue
            }
            let red = Int((color.redComponent * 15).rounded())
            let green = Int((color.greenComponent * 15).rounded())
            let blue = Int((color.blueComponent * 15).rounded())
            colors.insert((red << 8) | (green << 4) | blue)
            if colors.count >= 4 { return true }
        }
    }
    return false
}

private func approximatelyContains(_ outer: CGRect, _ inner: CGRect) -> Bool {
    outer.insetBy(dx: -0.5, dy: -0.5).contains(inner)
}

private func approximatelyEqual(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
    abs(lhs.width - rhs.width) <= 0.5 && abs(lhs.height - rhs.height) <= 0.5
}

private func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
    abs(lhs.minX - rhs.minX) <= 0.5
        && abs(lhs.minY - rhs.minY) <= 0.5
        && approximatelyEqual(lhs.size, rhs.size)
}

private func framesAreApproximatelyEqual(_ lhs: [CGRect], _ rhs: [CGRect]) -> Bool {
    let lhs = framesInReadingOrder(lhs)
    let rhs = framesInReadingOrder(rhs)
    return lhs.count == rhs.count && zip(lhs, rhs).allSatisfy {
        approximatelyEqual($0.0, $0.1)
    }
}

private func framesInReadingOrder(_ frames: [CGRect]) -> [CGRect] {
    frames.sorted {
        if abs($0.minY - $1.minY) > 0.5 {
            return $0.minY < $1.minY
        }
        return $0.minX < $1.minX
    }
}

private func approximatelyIntersects(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
    let intersection = lhs.intersection(rhs)
    return !intersection.isNull && intersection.width > 0.5 && intersection.height > 0.5
}

private func renderedModelRowCount(_ frames: [CGRect]) -> Int {
    Set(frames.map { Int(($0.minY * 2).rounded()) }).count
}
