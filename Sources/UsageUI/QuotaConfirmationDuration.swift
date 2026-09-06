import Foundation
import UsageDomain

/// Formats the elapsed wall-clock confirmation period of a stored quota run.
/// It intentionally uses absolute elapsed time rather than calendar components,
/// so a daylight-saving transition does not alter the reported duration.
public enum QuotaConfirmationDuration {
    public static func text(
        for observation: UsageLimitSnapshot,
        language: AppLanguage = L10n.language
    ) -> String {
        text(
            duration: observation.lastObservedAt.timeIntervalSince(observation.observedAt),
            language: language
        )
    }

    /// Formats an absolute elapsed duration for confirmation and pace summaries.
    /// Invalid or non-positive values deliberately use the single-observation
    /// label so callers never present a misleading zero-duration estimate.
    public static func text(
        duration: TimeInterval,
        language: AppLanguage = L10n.language
    ) -> String {
        guard duration.isFinite, duration > 0 else {
            return L10n.text("quota_single_observation", language: language)
        }
        guard duration >= 60 else {
            return L10n.text("quota_less_than_minute", language: language)
        }

        let wholeMinutes = floor(duration / 60)
        let truncatedDuration = wholeMinutes * 60
        guard truncatedDuration.isFinite else {
            return L10n.text("quota_single_observation", language: language)
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: language.rawValue)
        let formatter = DateComponentsFormatter()
        formatter.calendar = calendar
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 3
        formatter.unitsStyle = .full
        formatter.zeroFormattingBehavior = .dropAll

        return formatter.string(from: truncatedDuration)
            ?? L10n.text("quota_single_observation", language: language)
    }
}
