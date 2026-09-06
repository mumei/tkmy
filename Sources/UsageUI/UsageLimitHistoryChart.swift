import SwiftUI
import UsageDomain

enum UsageLimitHistoryChartAxis {
    enum LabelStyle: Equatable {
        case time
        case dateAndTime
        case date
    }

    static func labelStyle(for range: UsageLimitHistoryRange) -> LabelStyle {
        switch range {
        case .oneHour, .sixHours, .twelveHours:
            .time
        case .oneDay:
            .dateAndTime
        case .sevenDays, .thirtyDays:
            .date
        }
    }

    /// Tick positions are elapsed-time positions, keeping their spacing stable
    /// even when the selected range crosses a daylight-saving transition.
    static func tickDates(for range: UsageLimitHistoryRange, now: Date) -> [Date] {
        let tickCount: Int
        switch range {
        case .oneHour: tickCount = 3
        case .sixHours, .twelveHours, .oneDay, .sevenDays: tickCount = 4
        case .thirtyDays: tickCount = 5
        }
        let cutoff = now.addingTimeInterval(-range.interval)
        return (0..<tickCount).map { index in
            cutoff.addingTimeInterval(range.interval * Double(index) / Double(tickCount - 1))
        }
    }

    static func label(
        for date: Date,
        range: UsageLimitHistoryRange,
        locale: Locale = L10n.locale
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = .autoupdatingCurrent
        switch labelStyle(for: range) {
        case .time:
            formatter.setLocalizedDateFormatFromTemplate("HHmm")
        case .dateAndTime:
            formatter.setLocalizedDateFormatFromTemplate("MMMdHHmm")
        case .date:
            formatter.setLocalizedDateFormatFromTemplate("MMMd")
        }
        return formatter.string(from: date)
    }
}

struct UsageLimitHistoryChart: View {
    let observations: [UsageLimitSnapshot]
    let range: UsageLimitHistoryRange
    let now: Date

    var body: some View {
        GeometryReader { _ in
            let cutoff = now.addingTimeInterval(-range.interval)
            let ticks = UsageLimitHistoryChartAxis.tickDates(for: range, now: now)
            let segments = UsageLimitHistoryTimeline.segments(observations)
            Canvas { context, size in
                let chartRect = CGRect(
                    x: 30,
                    y: 8,
                    width: max(1, size.width - 34),
                    height: max(1, size.height - 28)
                )
                drawGrid(in: &context, chartRect: chartRect)
                for tick in ticks {
                    let x = xPosition(tick, cutoff: cutoff, in: chartRect)
                    var grid = Path()
                    grid.move(to: CGPoint(x: x, y: chartRect.minY))
                    grid.addLine(to: CGPoint(x: x, y: chartRect.maxY))
                    context.stroke(grid, with: .color(.secondary.opacity(0.16)), lineWidth: 1)
                }

                var plotContext = context
                plotContext.clip(to: Path(chartRect))
                for segment in segments where !segment.isEmpty {
                    drawSegment(
                        segment,
                        in: &plotContext,
                        cutoff: cutoff,
                        chartRect: chartRect
                    )
                }

                for (index, tick) in ticks.enumerated() {
                    let x = xPosition(tick, cutoff: cutoff, in: chartRect)
                    let anchor: UnitPoint = index == 0 ? .leading : index == ticks.count - 1 ? .trailing : .center
                    context.draw(
                        Text(UsageLimitHistoryChartAxis.label(for: tick, range: range))
                            .font(.caption2)
                            .foregroundStyle(.secondary),
                        at: CGPoint(x: x, y: size.height - 8),
                        anchor: anchor
                    )
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("quota_chart_a11y"))
    }

    private func drawGrid(in context: inout GraphicsContext, chartRect: CGRect) {
        for level in [0.0, 25.0, 50.0, 75.0, 100.0] {
            let y = yPosition(level, in: chartRect)
            var grid = Path()
            grid.move(to: CGPoint(x: chartRect.minX, y: y))
            grid.addLine(to: CGPoint(x: chartRect.maxX, y: y))
            context.stroke(grid, with: .color(.secondary.opacity(0.22)), lineWidth: 1)
            context.draw(
                Text("\(Int(level))%").font(.caption2).foregroundStyle(.secondary),
                at: CGPoint(x: 13, y: y)
            )
        }
    }

    private func drawSegment(
        _ segment: [UsageLimitSnapshot],
        in context: inout GraphicsContext,
        cutoff: Date,
        chartRect: CGRect
    ) {
        var path = Path()
        var hasPoint = false
        for observation in segment {
            guard observation.lastObservedAt <= now else { continue }
            let start = CGPoint(
                x: xPosition(observation.observedAt, cutoff: cutoff, in: chartRect),
                y: yPosition(observation.remainingPercent, in: chartRect)
            )
            let end = CGPoint(
                x: xPosition(observation.lastObservedAt, cutoff: cutoff, in: chartRect),
                y: yPosition(observation.remainingPercent, in: chartRect)
            )
            if hasPoint { path.addLine(to: start) } else {
                path.move(to: start)
                hasPoint = true
            }
            path.addLine(to: end)
        }
        context.stroke(path, with: .color(.accentColor), lineWidth: 2)

        for observation in segment {
            for date in [observation.observedAt, observation.lastObservedAt]
                where date >= cutoff && date <= now {
                let point = CGPoint(
                    x: xPosition(date, cutoff: cutoff, in: chartRect),
                    y: yPosition(observation.remainingPercent, in: chartRect)
                )
                context.fill(
                    Path(ellipseIn: CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5)),
                    with: .color(.accentColor)
                )
            }
        }
    }

    /// Deliberately leaves values outside 0...1 untouched. Canvas clips the
    /// real line to the plot rectangle, which avoids inventing a cutoff value.
    private func xPosition(_ date: Date, cutoff: Date, in rect: CGRect) -> CGFloat {
        let span = max(1, now.timeIntervalSince(cutoff))
        return rect.minX + CGFloat(date.timeIntervalSince(cutoff) / span) * rect.width
    }

    private func yPosition(_ remaining: Double, in rect: CGRect) -> CGFloat {
        rect.maxY - CGFloat(min(100, max(0, remaining)) / 100) * rect.height
    }
}
