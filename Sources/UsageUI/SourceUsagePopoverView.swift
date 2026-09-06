/* Hallmark · component: popover · genre: modern-minimal · theme: macOS-native
 * states: default · hover · focus · active · disabled · loading · error · success
 * contrast: system semantic colors
 * Hallmark · pre-emit critique: P5 H5 E5 S5 R5 V5
 */
import SwiftUI
import UsageDomain

public struct CodexUsagePopoverView: View {
    @ObservedObject private var viewModel: SourceUsageViewModel

    public init(viewModel: SourceUsageViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        SourceUsagePopoverView(viewModel: viewModel, expectedSource: .codex)
    }
}

public struct ClaudeCodeUsagePopoverView: View {
    @ObservedObject private var viewModel: SourceUsageViewModel

    public init(viewModel: SourceUsageViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        SourceUsagePopoverView(viewModel: viewModel, expectedSource: .claudeCode)
    }
}

public struct SourceUsagePopoverView: View {
    @ObservedObject private var viewModel: SourceUsageViewModel
    private let expectedSource: UsageSource
    private let layoutObserver: ((SourceUsagePopoverLayoutMetrics) -> Void)?
    private let quotaHistoryChartRangeObserver: ((UsageLimitHistoryRange) -> Void)?
    @State private var hoveredDay: Date?
    @State private var selectedPane: UsagePopoverPane = .usage
    @AppStorage(L10n.defaultsKey) private var languageRawValue = AppLanguage.systemDefault().rawValue

    public init(viewModel: SourceUsageViewModel) {
        self.viewModel = viewModel
        self.expectedSource = viewModel.source
        self.layoutObserver = nil
        self.quotaHistoryChartRangeObserver = nil
        self._hoveredDay = State(initialValue: nil)
    }

    init(
        viewModel: SourceUsageViewModel,
        expectedSource: UsageSource,
        initialPane: UsagePopoverPane = .usage,
        layoutObserver: ((SourceUsagePopoverLayoutMetrics) -> Void)? = nil,
        quotaHistoryChartRangeObserver: ((UsageLimitHistoryRange) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.expectedSource = expectedSource
        self.layoutObserver = layoutObserver
        self.quotaHistoryChartRangeObserver = quotaHistoryChartRangeObserver
        self._hoveredDay = State(initialValue: nil)
        self._selectedPane = State(initialValue: initialPane)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
            header
            Divider()
            phaseContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(Layout.outerPadding)
        .frame(
            width: SourceUsagePopoverSizing.width,
            height: SourceUsagePopoverSizing.contentHeight(for: viewModel.dailyModelUsage),
            alignment: .topLeading
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .coordinateSpace(name: Layout.coordinateSpaceName)
        .reportPopoverFrame(.root)
        .onPreferenceChange(SourceUsagePopoverLayoutPreferenceKey.self) { value in
            guard let metrics = value.metrics else { return }
            layoutObserver?(metrics)
        }
        .environment(\.sourceUsagePopoverLayoutReportingEnabled, layoutObserver != nil)
        .environment(\.locale, selectedLanguageLocale)
        .task { await viewModel.refresh() }
    }

    private var selectedLanguageLocale: Locale {
        Locale(identifier: AppLanguage(rawValue: languageRawValue)?.rawValue ?? AppLanguage.japanese.rawValue)
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text(expectedSource.displayName)
                .font(.system(size: 20, weight: .semibold, design: .rounded))

            if expectedSource == .codex {
                Picker(L10n.text("usage_pane"), selection: $selectedPane) {
                    ForEach(UsagePopoverPane.allCases) { pane in
                        Text(L10n.text(pane.localizationKey)).tag(pane)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 340)
            }

            Spacer()

            ZStack(alignment: .trailing) {
                if case .loading = viewModel.phase {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(L10n.text("updating"))
                } else if let refreshedAt = viewModel.lastSuccessfulUpdate {
                    Text(refreshedAt, format: .dateTime.hour().minute())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(L10n.text(
                            "last_updated",
                            refreshedAt.formatted(.dateTime.hour().minute().locale(selectedLanguageLocale))
                        ))
                }
            }
            .frame(width: Layout.headerAccessoryWidth, height: Layout.headerHeight, alignment: .trailing)
        }
        .frame(height: Layout.headerHeight)
    }

    @ViewBuilder
    private var phaseContent: some View {
        if viewModel.source != expectedSource {
            StateMessageView(
                symbol: "exclamationmark.triangle",
                title: L10n.text("source_mismatch"),
                message: L10n.text("use_viewmodel_for_source", expectedSource.displayName),
                retry: nil
            )
        } else {
            switch viewModel.phase {
            case .loading, .ready, .partialFailure, .staleSource:
                // Keep the loaded subtree's identity stable throughout a refresh.
                if viewModel.phase == .loading,
                   viewModel.dailyUsage.isEmpty,
                   viewModel.usageLimitHistory.isEmpty {
                    loadingView
                } else {
                    loadedContent(notice: refreshNotice)
                }
            case let .sourceMissing(searchedLocations):
                sourceMissingView(locations: searchedLocations)
            case let .unavailable(reason):
                StateMessageView(
                    symbol: "exclamationmark.circle",
                    title: L10n.text("cannot_display"),
                    message: reason ?? L10n.text("cannot_read_data"),
                    retry: { Task { await viewModel.refresh() } }
                )
            }
        }
    }

    private var refreshNotice: String? {
        switch viewModel.phase {
        case let .partialFailure(unreadableFileCount):
            unreadableFileCount == 1
                ? L10n.text("unreadable_file_one")
                : L10n.text("unreadable_files", Int64(unreadableFileCount))
        case let .staleSource(warning):
            warning
        default:
            nil
        }
    }

    private var loadingView: some View {
        StateMessageView(
            symbol: "arrow.triangle.2.circlepath",
            title: L10n.text("loading_records"),
            message: L10n.text("aggregating_locally"),
            retry: nil,
            showsProgress: true
        )
    }

    private func sourceMissingView(locations: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            StateMessageView(
                symbol: "folder.badge.questionmark",
                title: L10n.text("records_not_found", expectedSource.displayName),
                message: L10n.text("use_then_reload"),
                retry: { Task { await viewModel.refresh() } }
            )

            if !locations.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("searched_locations"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    ForEach(locations, id: \.self) { location in
                        Text(location)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func loadedContent(notice: String?) -> some View {
        VStack(alignment: .leading, spacing: Layout.contentSpacing) {
            if selectedPane == .quotaHistory, expectedSource == .codex {
                UsageLimitHistoryView(
                    history: viewModel.usageLimitHistory,
                    source: .codex,
                    range: $viewModel.selectedQuotaHistoryRange,
                    selectedBucketID: $viewModel.selectedQuotaHistoryBucketID,
                    quotaTokenSummary: viewModel.quotaTokenSummary,
                    chartRangeObserver: quotaHistoryChartRangeObserver
                )
            } else {
                usageContent(notice: notice)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func usageContent(notice: String?) -> some View {
        VStack(alignment: .leading, spacing: Layout.contentSpacing) {
            todaySummary

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(L10n.text("daily_token_usage"))
                        .font(.headline)
                    Spacer()
                    Text(L10n.text("last_12_months"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                TokenHeatmap(source: expectedSource, usage: viewModel.dailyUsage, selectedDay: $viewModel.selectedDay, hoveredDay: $hoveredDay)
            }
            selectedDayDetail
            Spacer(minLength: 0)
            footer(notice: notice)
        }
    }

    private var todaySummary: some View {
        let usage = viewModel.todayUsage
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.text("today"))
                    .font(.headline)

                if let usage, usage.unknownCostEventCount > 0 {
                    Label(L10n.text("uncalculated_count", Int64(usage.unknownCostEventCount)), systemImage: "exclamationmark.circle")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 1) {
                    Text(L10n.text("recent_30_day_cost"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                    Text(CostText.value(for: viewModel.recent30DayCostSummary))
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }

            HStack(alignment: .top, spacing: 0) {
                MetricView(title: L10n.text("total"), value: usage.map { TokenText.compact($0.tokens.total) } ?? "0", isPrimary: true)
                summaryDivider
                MetricView(title: L10n.text("input"), value: usage.map { TokenText.compact($0.tokens.input) } ?? "0")
                summaryDivider
                MetricView(title: L10n.text("output"), value: usage.map { TokenText.compact($0.tokens.output) } ?? "0")
                summaryDivider
                MetricView(title: L10n.text("estimated_cost"), value: CostText.value(for: usage))
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("today_usage"))
    }

    private var summaryDivider: some View {
        Divider()
            .frame(height: 38)
            .padding(.horizontal, 8)
    }

    @ViewBuilder
    private var selectedDayDetail: some View {
        if let displayedDay = HeatmapSelection.displayedDay(
            pinned: viewModel.selectedDay,
            hovered: hoveredDay
        ) {
            let usage = viewModel.usage(on: displayedDay)
            let usageByModel = viewModel.modelUsage(on: displayedDay)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(displayedDay, format: .dateTime.year().month().day().weekday(.wide))
                        .font(.subheadline.weight(.semibold))

                    Spacer()

                    if let usage, usage.unknownCostEventCount > 0 {
                        Text(L10n.text("uncalculated_count", Int64(usage.unknownCostEventCount)))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: Layout.selectedDayHeaderHeight, alignment: .top)
                .reportPopoverFrame(.selectedDayHeader)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 16) {
                        DetailMetricView(title: L10n.text("total"), value: usage.map { TokenText.exact($0.tokens.total) } ?? "0")
                        DetailMetricView(title: L10n.text("input"), value: usage.map { TokenText.exact($0.tokens.input) } ?? "0")
                        DetailMetricView(title: L10n.text("output"), value: usage.map { TokenText.exact($0.tokens.output) } ?? "0")
                    }

                    HStack(alignment: .top, spacing: 16) {
                        if expectedSource == .claudeCode {
                            DetailMetricView(title: L10n.text("cache_create"), value: usage.map { TokenText.exact($0.tokens.cacheCreate5m + $0.tokens.cacheCreate1h) } ?? "0")
                        }
                        DetailMetricView(title: L10n.text("cache_read"), value: usage.map { TokenText.exact($0.tokens.cacheRead) } ?? "0")
                        DetailMetricView(title: L10n.text("estimated_cost"), value: CostText.value(for: usage))
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.text("model_token_usage"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    if usageByModel.isEmpty {
                        Text(L10n.text("no_model_info"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(
                                maxWidth: .infinity,
                                minHeight: Layout.modelRowHeight,
                                alignment: .topLeading
                            )
                    } else {
                        LazyVGrid(columns: Layout.modelColumns, alignment: .leading, spacing: 6) {
                            ForEach(usageByModel) { item in
                                ModelUsageView(usage: item)
                            }
                        }
                    }
                }
                .frame(
                    maxWidth: .infinity,
                    minHeight: SourceUsagePopoverSizing.modelSectionHeight(for: viewModel.dailyModelUsage),
                    alignment: .topLeading
                )
                .reportPopoverFrame(.modelSection)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            .reportPopoverFrame(.selectedDayDetail)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.text("selected_day_details"))
        } else {
            Text(L10n.text("select_heatmap_day"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func footer(notice: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let notice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(notice)
                    .accessibilityAddTraits(.isStaticText)
            }

            HStack(spacing: 8) {
                Text(L10n.text("cost_note"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)

                Spacer(minLength: 8)

                if let pricingUpdatedAt = viewModel.pricingUpdatedAt {
                    Text(L10n.text(
                        "price_table",
                        pricingUpdatedAt.formatted(.dateTime.year().month().day().locale(selectedLanguageLocale))
                    ))
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.secondary)
        }
        .font(.caption2)
        .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32, alignment: .bottomLeading)
        .reportPopoverFrame(.footer)
    }
}

public struct TokenHeatmap: View {
    private let source: UsageSource
    private let usage: [DailyUsage]
    @Binding private var selectedDay: Date?
    @Binding private var hoveredDay: Date?

    @Environment(\.calendar) private var calendar

    public init(
        source: UsageSource,
        usage: [DailyUsage],
        selectedDay: Binding<Date?>,
        hoveredDay: Binding<Date?>
    ) {
        self.source = source
        self.usage = usage
        self._selectedDay = selectedDay
        self._hoveredDay = hoveredDay
    }

    public var body: some View {
        let cells = HeatmapTimeline.make(calendar: calendar)
        let usageByDay = Dictionary(uniqueKeysWithValues: usage.map {
            (calendar.startOfDay(for: $0.day), $0)
        })
        let maximum = usage.map(\.tokens.total).max() ?? 0

        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { proxy in
                let gridWidth = max(0, proxy.size.width - Layout.weekdayLabelWidth - Layout.heatmapLabelGap)
                let cellSize = max(
                    1,
                    (gridWidth - (CGFloat(HeatmapTimeline.weekCount - 1) * Layout.heatmapGap))
                        / CGFloat(HeatmapTimeline.weekCount)
                )

                HStack(alignment: .top, spacing: Layout.heatmapLabelGap) {
                    weekdayLabels(for: cells, cellSize: cellSize)

                    HStack(spacing: Layout.heatmapGap) {
                        ForEach(0..<HeatmapTimeline.weekCount, id: \.self) { week in
                            VStack(spacing: Layout.heatmapGap) {
                                ForEach(0..<HeatmapTimeline.daysPerWeek, id: \.self) { weekday in
                                    let item = cells[(week * HeatmapTimeline.daysPerWeek) + weekday]
                                    HeatmapDayButton(
                                        item: item,
                                        usage: item.date.flatMap { usageByDay[calendar.startOfDay(for: $0)] },
                                        maximum: maximum,
                                        isSelected: item.date.map { itemDate in
                                            selectedDay.map { selectedDate in
                                                calendar.isDate(itemDate, inSameDayAs: selectedDate)
                                            } ?? false
                                        } ?? false,
                                        cellSize: cellSize,
                                        select: { selectedDay = item.date },
                                        hover: { hovering in
                                            if hovering {
                                                hoveredDay = item.date
                                            } else if hoveredDay == item.date {
                                                hoveredDay = nil
                                            }
                                        }
                                    )
                                }
                            }
                        }
                    }
                }
            }
            .frame(height: Layout.heatmapGridHeight)

            HStack(spacing: 4) {
                Spacer()
                Text(L10n.text("less"))
                ForEach(1...5, id: \.self) { step in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(HeatmapColor.fill(intensity: Double(step) / 5))
                        .frame(width: 9, height: 9)
                }
                Text(L10n.text("more"))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text("heatmap_a11y", source.displayName))
        }
        .frame(maxWidth: .infinity)
    }

    private func weekdayLabels(for cells: [HeatmapItem], cellSize: CGFloat) -> some View {
        VStack(alignment: .trailing, spacing: Layout.heatmapGap) {
            ForEach(0..<HeatmapTimeline.daysPerWeek, id: \.self) { index in
                Text(cells[index].date.map { $0.formatted(.dateTime.weekday(.narrow)) } ?? "")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .frame(width: Layout.weekdayLabelWidth, height: cellSize)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct HeatmapDayButton: View {
    let item: HeatmapItem
    let usage: DailyUsage?
    let maximum: Int64
    let isSelected: Bool
    let cellSize: CGFloat
    let select: () -> Void
    let hover: (Bool) -> Void

    @State private var isHovered = false

    var body: some View {
        let tokenCount = usage?.tokens.total ?? 0

        Button(action: select) {
            RoundedRectangle(cornerRadius: 2)
                .fill(
                    item.date == nil
                        ? Color.clear
                        : HeatmapColor.fill(value: tokenCount, maximum: maximum)
                )
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(Color.primary, lineWidth: 1.5)
                    } else if isHovered, item.date != nil {
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(Color.secondary, lineWidth: 1)
                    }
                }
                .frame(width: cellSize, height: cellSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(item.date == nil)
        .onHover { hovering in
            isHovered = hovering
            guard item.date != nil else { return }
            hover(hovering)
        }
        .help(helpText)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHidden(item.date == nil)
    }

    private var helpText: String {
        guard let date = item.date else { return "" }
        let dateText = date.formatted(.dateTime.year().month().day().locale(L10n.locale))
        return "\(dateText): \(L10n.text("tokens_format", TokenText.exact(usage?.tokens.total ?? 0)))"
    }

    private var accessibilityText: String {
        guard let date = item.date else { return L10n.text("outside_period") }
        let dateText = date.formatted(.dateTime.year().month().day().weekday(.wide).locale(L10n.locale))
        return "\(dateText), \(L10n.text("tokens_format", TokenText.exact(usage?.tokens.total ?? 0)))"
    }
}

private struct ModelUsageView: View {
    let usage: DailyModelUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(usage.model ?? L10n.text("model_not_recorded"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(TokenText.exact(usage.tokens.total))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: Layout.modelRowHeight, alignment: .topLeading)
        .reportPopoverFrame(.modelItem)
        .help(
            usage.model == nil
                ? L10n.text("model_missing_help")
                : usage.model ?? ""
        )
        .accessibilityElement(children: .combine)
    }
}

enum HeatmapSelection {
    static func displayedDay(pinned: Date?, hovered: Date?) -> Date? {
        hovered ?? pinned
    }
}

private struct MetricView: View {
    let title: String
    let value: String
    var isPrimary = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Text(value)
                .font(.system(size: isPrimary ? 26 : 20, weight: isPrimary ? .bold : .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct DetailMetricView: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .reportPopoverFrame(.detailMetric)
        .accessibilityElement(children: .combine)
    }
}

private struct StateMessageView: View {
    let symbol: String
    let title: String
    let message: String
    let retry: (() -> Void)?
    var showsProgress = false

    var body: some View {
        VStack(spacing: 12) {
            if showsProgress {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 390)
            if let retry {
                Button(L10n.text("reload"), action: retry)
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .padding()
        .accessibilityElement(children: .contain)
    }
}

private struct HeatmapItem {
    let date: Date?
}

private enum HeatmapTimeline {
    static let weekCount = 52
    static let daysPerWeek = 7

    static func make(calendar: Calendar, now: Date = Date()) -> [HeatmapItem] {
        let today = calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: today)
        let distanceFromWeekStart = (weekday - calendar.firstWeekday + daysPerWeek) % daysPerWeek
        let currentWeekStart = calendar.date(byAdding: .day, value: -distanceFromWeekStart, to: today) ?? today
        let firstDay = calendar.date(byAdding: .weekOfYear, value: -(weekCount - 1), to: currentWeekStart) ?? currentWeekStart

        return (0..<(weekCount * daysPerWeek)).map { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: firstDay), date <= today else {
                return HeatmapItem(date: nil)
            }
            return HeatmapItem(date: date)
        }
    }
}

enum HeatmapColor {
    struct RampPosition: Equatable {
        let lowerStopIndex: Int
        let fraction: Double
    }

    private static let rampStops: [NSColor] = [
        .systemTeal,
        .systemGreen,
        .systemYellow,
        .systemOrange,
        .systemRed,
    ]

    static func intensity(value: Int64, maximum: Int64) -> Double {
        guard value > 0, maximum > 0 else { return 0 }
        return min(1, max(0, Double(value) / Double(maximum)))
    }

    static func fill(value: Int64, maximum: Int64) -> Color {
        let intensity = intensity(value: value, maximum: maximum)
        guard intensity > 0 else { return Color(nsColor: .separatorColor).opacity(0.28) }
        return fill(intensity: intensity)
    }

    static func fill(intensity: Double) -> Color {
        let position = rampPosition(intensity: intensity)
        let lower = rampStops[position.lowerStopIndex]
        let upper = rampStops[position.lowerStopIndex + 1]
        let color = lower.blended(withFraction: position.fraction, of: upper) ?? lower
        return Color(nsColor: color)
    }

    static func rampPosition(intensity: Double) -> RampPosition {
        let normalized = min(1, max(0, intensity))
        let scaled = normalized * Double(rampStops.count - 1)
        let lowerStopIndex = min(rampStops.count - 2, Int(scaled.rounded(.down)))
        return RampPosition(
            lowerStopIndex: lowerStopIndex,
            fraction: scaled - Double(lowerStopIndex)
        )
    }
}

private enum TokenText {
    static func compact(_ value: Int64) -> String {
        value.formatted(.number.notation(.compactName).locale(L10n.locale))
    }

    static func exact(_ value: Int64) -> String {
        value.formatted(.number.grouping(.automatic).locale(L10n.locale))
    }
}

private enum CostText {
    static func value(for usage: DailyUsage?) -> String {
        guard let usage else { return "$0.00" }

        if usage.unknownCostEventCount > 0, usage.knownCostMicrosUSD == 0 {
            return L10n.text("cannot_calculate")
        }

        let dollars = Decimal(usage.knownCostMicrosUSD) / 1_000_000
        let amount = dollars.formatted(
            .currency(code: "USD")
                .precision(.fractionLength(2))
                .locale(Locale(identifier: "en_US_POSIX"))
        )
        return usage.unknownCostEventCount > 0 ? "\(amount)+" : amount
    }

    static func value(for summary: UsageCostSummary) -> String {
        if summary.unknownCostEventCount > 0, summary.knownCostMicrosUSD == 0 {
            return L10n.text("cannot_calculate")
        }

        let dollars = summary.knownCostMicrosUSD / 1_000_000
        let amount = dollars.formatted(
            .currency(code: "USD")
                .precision(.fractionLength(2))
                .locale(Locale(identifier: "en_US_POSIX"))
        )
        return summary.unknownCostEventCount > 0 ? "\(amount)+" : amount
    }
}

public enum SourceUsagePopoverSizing {
    private struct DayKey: Hashable {
        let source: UsageSource
        let day: Date
    }

    public static let width: CGFloat = 640
    public static let baseHeight: CGFloat = 566
    public static let modelColumnCount = 4
    public static let modelRowHeight: CGFloat = 32
    public static let modelRowSpacing: CGFloat = 6
    public static let baseModelSectionHeight: CGFloat = 51

    public static func maximumModelCountPerDay(
        in usage: [DailyModelUsage],
        calendar: Calendar = .current
    ) -> Int {
        Dictionary(grouping: usage) {
            DayKey(source: $0.source, day: calendar.startOfDay(for: $0.day))
        }
        .values
        .map(\.count)
        .max() ?? 0
    }

    public static func modelRowCount(
        for usage: [DailyModelUsage],
        calendar: Calendar = .current
    ) -> Int {
        let count = maximumModelCountPerDay(in: usage, calendar: calendar)
        return max(1, (count + modelColumnCount - 1) / modelColumnCount)
    }

    public static func modelSectionHeight(
        for usage: [DailyModelUsage],
        calendar: Calendar = .current
    ) -> CGFloat {
        baseModelSectionHeight + additionalHeight(for: usage, calendar: calendar)
    }

    public static func contentHeight(
        for usage: [DailyModelUsage],
        calendar: Calendar = .current
    ) -> CGFloat {
        baseHeight + additionalHeight(for: usage, calendar: calendar)
    }

    private static func additionalHeight(
        for usage: [DailyModelUsage],
        calendar: Calendar
    ) -> CGFloat {
        CGFloat(modelRowCount(for: usage, calendar: calendar) - 1) * (modelRowHeight + modelRowSpacing)
    }
}

struct SourceUsagePopoverLayoutMetrics: Equatable {
    let rootFrame: CGRect
    let selectedDayDetailFrame: CGRect
    let selectedDayHeaderFrame: CGRect
    let detailMetricFrames: [CGRect]
    let modelSectionFrame: CGRect
    let footerFrame: CGRect
    let modelItemFrames: [CGRect]
}

private enum SourceUsagePopoverLayoutElement {
    case root
    case selectedDayDetail
    case selectedDayHeader
    case detailMetric
    case modelSection
    case modelItem
    case footer
}

private struct SourceUsagePopoverLayoutPreference: Equatable {
    var rootFrame: CGRect?
    var selectedDayDetailFrame: CGRect?
    var selectedDayHeaderFrame: CGRect?
    var detailMetricFrames: [CGRect] = []
    var modelSectionFrame: CGRect?
    var footerFrame: CGRect?
    var modelItemFrames: [CGRect] = []

    init(frame: CGRect? = nil, element: SourceUsagePopoverLayoutElement? = nil) {
        guard let frame, let element else { return }
        switch element {
        case .root:
            rootFrame = frame
        case .selectedDayDetail:
            selectedDayDetailFrame = frame
        case .selectedDayHeader:
            selectedDayHeaderFrame = frame
        case .detailMetric:
            detailMetricFrames = [frame]
        case .modelSection:
            modelSectionFrame = frame
        case .modelItem:
            modelItemFrames = [frame]
        case .footer:
            footerFrame = frame
        }
    }

    mutating func merge(_ next: Self) {
        rootFrame = next.rootFrame ?? rootFrame
        selectedDayDetailFrame = next.selectedDayDetailFrame ?? selectedDayDetailFrame
        selectedDayHeaderFrame = next.selectedDayHeaderFrame ?? selectedDayHeaderFrame
        detailMetricFrames.append(contentsOf: next.detailMetricFrames)
        modelSectionFrame = next.modelSectionFrame ?? modelSectionFrame
        footerFrame = next.footerFrame ?? footerFrame
        modelItemFrames.append(contentsOf: next.modelItemFrames)
    }

    var metrics: SourceUsagePopoverLayoutMetrics? {
        guard
            let rootFrame,
            let selectedDayDetailFrame,
            let selectedDayHeaderFrame,
            let modelSectionFrame,
            let footerFrame
        else {
            return nil
        }
        return SourceUsagePopoverLayoutMetrics(
            rootFrame: rootFrame,
            selectedDayDetailFrame: selectedDayDetailFrame,
            selectedDayHeaderFrame: selectedDayHeaderFrame,
            detailMetricFrames: detailMetricFrames,
            modelSectionFrame: modelSectionFrame,
            footerFrame: footerFrame,
            modelItemFrames: modelItemFrames
        )
    }
}

private struct SourceUsagePopoverLayoutPreferenceKey: PreferenceKey {
    static let defaultValue = SourceUsagePopoverLayoutPreference()

    static func reduce(
        value: inout SourceUsagePopoverLayoutPreference,
        nextValue: () -> SourceUsagePopoverLayoutPreference
    ) {
        value.merge(nextValue())
    }
}

private struct SourceUsagePopoverLayoutReportingEnabledKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var sourceUsagePopoverLayoutReportingEnabled: Bool {
        get { self[SourceUsagePopoverLayoutReportingEnabledKey.self] }
        set { self[SourceUsagePopoverLayoutReportingEnabledKey.self] = newValue }
    }
}

private struct SourceUsagePopoverLayoutReporter: View {
    @Environment(\.sourceUsagePopoverLayoutReportingEnabled) private var isEnabled
    let element: SourceUsagePopoverLayoutElement

    @ViewBuilder
    var body: some View {
        if isEnabled {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: SourceUsagePopoverLayoutPreferenceKey.self,
                    value: SourceUsagePopoverLayoutPreference(
                        frame: proxy.frame(in: .named(Layout.coordinateSpaceName)),
                        element: element
                    )
                )
            }
        } else {
            Color.clear
        }
    }
}

private extension View {
    func reportPopoverFrame(_ element: SourceUsagePopoverLayoutElement) -> some View {
        background {
            SourceUsagePopoverLayoutReporter(element: element)
        }
    }
}

private enum Layout {
    static let coordinateSpaceName = "source-usage-popover"
    static let outerPadding: CGFloat = 16
    static let headerHeight: CGFloat = 24
    static let headerAccessoryWidth: CGFloat = 48
    static let sectionSpacing: CGFloat = 12
    static let contentSpacing: CGFloat = 12
    static let heatmapGap: CGFloat = 2
    static let heatmapLabelGap: CGFloat = 8
    static let weekdayLabelWidth: CGFloat = 12
    static let heatmapGridHeight: CGFloat = 78
    static let selectedDayHeaderHeight: CGFloat = 18
    static let modelRowHeight = SourceUsagePopoverSizing.modelRowHeight
    static let modelColumns = Array(
        repeating: GridItem(.flexible(minimum: 110), spacing: 12, alignment: .leading),
        count: SourceUsagePopoverSizing.modelColumnCount
    )
}
