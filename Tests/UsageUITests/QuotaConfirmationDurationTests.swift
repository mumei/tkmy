import Foundation
import Testing
import UsageDomain
@testable import UsageUI

@Test func confirmationDurationFormatsMinutesHoursAndDays() {
    #expect(durationText(minutes: 35, language: .english).contains("35"))
    let twoHoursFifteenMinutes = durationText(minutes: 135, language: .english)
    #expect(twoHoursFifteenMinutes.contains("2"))
    #expect(twoHoursFifteenMinutes.contains("15"))
    let oneHour = durationText(minutes: 60, language: .english)
    #expect(oneHour.contains("1"))
    #expect(!oneHour.contains("minute"))
    let severalDays = durationText(minutes: (3 * 24 * 60) + 125, language: .english)
    #expect(severalDays.contains("3"))
    #expect(severalDays.contains("2"))
    #expect(severalDays.contains("5"))
}

@Test func confirmationDurationKeepsSingleAndSubMinuteStatesDistinct() {
    let single = QuotaConfirmationDuration.text(for: observation(duration: 0), language: .english)
    let subMinute = QuotaConfirmationDuration.text(for: observation(duration: 59), language: .english)
    let oneMinute = QuotaConfirmationDuration.text(for: observation(duration: 60), language: .english)
    #expect(single == L10n.text("quota_single_observation", language: .english))
    #expect(subMinute == L10n.text("quota_less_than_minute", language: .english))
    #expect(single != subMinute)
    #expect(oneMinute.contains("1 minute"))
}

@Test func confirmationDurationAcceptsStandaloneElapsedTimeSafely() {
    #expect(QuotaConfirmationDuration.text(duration: 35 * 60, language: .english).contains("35"))
    #expect(QuotaConfirmationDuration.text(duration: 0, language: .english) == L10n.text("quota_single_observation", language: .english))
    #expect(QuotaConfirmationDuration.text(duration: .nan, language: .english) == L10n.text("quota_single_observation", language: .english))
}

@Test func confirmationDurationTruncatesSubsequentSecondsInsteadOfRounding() {
    let oneMinuteFiftyNineSeconds = QuotaConfirmationDuration.text(
        for: observation(duration: 119),
        language: .english
    )
    #expect(oneMinuteFiftyNineSeconds.contains("1"))
    #expect(!oneMinuteFiftyNineSeconds.contains("2 minutes"))
}

@Test func confirmationDurationUsesAbsoluteElapsedTimeAcrossDST() {
    let start = Date(timeIntervalSince1970: 1_710_054_000)
    let observation = UsageLimitSnapshot(
        source: .codex,
        limitID: "codex",
        usedPercent: 20,
        windowMinutes: 300,
        resetsAt: nil,
        observedAt: start,
        lastObservedAt: start.addingTimeInterval(2 * 60 * 60)
    )
    let text = QuotaConfirmationDuration.text(for: observation, language: .english)
    #expect(text.contains("2"))
    #expect(text.localizedCaseInsensitiveContains("hour"))
}

@Test func confirmationDurationHasLocalizedSpecialStatesForEveryLanguage() {
    for language in AppLanguage.allCases {
        let single = L10n.text("quota_single_observation", language: language)
        let subMinute = L10n.text("quota_less_than_minute", language: language)
        #expect(single != "quota_single_observation")
        #expect(subMinute != "quota_less_than_minute")
        #expect(!QuotaConfirmationDuration.text(for: observation(duration: 35 * 60), language: language).isEmpty)
    }
}

private func durationText(minutes: Int, language: AppLanguage) -> String {
    QuotaConfirmationDuration.text(for: observation(duration: TimeInterval(minutes * 60)), language: language)
}

private func observation(duration: TimeInterval) -> UsageLimitSnapshot {
    let start = Date(timeIntervalSince1970: 1_760_000_000)
    return UsageLimitSnapshot(
        source: .codex,
        limitID: "codex",
        usedPercent: 20,
        windowMinutes: 300,
        resetsAt: nil,
        observedAt: start,
        lastObservedAt: start.addingTimeInterval(duration)
    )
}
@Test func quotaNewLabelsAreTranslatedAndKeepLiteralPercentSigns() {
    let plainKeys = [
        "quota_range_1h", "quota_range_6h", "quota_range_12h", "quota_range_1d",
        "quota_consumption_pace", "quota_pace_recent", "quota_pace_note",
        "quota_pace_insufficient", "quota_tokens_note", "quota_tokens_unavailable",
        "quota_first_observation"
    ]
    for language in AppLanguage.allCases {
        for key in plainKeys {
            let text = L10n.text(key, language: language)
            #expect(!text.isEmpty && text != key)
        }
        for key in ["quota_pace_average_format", "quota_tokens_average_format"] {
            let text = L10n.text(key, language: language, "35")
            #expect(text.contains("%"), "Missing literal percent in \(language.rawValue): \(key)")
            #expect(text.contains("35") && !text.contains("%@"))
        }
        #expect(!L10n.text("quota_pace_basis_format", language: language, "35", "2").contains("%@"))
        #expect(!L10n.text("quota_tokens_breakdown_format", language: language, "100", "200", "30").contains("%@"))
        let sincePrevious = L10n.text("quota_since_previous_format", language: language, "12 min")
        #expect(sincePrevious.contains("12 min") && !sincePrevious.contains("%@"))
    }
}
