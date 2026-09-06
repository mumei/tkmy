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

    @State private var range: UsageLimitHistoryRange = .sevenDays
    @State private var selectedBucketID: String?

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
                .pickerStyle(.segmented)
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
                    UsageLimitHistoryChart(observations: observations, range: range, now: now)
                        .frame(height: 148)
                    Text(L10n.text("quota_chart_gap_note"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    observationTable
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: synchronizeSelectedBucket)
        .onChange(of: range) { _, _ in synchronizeSelectedBucket() }
        .onChange(of: history) { _, _ in synchronizeSelectedBucket() }
    }

    private var observationTable: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(L10n.text("quota_observed"))
                Spacer()
                Text(L10n.text("quota_remaining"))
                Text(L10n.text("quota_next_reset"))
                    .frame(width: 130, alignment: .trailing)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(observations.reversed()) { observation in
                        HStack {
                            Text(observation.observedAt, format: .dateTime.month().day().hour().minute().second().locale(L10n.locale))
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
            }
            .frame(maxHeight: .infinity)
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

private struct UsageLimitHistoryChart: View {
    let observations: [UsageLimitSnapshot]
    let range: UsageLimitHistoryRange
    let now: Date

    var body: some View {
        GeometryReader { proxy in
            let cutoff = now.addingTimeInterval(-range.interval)
            let segments = UsageLimitHistoryTimeline.segments(observations)
            Canvas { context, size in
                let chartRect = CGRect(x: 30, y: 8, width: max(1, size.width - 34), height: max(1, size.height - 28))
                for level in [0.0, 50.0, 100.0] {
                    let y = yPosition(level, in: chartRect)
                    var grid = Path()
                    grid.move(to: CGPoint(x: chartRect.minX, y: y))
                    grid.addLine(to: CGPoint(x: chartRect.maxX, y: y))
                    context.stroke(grid, with: .color(.secondary.opacity(0.22)), lineWidth: 1)
                    context.draw(Text("\(Int(level))%").font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: 13, y: y))
                }
                for segment in segments where !segment.isEmpty {
                    var path = Path()
                    for (index, observation) in segment.enumerated() {
                        let point = CGPoint(
                            x: xPosition(observation.observedAt, cutoff: cutoff, now: now, in: chartRect),
                            y: yPosition(observation.remainingPercent, in: chartRect)
                        )
                        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                    context.stroke(path, with: .color(.accentColor), lineWidth: 2)
                    for observation in segment {
                        let point = CGPoint(
                            x: xPosition(observation.observedAt, cutoff: cutoff, now: now, in: chartRect),
                            y: yPosition(observation.remainingPercent, in: chartRect)
                        )
                        context.fill(Path(ellipseIn: CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5)), with: .color(.accentColor))
                    }
                }
                let middle = cutoff.addingTimeInterval(range.interval / 2)
                context.draw(Text(dateLabel(cutoff)).font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: chartRect.minX, y: size.height - 8), anchor: .leading)
                context.draw(Text(dateLabel(middle)).font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: chartRect.midX, y: size.height - 8))
                context.draw(Text(dateLabel(now)).font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: chartRect.maxX, y: size.height - 8), anchor: .trailing)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("quota_chart_a11y"))
    }

    private func xPosition(_ date: Date, cutoff: Date, now: Date, in rect: CGRect) -> CGFloat {
        let span = max(1, now.timeIntervalSince(cutoff))
        return rect.minX + CGFloat(min(1, max(0, date.timeIntervalSince(cutoff) / span))) * rect.width
    }

    private func yPosition(_ remaining: Double, in rect: CGRect) -> CGFloat {
        rect.maxY - CGFloat(min(100, max(0, remaining)) / 100) * rect.height
    }

    private func dateLabel(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().locale(L10n.locale))
    }
}
