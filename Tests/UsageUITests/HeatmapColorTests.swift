import Testing
@testable import UsageUI

@Test func heatmapIntensityUsesContinuousLinearRatio() {
    #expect(HeatmapColor.intensity(value: 0, maximum: 100) == 0)
    #expect(HeatmapColor.intensity(value: 25, maximum: 100) == 0.25)
    #expect(HeatmapColor.intensity(value: 50, maximum: 100) == 0.5)
    #expect(HeatmapColor.intensity(value: 75, maximum: 100) == 0.75)
    #expect(HeatmapColor.intensity(value: 100, maximum: 100) == 1)
}

@Test func heatmapIntensityClampsInvalidAndOversizedValues() {
    #expect(HeatmapColor.intensity(value: -1, maximum: 100) == 0)
    #expect(HeatmapColor.intensity(value: 1, maximum: 0) == 0)
    #expect(HeatmapColor.intensity(value: 150, maximum: 100) == 1)
}

@Test func heatmapRampMovesContinuouslyAcrossFiveColorStops() {
    #expect(HeatmapColor.rampPosition(intensity: 0) == .init(lowerStopIndex: 0, fraction: 0))
    #expect(HeatmapColor.rampPosition(intensity: 0.125) == .init(lowerStopIndex: 0, fraction: 0.5))
    #expect(HeatmapColor.rampPosition(intensity: 0.5) == .init(lowerStopIndex: 2, fraction: 0))
    #expect(HeatmapColor.rampPosition(intensity: 0.875) == .init(lowerStopIndex: 3, fraction: 0.5))
    #expect(HeatmapColor.rampPosition(intensity: 1) == .init(lowerStopIndex: 3, fraction: 1))
}
