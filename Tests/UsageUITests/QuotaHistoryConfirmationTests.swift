import Foundation
import Testing
import UsageDomain
@testable import UsageUI

private let base = Date(timeIntervalSince1970: 1_790_215_200)
private let weeklyReset = Date(timeIntervalSince1970: 1_790_818_808)

@Test func transientRecoveryInSameWeeklyWindowIsNotDisplayed() {
    let history = [
        quota(at: 24, used: 1),
        quota(at: 484, used: 0),
        quota(at: 487, used: 1),
    ]

    let displayed = UsageLimitHistoryTimeline.confirmedHistory(from: history)

    #expect(displayed.map(\.usedPercent) == [1, 1])
    #expect(displayed.map(\.observedAt) == [base.addingTimeInterval(24), base.addingTimeInterval(487)])
    #expect(history.map(\.usedPercent) == [1, 0, 1]) // Source evidence stays unchanged.
}

@Test func sustainedRecoveryIsDisplayedAfterConfirmation() {
    let history = [
        quota(at: 0, used: 10),
        quota(at: 10, used: 9),
        quota(at: 70, used: 9),
    ]
    #expect(UsageLimitHistoryTimeline.confirmedHistory(from: Array(history.prefix(2)))
        .map(\.usedPercent) == [10])
    #expect(UsageLimitHistoryTimeline.confirmedHistory(from: history)
        .map(\.usedPercent) == [10, 9, 9])
}

@Test func actualResetAndDifferentBucketRemainVisible() {
    let oldReset = base.addingTimeInterval(20)
    let nextReset = oldReset.addingTimeInterval(7 * 24 * 60 * 60)
    let old = quota(at: 10, used: 89, reset: oldReset, epoch: "old")
    let reset = quota(at: 21, used: 0, reset: nextReset, epoch: "new")
    let model = quota(at: 22, used: 0, reset: nextReset, epoch: "model", limitID: "codex_model")

    let displayed = UsageLimitHistoryTimeline.confirmedHistory(from: [old, reset, model])

    #expect(displayed.count == 3)
    #expect(displayed.contains(reset))
    #expect(displayed.contains(model))
}

@Test func ResetJitterAndStorageEpochChangeDoNotConfirmRecovery() {
    let before = quota(at: 0, used: 1, epoch: "before-gap")
    let jitter = quota(at: 100, used: 0, reset: weeklyReset.addingTimeInterval(2), epoch: "after-gap")
    let after = quota(at: 103, used: 1, epoch: "after-gap")

    #expect(UsageLimitHistoryTimeline.confirmedHistory(from: [before, jitter, after]) == [before, after])
}

private func quota(
    at seconds: TimeInterval,
    used: Double,
    reset: Date = weeklyReset,
    epoch: String = "same",
    limitID: String = "codex"
) -> UsageLimitSnapshot {
    UsageLimitSnapshot(
        source: .codex, limitID: limitID, usedPercent: used, windowMinutes: 10_080,
        resetsAt: reset, observedAt: base.addingTimeInterval(seconds), resetEpochID: epoch
    )
}
