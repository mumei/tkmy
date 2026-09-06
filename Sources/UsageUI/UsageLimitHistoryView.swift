import SwiftUI
import UsageDomain

enum UsagePopoverPane: String, CaseIterable, Identifiable, Hashable {
    case usage
    case quotaHistory

    var id: String { rawValue }
    var localizationKey: String {
        self == .usage ? "token_usage_pane" : "quota_history_pane"
    }
}

struct UsageLimitHistoryView: View {
    let history: [UsageLimitSnapshot]
    let source: UsageSource
    let quotaTokenSummary: QuotaTokenSummary?

    @State private var range: UsageLimitHistoryRange
    @State private var selectedBucketID: String?

    init(
        history: [UsageLimitSnapshot],
        source: UsageSource,
        initialRange: UsageLimitHistoryRange = .sevenDays,
        quotaTokenSummary: QuotaTokenSummary? = nil
    ) {
        self.history = history
        self.source = source
        self.quotaTokenSummary = quotaTokenSummary
        _range = State(initialValue: initialRange)
    }

    private var now: Date { Date() }
    private var buckets: [UsageLimitHistoryBucket] {
        UsageLimitHistoryTimeline.buckets(from: history, source: source, range: range, now: now)
    }
    private var selectedBucket: UsageLimitHistoryBucket? {
        buckets.first { $0.id == selectedBucketID }
            ?? UsageLimitHistoryTimeline.preferredBucket(in: buckets)
    }
    private var observations: [UsageLimitSnapshot] {
        guard let selectedBucket else { return [] }
        return UsageLimitHistoryTimeline.observations(
            from: history,
            source: source,
            bucket: selectedBucket,
            range: range,
            now: now
        )
    }
    private var lastConfirmedAt: Date? {
        observations.map(\.lastObservedAt).filter { $0 <= now }.max()
    }
    private var chartObservations: [UsageLimitSnapshot] {
        guard let selectedBucket else { return [] }
        return UsageLimitHistoryTimeline.chartObservations(
            from: history, source: source, bucket: selectedBucket, range: range, now: now
        )
    }
    private var consumptionPace: QuotaConsumptionPace? {
        // Prefer a shared time/token interval once two actual changes have
        // been observed after token coverage became verifiable.
        if let summary = quotaTokenSummary, summary.isComplete,
           let bucket = selectedBucket,
           let coverageStart = summary.coverageStartedAt,
           let coveredPace = QuotaConsumptionPace.latest(
               in: observations, range: range, now: now, minimumStartedAt: coverageStart
           ),
           summary.tokens(
               fromExclusive: coveredPace.startedAt, through: coveredPace.endedAt, limitID: bucket.limitID
           ) != nil {
            return coveredPace
        }
        return QuotaConsumptionPace.latest(in: observations, range: range, now: now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.text("remaining_quota_history"))
                    .font(.headline)
                Spacer()
                Picker(L10n.text("quota_period"), selection: $range) {
                    ForEach(UsageLimitHistoryRange.allCases) { value in
                        Text(L10n.text(value.localizationKey)).tag(value)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 132)
                .labelsHidden()
                .accessibilityLabel(L10n.text("quota_period"))
            }

            if buckets.isEmpty {
                ContentUnavailableView(
                    L10n.text("quota_history_empty_title"),
                    systemImage: "chart.line.uptrend.xyaxis",
                    description: Text(L10n.text("quota_history_empty_message"))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Picker(L10n.text("quota_window"), selection: $selectedBucketID) {
                    ForEach(buckets) { bucket in
                        Text(bucketTitle(bucket)).tag(Optional(bucket.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                if observations.isEmpty {
                    ContentUnavailableView(
                        L10n.text("quota_history_empty_title"),
                        systemImage: "calendar.badge.exclamationmark",
                        description: Text(L10n.text("quota_history_period_empty"))
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            UsageLimitHistoryChart(observations: chartObservations, range: range, now: now)
                                .frame(height: 148)
                            Text(L10n.text("quota_chart_gap_note"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            paceSummary
                            if let lastConfirmedAt {
                                Text(L10n.text("quota_last_confirmed", timestamp(lastConfirmedAt)))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            observationTable
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: synchronizeSelectedBucket)
        .onChange(of: range) { _, _ in synchronizeSelectedBucket() }
        .onChange(of: history) { _, _ in synchronizeSelectedBucket() }
    }

    private var paceSummary: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let pace = consumptionPace {
                Text(L10n.text("quota_consumption_pace"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(L10n.text(
                    "quota_pace_average_format",
                    QuotaConfirmationDuration.text(duration: pace.secondsPerPercentagePoint)
                ))
                .font(.subheadline.weight(.semibold))
                Text(L10n.text("quota_pace_recent") + " · " + L10n.text(
                    "quota_pace_basis_format",
                    QuotaConfirmationDuration.text(duration: pace.elapsed),
                    pace.percentagePointDrop.formatted(.number.precision(.fractionLength(0...2)).locale(L10n.locale))
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(period(start: pace.startedAt, end: pace.endedAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                tokenPaceSummary(pace)
            } else {
                Text(L10n.text("quota_pace_insufficient"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(L10n.text("quota_pace_note"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.text("quota_consumption_pace"))
    }

    @ViewBuilder
    private func tokenPaceSummary(_ pace: QuotaConsumptionPace) -> some View {
        if let bucket = selectedBucket,
           let tokens = quotaTokenSummary?.tokens(
               fromExclusive: pace.startedAt, through: pace.endedAt, limitID: bucket.limitID
           ) {
            Text(L10n.text("quota_tokens_average_format", tokenAverage(tokens.total, pace: pace)))
                .font(.subheadline.weight(.semibold))
                .padding(.top, 3)
            Text(L10n.text(
                "quota_tokens_breakdown_format",
                tokenAverage(tokens.input, pace: pace),
                tokenAverage(tokens.cacheRead, pace: pace),
                tokenAverage(tokens.output, pace: pace)
            ))
            .font(.caption2)
            .foregroundStyle(.secondary)
            Text(L10n.text("quota_tokens_note"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(L10n.text("quota_tokens_unavailable"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func tokenAverage(_ tokens: Int64, pace: QuotaConsumptionPace) -> String {
        (Double(tokens) / pace.percentagePointDrop)
            .formatted(.number.precision(.fractionLength(0)).locale(L10n.locale))
    }

    private var observationTable: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(L10n.text("quota_confirmation_period"))
                Spacer()
                Text(L10n.text("quota_remaining"))
                Text(L10n.text("quota_next_reset"))
                    .frame(width: 130, alignment: .trailing)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)

            LazyVStack(spacing: 0) {
                ForEach(observations.reversed()) { observation in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(QuotaConfirmationDuration.text(for: observation))
                                .fontWeight(.medium)
                            Text(confirmationPeriod(observation))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .monospacedDigit()
                        Spacer()
                        Text(percentage(observation.remainingPercent))
                            .monospacedDigit()
                        Text(resetText(observation.resetsAt))
                            .monospacedDigit()
                            .frame(width: 130, alignment: .trailing)
                    }
                    .font(.caption)
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                    Divider()
                }
            }
            .accessibilityLabel(L10n.text("quota_observations_table"))
        }
    }

    private func bucketTitle(_ bucket: UsageLimitHistoryBucket) -> String {
        let trimmedID = bucket.limitID.trimmingCharacters(in: .whitespacesAndNewlines)
        let category = trimmedID.isEmpty || trimmedID.lowercased() == "codex"
            ? L10n.text("quota_general")
            : L10n.text("quota_model_limit", readableLimitID(trimmedID))
        return L10n.text("quota_window_format", category, durationText(bucket.windowMinutes))
    }

    private func percentage(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)).locale(L10n.locale)) + "%"
    }

    private func resetText(_ reset: Date?) -> String {
        guard let reset else { return L10n.text("quota_reset_unknown") }
        return reset.formatted(.dateTime.month().day().hour().minute().second().locale(L10n.locale))
    }

    private func confirmationPeriod(_ observation: UsageLimitSnapshot) -> String {
        period(start: observation.observedAt, end: observation.lastObservedAt)
    }

    private func period(start: Date, end: Date) -> String {
        guard start != end else { return timestamp(start) }
        let endText = Calendar.current.isDate(start, inSameDayAs: end)
            ? end.formatted(.dateTime.hour().minute().second().locale(L10n.locale))
            : timestamp(end)
        return "\(timestamp(start))–\(endText)"
    }

    private func timestamp(_ date: Date) -> String {
        date.formatted(.dateTime.month().day().hour().minute().second().locale(L10n.locale))
    }

    private func readableLimitID(_ limitID: String) -> String {
        if limitID.lowercased() == "codex_bengalfox" { return "GPT-5.3-Codex-Spark" }
        return limitID
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { String($0.prefix(1)).uppercased() + String($0.dropFirst()) }
            .joined(separator: " ")
    }

    private func durationText(_ minutes: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = L10n.locale
        let formatter = DateComponentsFormatter()
        formatter.calendar = calendar
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 1
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: TimeInterval(minutes * 60)) ?? "\(minutes)"
    }

    private func synchronizeSelectedBucket() {
        guard buckets.contains(where: { $0.id == selectedBucketID }) else {
            selectedBucketID = UsageLimitHistoryTimeline.preferredBucket(in: buckets)?.id
            return
        }
    }
}
