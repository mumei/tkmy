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
    @State private var hoveredDay: Date?

    public init(viewModel: SourceUsageViewModel) {
        self.viewModel = viewModel
        self.expectedSource = viewModel.source
        self._hoveredDay = State(initialValue: nil)
    }

    init(viewModel: SourceUsageViewModel, expectedSource: UsageSource) {
        self.viewModel = viewModel
        self.expectedSource = expectedSource
        self._hoveredDay = State(initialValue: nil)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
            header
            Divider()
            phaseContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(Layout.outerPadding)
        .frame(width: Layout.popoverWidth, height: Layout.popoverHeight, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await viewModel.refresh() }
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text(expectedSource.displayName)
                .font(.system(size: 20, weight: .semibold, design: .rounded))

            Spacer()

            ZStack(alignment: .trailing) {
                if case .loading = viewModel.phase {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("更新中")
                } else if let refreshedAt = viewModel.lastSuccessfulUpdate {
                    Text(refreshedAt, format: .dateTime.hour().minute())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("最終更新 \(refreshedAt.formatted(date: .omitted, time: .shortened))")
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
                title: "データソースが一致しません",
                message: "\(expectedSource.displayName)用のViewModelを指定してください。",
                retry: nil
            )
        } else {
            switch viewModel.phase {
            case .loading where viewModel.dailyUsage.isEmpty:
                loadingView
            case .loading:
                loadedContent(notice: nil)
            case .ready:
                loadedContent(notice: nil)
            case let .partialFailure(unreadableFileCount):
                loadedContent(
                    notice: unreadableFileCount == 1
                        ? "1件のファイルを読み取れませんでした。表示値は一部です。"
                        : "\(unreadableFileCount.formatted())件のファイルを読み取れませんでした。表示値は一部です。"
                )
            case let .staleSource(warning):
                loadedContent(notice: warning)
            case let .sourceMissing(searchedLocations):
                sourceMissingView(locations: searchedLocations)
            case let .unavailable(reason):
                StateMessageView(
                    symbol: "exclamationmark.circle",
                    title: "利用状況を表示できません",
                    message: reason ?? "保存データまたは利用記録を読み込めませんでした。",
                    retry: { Task { await viewModel.refresh() } }
                )
            }
        }
    }

    private var loadingView: some View {
        StateMessageView(
            symbol: "arrow.triangle.2.circlepath",
            title: "利用記録を読み込み中",
            message: "見つかった記録を端末内で集計しています。",
            retry: nil,
            showsProgress: true
        )
    }

    private func sourceMissingView(locations: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            StateMessageView(
                symbol: "folder.badge.questionmark",
                title: "\(expectedSource.displayName)の利用記録が見つかりません",
                message: "一度利用したあとに再読み込みしてください。",
                retry: { Task { await viewModel.refresh() } }
            )

            if !locations.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("確認した場所")
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
            todaySummary

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("日別トークン消費")
                        .font(.headline)
                    Spacer()
                    Text("直近12か月")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                TokenHeatmap(
                    source: expectedSource,
                    usage: viewModel.dailyUsage,
                    selectedDay: $viewModel.selectedDay,
                    hoveredDay: $hoveredDay
                )
            }

            selectedDayDetail

            Spacer(minLength: 0)
            footer(notice: notice)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var todaySummary: some View {
        let usage = viewModel.todayUsage
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("今日")
                    .font(.headline)

                if let usage, usage.unknownCostEventCount > 0 {
                    Label("\(usage.unknownCostEventCount.formatted())件 未算出", systemImage: "exclamationmark.circle")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 1) {
                    Text("直近30日の推定合計（USD）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(CostText.value(for: viewModel.recent30DayCostSummary))
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }

            HStack(alignment: .top, spacing: 0) {
                MetricView(title: "合計", value: usage.map { TokenText.compact($0.tokens.total) } ?? "0", isPrimary: true)
                summaryDivider
                MetricView(title: "入力", value: usage.map { TokenText.compact($0.tokens.input) } ?? "0")
                summaryDivider
                MetricView(title: "出力", value: usage.map { TokenText.compact($0.tokens.output) } ?? "0")
                summaryDivider
                MetricView(title: "推定金額（USD）", value: CostText.value(for: usage))
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("今日の利用状況")
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
                        Text("\(usage.unknownCostEventCount.formatted())件 未算出")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: Layout.selectedDayHeaderHeight, alignment: .top)

                LazyVGrid(columns: Layout.detailColumns, alignment: .leading, spacing: 8) {
                    DetailMetricView(title: "合計", value: usage.map { TokenText.exact($0.tokens.total) } ?? "0")
                    DetailMetricView(title: "入力", value: usage.map { TokenText.exact($0.tokens.input) } ?? "0")
                    DetailMetricView(title: "出力", value: usage.map { TokenText.exact($0.tokens.output) } ?? "0")
                    DetailMetricView(title: "キャッシュ作成", value: usage.map { TokenText.exact($0.tokens.cacheCreate5m + $0.tokens.cacheCreate1h) } ?? "0")
                    DetailMetricView(title: "キャッシュ読取", value: usage.map { TokenText.exact($0.tokens.cacheRead) } ?? "0")
                    DetailMetricView(title: "推定金額（USD）", value: CostText.value(for: usage))
                }

                Divider()

                VStack(alignment: .leading, spacing: 5) {
                    Text("モデル別トークン消費")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    if usageByModel.isEmpty {
                        Text("モデル情報なし")
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
                .frame(maxWidth: .infinity, minHeight: Layout.modelSectionHeight, alignment: .topLeading)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("選択日の詳細")
        } else {
            Text("ヒートマップの日付を選択すると詳細を表示します。")
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
                Text("推定金額はログ記録済みUSDを優先し、未記録分はAPI単価から算出した参考値です。")
                    .lineLimit(1)

                Spacer(minLength: 8)

                if let pricingUpdatedAt = viewModel.pricingUpdatedAt {
                    Text("価格表 \(pricingUpdatedAt.formatted(date: .numeric, time: .omitted))")
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.secondary)
        }
        .font(.caption2)
        .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32, alignment: .bottomLeading)
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
                Text("少")
                ForEach(1...5, id: \.self) { step in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(HeatmapColor.fill(intensity: Double(step) / 5))
                        .frame(width: 9, height: 9)
                }
                Text("多")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(source.displayName)のトークン消費。ティールから赤に近づくほど利用量が多い")
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
        return "\(date.formatted(date: .abbreviated, time: .omitted)): \(TokenText.exact(usage?.tokens.total ?? 0)) tokens"
    }

    private var accessibilityText: String {
        guard let date = item.date else { return "期間外" }
        return "\(date.formatted(date: .complete, time: .omitted))、\(TokenText.exact(usage?.tokens.total ?? 0))トークン"
    }
}

private struct ModelUsageView: View {
    let usage: DailyModelUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(usage.model ?? "モデル記録なし")
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
        .help(
            usage.model == nil
                ? "利用記録にモデル名が含まれていないトークンです。"
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
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
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
                Button("再読み込み", action: retry)
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
        value.formatted(.number.notation(.compactName))
    }

    static func exact(_ value: Int64) -> String {
        value.formatted(.number.grouping(.automatic))
    }
}

private enum CostText {
    static func value(for usage: DailyUsage?) -> String {
        guard let usage else { return "$0.00" }

        if usage.unknownCostEventCount > 0, usage.knownCostMicrosUSD == 0 {
            return "算出不可"
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
            return "算出不可"
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

private enum Layout {
    static let popoverWidth: CGFloat = 640
    static let popoverHeight: CGFloat = 560
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
    static let modelRowHeight: CGFloat = 32
    static let modelSectionHeight: CGFloat = 51
    static let detailColumns = Array(
        repeating: GridItem(.flexible(minimum: 150), spacing: 16, alignment: .leading),
        count: 3
    )
    static let modelColumns = Array(
        repeating: GridItem(.flexible(minimum: 110), spacing: 12, alignment: .leading),
        count: 4
    )
}
