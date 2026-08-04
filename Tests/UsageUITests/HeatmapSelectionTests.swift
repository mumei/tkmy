import Foundation
import Testing
@testable import UsageUI

@Test func hoveredDayTakesPriorityOverPinnedDay() {
    let pinned = Date(timeIntervalSince1970: 1)
    let hovered = Date(timeIntervalSince1970: 2)

    #expect(HeatmapSelection.displayedDay(pinned: pinned, hovered: hovered) == hovered)
}

@Test func pinnedDayReturnsAfterHoverEnds() {
    let pinned = Date(timeIntervalSince1970: 1)

    #expect(HeatmapSelection.displayedDay(pinned: pinned, hovered: nil) == pinned)
}
