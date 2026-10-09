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
    let accounts: [QuotaAccount]
    let activeAccountID: String?
    @Binding private var selectedAccountID: String?
    private var effectiveAccountID: String { selectedAccountID ?? activeAccountID ?? "anonymous" }
    private var displayHistory: [UsageLimitSnapshot] {
        UsageLimitHistoryTimeline.confirmedHistory(from: history.filter {
            ($0.quotaAccountID ?? "anonymous") == effectiveAccountID
        })
    }
    private var isCurrentAccount: Bool { effectiveAccountID == activeAccountID }

    let source: UsageSource
    let quotaTokenSummary: QuotaTokenSummary?
    let layoutObserver: ((QuotaHistoryLayoutMetrics) -> Void)?
    let chartRangeObserver: ((UsageLimitHistoryRange) -> Void)?

    @Binding private var range: UsageLimitHistoryRange
    @Binding private var selectedBucketID: String?
    @State private var showsTokenDetails = false

    init(
        history: [UsageLimitSnapshot],
        source: UsageSource,
        range: Binding<UsageLimitHistoryRange>,
        selectedBucketID: Binding<String?>,
        quotaTokenSummary: QuotaTokenSummary? = nil,
        accounts: [QuotaAccount] = [],
        activeAccountID: String? = nil,
        selectedAccountID: Binding<String?> = .constant(nil),
        layoutObserver: ((QuotaHistoryLayoutMetrics) -> Void)? = nil,
        chartRangeObserver: ((UsageLimitHistoryRange) -> Void)? = nil
    ) {
        self.history = history
        self.accounts = accounts.filter { $0.source == source }
        self.activeAccountID = activeAccountID
        _selectedAccountID = selectedAccountID
        self.source = source
        self.quotaTokenSummary = quotaTokenSummary
        self.layoutObserver = layoutObserver
        self.chartRangeObserver = chartRangeObserver
        _range = range
        _selectedBucketID = selectedBucketID
    }

    private var now: Date { Date() }
    private var buckets: [UsageLimitHistoryBucket] {
        UsageLimitHistoryTimeline.buckets(from: displayHistory, source: source, range: range, now: now)
    }
    private var selectedBucket: UsageLimitHistoryBucket? {
        buckets.first { $0.id == selectedBucketID }
            ?? UsageLimitHistoryTimeline.preferredBucket(in: buckets)
    }
    private var observations: [UsageLimitSnapshot] {
        buckets.flatMap { bucket in
            UsageLimitHistoryTimeline.observations(from: displayHistory, source: source, bucket: bucket, range: range, now: now)
        }.sorted {
            if $0.observedAt != $1.observedAt { return $0.observedAt < $1.observedAt }
            return $0.windowMinutes < $1.windowMinutes
        }
    }
    private var paceObservations: [UsageLimitSnapshot] {
        observations.filter { UsageLimitHistoryBucket($0) == selectedBucket }
    }
    private var lastConfirmedAt: Date? {
        chartObservations.map(\.lastObservedAt).filter { $0 <= now }.max()
    }
    private var chartObservations: [UsageLimitSnapshot] {
        buckets.flatMap { bucket in
            UsageLimitHistoryTimeline.chartObservations(from: displayHistory, source: source, bucket: bucket, range: range, now: now)
        }
    }
    private var consumptionPace: QuotaConsumptionPace? {
        // Prefer a shared time/token interval once two actual changes have
        // been observed after token coverage became verifiable.
        if let summary = quotaTokenSummary, summary.isComplete,
           let bucket = selectedBucket,
           let coverageStart = summary.coverageStartedAt,
           let coveredPace = QuotaConsumptionPace.latest(
               in: paceObservations, range: range, now: now, minimumStartedAt: coverageStart
           ),
           summary.tokens(
               fromExclusive: coveredPace.startedAt, through: coveredPace.endedAt, limitID: bucket.limitID
           ) != nil {
            return coveredPace
        }
        return QuotaConsumptionPace.latest(in: paceObservations, range: range, now: now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                .reportQuotaFrame(.rangePicker)
            }

            accountPicker
            Text(L10n.text(isCurrentAccount ? "quota_account_current" : "quota_account_last_observed"))
                .font(.caption2).foregroundStyle(.secondary)
            if buckets.isEmpty {
                ContentUnavailableView(
                    L10n.text("quota_history_empty_title"),
                    systemImage: "chart.line.uptrend.xyaxis",
                    description: Text(L10n.text("quota_history_empty_message"))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                legend.reportQuotaFrame(.windowPicker)
                if chartObservations.isEmpty {
                    ContentUnavailableView(
                        L10n.text("quota_history_empty_title"),
                        systemImage: "calendar.badge.exclamationmark",
                        description: Text(L10n.text("quota_history_period_empty"))
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    UsageLimitHistoryChart(
                        observations: chartObservations,
                        range: range,
                        now: now,
                        extendsLatestObservation: isCurrentAccount,
                        rangeObserver: chartRangeObserver
                    )
                        .frame(height: 148)
                        .layoutPriority(1)
                        .help(L10n.text("quota_chart_gap_note"))
                        .reportQuotaFrame(.chart)
                    tokenSummary
                    if let lastConfirmedAt {
                        Text(L10n.text("quota_last_confirmed", timestamp(lastConfirmedAt)))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    observationTable
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .coordinateSpace(name: "quota-history-layout")
        .onPreferenceChange(QuotaHistoryLayoutPreference.self) { frames in
            if let metrics = QuotaHistoryLayoutMetrics(frames: frames) { layoutObserver?(metrics) }
        }
        .onAppear(perform: synchronizeSelectedBucket)
        .onChange(of: range) { _, _ in synchronizeSelectedBucket() }
        .onChange(of: history) { _, _ in synchronizeSelectedBucket() }
        .onChange(of: selectedAccountID) { _, _ in synchronizeSelectedBucket() }
    }

    private var accountPicker: some View {
        Picker(L10n.text("quota_account"), selection: $selectedAccountID) {
            Text(L10n.text("quota_account_unknown")).tag(Optional("anonymous"))
            ForEach(accounts) { account in
                Text(account.displayName).tag(Optional(account.id))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(L10n.text("quota_account"))
    }

    private var legend: some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(legendBuckets) { bucket in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Circle().fill(UsageLimitHistoryChart.color(for: bucket)).frame(width: 7, height: 7)
                        Text(bucketTitle(bucket))
                        Text(latestObservation(for: bucket).map { percentage($0.remainingPercent) } ?? "—")
                            .monospacedDigit()
                    }
                    if let latest = latestObservation(for: bucket) {
                        Text(timestamp(latest.lastObservedAt)).foregroundStyle(.secondary)
                    }
                }
                .font(.caption2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var legendBuckets: [UsageLimitHistoryBucket] {
        var values = buckets
        let limitID = accounts.first { $0.id == effectiveAccountID }?.limitID
            ?? (source == .codex ? "codex" : "claude-code")
        for minutes in [300, 10_080] where !values.contains(where: { $0.windowMinutes == minutes && $0.isGeneral }) {
            values.append(UsageLimitHistoryBucket(limitID: limitID, windowMinutes: minutes))
        }
        return values.sorted { $0.windowMinutes < $1.windowMinutes }
    }

    private func latestObservation(for bucket: UsageLimitHistoryBucket) -> UsageLimitSnapshot? {
        chartObservations.filter { UsageLimitHistoryBucket($0) == bucket }.max { $0.lastObservedAt < $1.lastObservedAt }
    }

    private var paceWindowTitle: String { selectedBucket.map { durationText($0.windowMinutes) + " · " } ?? "" }

    private var tokenSummary: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let pace = consumptionPace {
                Text(paceWindowTitle + L10n.text(
                    "quota_pace_average_format",
                    QuotaConfirmationDuration.text(duration: pace.secondsPerPercentagePoint)
                ))
                .font(.caption.weight(.semibold))
                .lineLimit(1)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let tokens = tokenBreakdown(for: pace) {
                        Text(L10n.text(
                            "quota_tokens_average_format",
                            tokenAverage(tokens.total, pace: pace)
                        ))
                        .font(.caption)
                        .lineLimit(1)
                        Button {
                            showsTokenDetails.toggle()
                        } label: {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.text("quota_token_details"))
                        .help(L10n.text("quota_token_details"))
                        .popover(isPresented: $showsTokenDetails, arrowEdge: .bottom) {
                            tokenDetails
                        }
                    } else {
                        Text(L10n.text("quota_tokens_unavailable"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            } else {
                Text(paceWindowTitle + L10n.text("quota_pace_insufficient"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var tokenDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("quota_token_details"))
                .font(.headline)
            if let pace = consumptionPace, let tokens = tokenBreakdown(for: pace) {
                Text(L10n.text(
                    "quota_tokens_breakdown_format",
                    tokenAverage(tokens.input, pace: pace),
                    tokenAverage(tokens.cacheRead, pace: pace),
                    tokenAverage(tokens.output, pace: pace)
                ))
                Text(L10n.text(
                    "quota_pace_basis_format",
                    QuotaConfirmationDuration.text(duration: pace.elapsed),
                    pace.percentagePointDrop.formatted(.number.precision(.fractionLength(0...2)).locale(L10n.locale))
                ))
                Text(period(start: pace.startedAt, end: pace.endedAt))
            } else {
                Text(L10n.text("quota_tokens_unavailable"))
            }
            Text(L10n.text("quota_tokens_note"))
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
        .padding(14)
        .frame(width: 340, alignment: .leading)
    }

    private func tokenBreakdown(for pace: QuotaConsumptionPace) -> TokenBreakdown? {
        guard effectiveAccountID == "anonymous", let bucket = selectedBucket else { return nil }
        return quotaTokenSummary?.tokens(
            fromExclusive: pace.startedAt, through: pace.endedAt, limitID: bucket.limitID
        )
    }

    private func tokenAverage(_ tokens: Int64, pace: QuotaConsumptionPace) -> String {
        (Double(tokens) / pace.percentagePointDrop)
            .formatted(.number.precision(.fractionLength(0)).locale(L10n.locale))
    }

    private var observationTable: some View {
        // LazyVStack may request a row after the view's time-dependent
        // observations have changed. Keep indices and row data on one snapshot.
        let tableObservations = observations
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
                Text(L10n.text("quota_observed"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(L10n.text("quota_remaining"))
                    .frame(width: 68, alignment: .trailing)
                Text(L10n.text("quota_next_reset"))
                    .frame(width: 130, alignment: .trailing)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .reportQuotaFrame(.tableHeader)

            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    if tableObservations.isEmpty {
                        Text(L10n.text("quota_history_period_empty"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    }
                    ForEach(tableObservations.indices.reversed(), id: \.self) { index in
                        let observation = tableObservations[index]
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(timestamp(observation.observedAt))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(durationText(observation.windowMinutes) + " · " + elapsedSincePrevious(at: index, in: tableObservations))
                                    .foregroundStyle(UsageLimitHistoryChart.color(for: UsageLimitHistoryBucket(observation)))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(timestamp(observation.observedAt))
                            Text(percentage(observation.remainingPercent))
                                .monospacedDigit()
                                .frame(width: 68, alignment: .trailing)
                            Text(resetText(observation.resetsAt))
                                .monospacedDigit()
                                .lineLimit(1)
                                .frame(width: 130, alignment: .trailing)
                        }
                        .font(.caption)
                        .padding(.vertical, 3)
                        .accessibilityElement(children: .combine)
                        Divider()
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity)
            .accessibilityLabel(L10n.text("quota_observations_table"))
            .reportQuotaFrame(.rowsViewport)
        }
        .frame(maxHeight: .infinity)
    }

    private func bucketTitle(_ bucket: UsageLimitHistoryBucket) -> String {
        let trimmedID = bucket.limitID.trimmingCharacters(in: .whitespacesAndNewlines)
        let category = trimmedID.isEmpty || bucket.isGeneral
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

    private func elapsedSincePrevious(at index: Int, in observations: [UsageLimitSnapshot]) -> String {
        let current = observations[index]
        guard let previous = observations.prefix(index).last(where: { UsageLimitHistoryBucket($0) == UsageLimitHistoryBucket(current) }) else {
            return L10n.text("quota_first_observation")
        }
        let elapsed = max(0.001, current.observedAt.timeIntervalSince(previous.observedAt))
        return L10n.text(
            "quota_since_previous_format",
            QuotaConfirmationDuration.text(duration: elapsed)
        )
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

struct QuotaHistoryLayoutMetrics: Equatable {
    let rangePicker: CGRect
    let windowPicker: CGRect
    let chart: CGRect
    let tableHeader: CGRect
    let rowsViewport: CGRect

    fileprivate init?(frames: [QuotaHistoryLayoutElement: CGRect]) {
        guard let rangePicker = frames[.rangePicker], let windowPicker = frames[.windowPicker],
              let chart = frames[.chart], let tableHeader = frames[.tableHeader],
              let rowsViewport = frames[.rowsViewport] else { return nil }
        self.rangePicker = rangePicker
        self.windowPicker = windowPicker
        self.chart = chart
        self.tableHeader = tableHeader
        self.rowsViewport = rowsViewport
    }
}

private enum QuotaHistoryLayoutElement: Hashable {
    case rangePicker, windowPicker, chart, tableHeader, rowsViewport
}

private struct QuotaHistoryLayoutPreference: PreferenceKey {
    static let defaultValue: [QuotaHistoryLayoutElement: CGRect] = [:]
    static func reduce(
        value: inout [QuotaHistoryLayoutElement: CGRect],
        nextValue: () -> [QuotaHistoryLayoutElement: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private extension View {
    func reportQuotaFrame(_ element: QuotaHistoryLayoutElement) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(
                key: QuotaHistoryLayoutPreference.self,
                value: [element: proxy.frame(in: .named("quota-history-layout"))]
            )
        })
    }
}
