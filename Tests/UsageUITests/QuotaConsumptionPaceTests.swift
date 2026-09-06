import Foundation
import Testing
import UsageDomain
@testable import UsageUI

struct QuotaConsumptionPaceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("One percent pace uses change timestamps, not constant-run duration")
    func onePointDrop() throws {
        let value = try #require(pace([
            sample(-2_100, used: 20, last: -60), sample(0, used: 21)
        ]))
        #expect(value.elapsed == 2_100)
        #expect(value.secondsPerPercentagePoint == 2_100)
    }

    @Test("Multiple percentage points use the continuous interval average")
    func multiplePoints() throws {
        let value = try #require(pace([
            sample(-8_100, used: 20, last: -3_660),
            sample(-3_600, used: 22, last: -60), sample(0, used: 24)
        ]))
        #expect(value.percentagePointDrop == 4)
        #expect(value.elapsed == 8_100)
        #expect(value.secondsPerPercentagePoint == 2_025)
    }

    @Test("Trailing same-level confirmations never extend the pace endpoint")
    func confirmationDoesNotExtendPace() throws {
        let value = try #require(pace([
            sample(-2_400, used: 20, last: -360),
            sample(-300, used: 21, last: 0)
        ]))
        #expect(value.endedAt == now.addingTimeInterval(-300))
        #expect(value.secondsPerPercentagePoint == 2_100)
    }

    @Test("Insufficient, flat, reset, missing, reversed, overlapping and conflicting observations have no pace")
    func unavailableCases() {
        let invalid: [[UsageLimitSnapshot]] = [
            [], [sample(0, used: 20)],
            [sample(-60, used: 20), sample(0, used: 20)],
            [sample(-60, used: 20), sample(0, used: 21, epoch: "next")],
            [sample(-1_801, used: 20), sample(0, used: 21)],
            [sample(0, used: 21), sample(-60, used: 20)],
            [sample(-60, used: 20, last: 0), sample(-30, used: 21)],
            [sample(0, used: 20), sample(0, used: 21)],
            [sample(-60, used: 20), sample(0, used: 19)],
            [sample(-60, used: 20), sample(1, used: 21)],
            [sample(-60, used: 20), sample(0, used: 21, source: .claudeCode)],
            [sample(-60, used: 20), sample(0, used: 21, limitID: "model")],
        ]
        for observations in invalid { #expect(pace(observations) == nil) }
    }

    @Test("Only the latest continuous segment supplies the estimate")
    func latestSegment() throws {
        let value = try #require(pace([
            sample(-8_000, used: 20), sample(-7_000, used: 21),
            sample(-600, used: 25), sample(0, used: 27)
        ]))
        #expect(value.elapsed == 600)
        #expect(value.percentagePointDrop == 2)
        #expect(pace([
            sample(-8_000, used: 20), sample(-7_000, used: 21), sample(0, used: 25)
        ]) == nil)
    }

    @Test("A range boundary cannot invent a pace baseline")
    func rangeBoundary() throws {
        #expect(pace([
            sample(-3_601, used: 20, last: -60), sample(0, used: 21)
        ], range: .oneHour) == nil)
        let value = try #require(pace([
            sample(-3_600, used: 20, last: -60), sample(0, used: 21)
        ], range: .oneHour))
        #expect(value.elapsed == 3_600)
    }

    @Test("Token coverage starts at the next actual observation, never at a synthetic boundary")
    func coverageBoundary() throws {
        let observations = [
            sample(-1_200, used: 20), sample(-600, used: 21), sample(0, used: 23)
        ]
        let value = try #require(QuotaConsumptionPace.latest(
            in: observations, range: .oneHour, now: now,
            minimumStartedAt: now.addingTimeInterval(-900)
        ))
        #expect(value.startedAt == now.addingTimeInterval(-600))
        #expect(value.elapsed == 600)
        #expect(value.percentagePointDrop == 2)
        #expect(QuotaConsumptionPace.latest(
            in: observations, range: .oneHour, now: now,
            minimumStartedAt: now.addingTimeInterval(-300)
        ) == nil)
    }

    private func pace(
        _ observations: [UsageLimitSnapshot], range: UsageLimitHistoryRange = .sevenDays
    ) -> QuotaConsumptionPace? {
        QuotaConsumptionPace.latest(in: observations, range: range, now: now)
    }

    private func sample(
        _ offset: TimeInterval, used: Double, last: TimeInterval? = nil,
        epoch: String = "epoch", source: UsageSource = .codex, limitID: String = "codex"
    ) -> UsageLimitSnapshot {
        UsageLimitSnapshot(
            source: source, limitID: limitID, usedPercent: used, windowMinutes: 300,
            resetsAt: now.addingTimeInterval(8_000),
            observedAt: now.addingTimeInterval(offset),
            lastObservedAt: last.map { now.addingTimeInterval($0) }, resetEpochID: epoch
        )
    }
}
