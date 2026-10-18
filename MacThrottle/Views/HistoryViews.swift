import SwiftUI

private struct WidthPreferenceKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct HistoryGraphView: View {
    // MARK: - Constants
    private static let maxPoints = 300
    private static let minTemperatureBound: Double = 30
    private static let maxTemperatureBound: Double = 110
    private static let temperaturePadding: Double = 5
    private static let graphHeight: CGFloat = 80
    private static let pressureStripHeight: CGFloat = 5
    private static let plotTopPadding: CGFloat = 8
    private static let plotBottomPadding: CGFloat = 2

    // Activity Monitor-style series colors on a neutral background
    static let temperatureColor = Color.orange
    static let speedColor = Color.blue
    static let fanColor = Color.gray

    // MARK: - Properties
    let history: [HistoryEntry]
    var showFanSpeed: Bool = true
    /// Samples further apart than this are drawn as a gap (sleep, app not running).
    var maxGap: TimeInterval = 10
    @State private var hoverLocation: CGPoint?

    private var historyDuration: TimeInterval {
        guard let first = history.first else { return 0 }
        return Date().timeIntervalSince(first.timestamp)
    }

    /// Time covered by one downsampled point (0 when the history is not downsampled).
    private var bucketDuration: TimeInterval {
        guard history.count > Self.maxPoints, let first = history.first, let last = history.last else { return 0 }
        return last.timestamp.timeIntervalSince(first.timestamp) / Double(Self.maxPoints)
    }

    private var isAggregated: Bool {
        bucketDuration > 0
    }

    /// Consecutive points further apart than this are separated by a gap.
    private var gapThreshold: TimeInterval {
        max(maxGap, bucketDuration * 2)
    }

    /// Aggregates the history into at most `maxPoints` time buckets. Each bucket keeps the worst
    /// pressure and the peak temperature and fan speed, so short throttling spikes stay visible.
    private func downsample() -> [HistoryEntry] {
        let bucketDuration = bucketDuration
        guard bucketDuration > 0, let first = history.first else { return history }

        var result: [HistoryEntry] = []
        result.reserveCapacity(Self.maxPoints)
        var current: HistoryEntry?
        var currentBucket = -1

        for entry in history {
            let bucket = min(Int(entry.timestamp.timeIntervalSince(first.timestamp) / bucketDuration), Self.maxPoints - 1)
            if bucket != currentBucket, let finished = current {
                result.append(finished)
                current = nil
            }
            currentBucket = bucket

            if let existing = current {
                current = HistoryEntry(
                    pressure: entry.pressure.severity > existing.pressure.severity ? entry.pressure : existing.pressure,
                    temperature: peak(existing.temperature, entry.temperature),
                    fanSpeed: peak(existing.fanSpeed, entry.fanSpeed),
                    speedLimit: lowest(existing.speedLimit, entry.speedLimit),
                    timestamp: existing.timestamp
                )
            } else {
                current = entry
            }
        }
        if let current {
            result.append(current)
        }

        return result
    }

    private func peak(_ lhs: Double?, _ rhs: Double?) -> Double? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        return max(lhs, rhs)
    }

    private func lowest(_ lhs: Double?, _ rhs: Double?) -> Double? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        return min(lhs, rhs)
    }

    private func temperatureRange(_ sampled: [HistoryEntry]) -> (min: Double, max: Double) {
        let temps = sampled.compactMap { $0.temperature }
        guard !temps.isEmpty else { return (Self.minTemperatureBound, 100) }
        let minTemp = max(Self.minTemperatureBound, (temps.min() ?? Self.minTemperatureBound) - Self.temperaturePadding)
        let maxTemp = min(Self.maxTemperatureBound, (temps.max() ?? 100) + Self.temperaturePadding)
        return (minTemp, maxTemp)
    }

    private func hasSpeedData(_ sampled: [HistoryEntry]) -> Bool {
        sampled.contains { $0.speedLimit != nil }
    }

    private func hasFanData(_ sampled: [HistoryEntry]) -> Bool {
        showFanSpeed && sampled.contains { $0.fanSpeed != nil }
    }

    private func yPositionForTemperature(
        _ temp: Double,
        range: (min: Double, max: Double),
        height: CGFloat
    ) -> CGFloat {
        let normalized = (temp - range.min) / (range.max - range.min)
        return Self.plotTopPadding + (1.0 - CGFloat(normalized)) * (height - Self.plotTopPadding - Self.plotBottomPadding)
    }

    /// Y position on the shared 0-100% scale (fan speed and speed limit).
    private func yPositionForPercentage(_ percentage: Double, height: CGFloat) -> CGFloat {
        let normalized = percentage / 100.0
        return Self.plotTopPadding + (1.0 - CGFloat(normalized)) * (height - Self.plotTopPadding - Self.plotBottomPadding)
    }

    private func entryAt(
        x: CGFloat,
        width: CGFloat,
        in sampled: [HistoryEntry]
    ) -> (entry: HistoryEntry, xPosition: CGFloat)? {
        guard sampled.count >= 2, let first = sampled.first else { return nil }
        let totalDuration = Date().timeIntervalSince(first.timestamp)
        guard totalDuration > 0 else { return nil }

        let fraction = x / width
        let targetTime = first.timestamp.addingTimeInterval(totalDuration * fraction)

        // Find the closest entry to the target time
        guard let closest = sampled.min(by: {
            abs($0.timestamp.timeIntervalSince(targetTime)) < abs($1.timestamp.timeIntervalSince(targetTime))
        }) else { return nil }

        // Nothing to show while hovering over a gap
        guard abs(closest.timestamp.timeIntervalSince(targetTime)) <= gapThreshold else { return nil }

        let entryX = CGFloat(closest.timestamp.timeIntervalSince(first.timestamp) / totalDuration) * width
        return (closest, entryX)
    }

    @State private var graphWidth: CGFloat = 220

    var body: some View {
        let sampled = downsample()

        VStack(spacing: 3) {
            graphView(sampled)
                .background(GeometryReader { geo in
                    Color.clear.preference(key: WidthPreferenceKey.self, value: geo.size.width)
                })
                .onPreferenceChange(WidthPreferenceKey.self) { graphWidth = $0 }
                .overlay(alignment: .topTrailing) {
                    tooltipView(sampled)
                        .allowsHitTesting(false)
                }

            HStack {
                Text(formatTimeAgo(historyDuration))
                Spacer()
                Text("now")
            }
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                legendItem("Temp", color: Self.temperatureColor)
                if hasSpeedData(sampled) {
                    legendItem("Speed Limit", color: Self.speedColor)
                }
                if hasFanData(sampled) {
                    legendItem("Fan", color: Self.fanColor, dashed: true)
                }
                Spacer(minLength: 0)
                pressureLegend
            }
        }
        .font(.system(size: 9))
    }

    private func legendItem(_ title: String, color: Color, dashed: Bool = false) -> some View {
        HStack(spacing: 3) {
            if dashed {
                HStack(spacing: 1) {
                    ForEach(0..<2, id: \.self) { _ in
                        Capsule().fill(color).frame(width: 3, height: 2)
                    }
                }
            } else {
                Circle().fill(color).frame(width: 6, height: 6)
            }
            Text(title)
        }
    }

    private var pressureLegend: some View {
        HStack(spacing: 3) {
            HStack(spacing: 0) {
                ForEach([ThermalPressure.nominal, .moderate, .heavy, .critical], id: \.self) { pressure in
                    Rectangle().fill(pressure.color).frame(width: 3, height: 5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 1))
            Text("Pressure")
        }
        .help("The strip under the graph shows the thermal pressure: green Nominal, yellow Moderate, "
            + "orange Heavy, red Critical")
    }

    private func graphView(_ sampled: [HistoryEntry]) -> some View {
        let latest = history.last
        let range = temperatureRange(sampled)
        let showFan = hasFanData(sampled)
        let showSpeed = hasSpeedData(sampled)
        let gapThreshold = gapThreshold
        // How far a point before a gap extends to the right
        let pointDuration = max(maxGap / 5, bucketDuration)

        return Canvas { context, size in
            guard sampled.count >= 2 else { return }

            guard let firstEntry = sampled.first else { return }
            let startTime = firstEntry.timestamp
            let endTime = Date()
            let totalDuration = endTime.timeIntervalSince(startTime)

            guard totalDuration > 0 else { return }

            // The plot sits above a thin thermal pressure strip
            let plotHeight = size.height - Self.pressureStripHeight

            func xPosition(_ date: Date) -> CGFloat {
                CGFloat(date.timeIntervalSince(startTime) / totalDuration) * size.width
            }

            func isGap(before index: Int) -> Bool {
                index > 0 && sampled[index].timestamp.timeIntervalSince(sampled[index - 1].timestamp) > gapThreshold
            }

            /// Splits a series into continuous runs of points, broken at gaps; the last run reaches "now".
            func runs(_ value: (HistoryEntry) -> Double?, y: (Double) -> CGFloat) -> [[CGPoint]] {
                var result: [[CGPoint]] = []
                var current: [CGPoint] = []
                for (i, entry) in sampled.enumerated() {
                    guard let v = value(entry) else { continue }
                    if isGap(before: i), !current.isEmpty {
                        result.append(current)
                        current = []
                    }
                    current.append(CGPoint(x: xPosition(entry.timestamp), y: y(v)))
                }
                if let last = latest.flatMap(value) {
                    current.append(CGPoint(x: size.width, y: y(last)))
                }
                if !current.isEmpty {
                    result.append(current)
                }
                return result
            }

            func linePath(_ points: [CGPoint]) -> Path {
                var path = Path()
                path.addLines(points)
                return path
            }

            // Neutral background with light grid lines
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.primary.opacity(0.04)))
            for fraction in [0.25, 0.5, 0.75] {
                let y = yPositionForPercentage(fraction * 100, height: plotHeight)
                var grid = Path()
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(grid, with: .color(.primary.opacity(0.08)), lineWidth: 0.5)
            }

            // Draw thermal pressure strip as merged segments by pressure state, leaving gaps empty
            func fillSegment(from start: CGFloat, to end: CGFloat, pressure: ThermalPressure) {
                let rect = CGRect(x: start, y: plotHeight, width: end - start, height: Self.pressureStripHeight)
                context.fill(Path(rect), with: .color(pressure.color))
            }

            var currentPressure = sampled[0].pressure
            var segmentStart: CGFloat = 0

            for i in 1..<sampled.count {
                let entry = sampled[i]
                let x = xPosition(entry.timestamp)

                if isGap(before: i) {
                    let previousEnd = xPosition(sampled[i - 1].timestamp.addingTimeInterval(pointDuration))
                    fillSegment(from: segmentStart, to: previousEnd, pressure: currentPressure)
                    currentPressure = entry.pressure
                    segmentStart = x
                } else if entry.pressure != currentPressure {
                    fillSegment(from: segmentStart, to: x, pressure: currentPressure)
                    currentPressure = entry.pressure
                    segmentStart = x
                }
            }
            // Draw final segment to end
            fillSegment(from: segmentStart, to: size.width, pressure: currentPressure)

            // Temperature as a filled area, broken at gaps
            let tempRuns = runs({ $0.temperature }, y: { yPositionForTemperature($0, range: range, height: plotHeight) })
            for run in tempRuns {
                guard let first = run.first, let last = run.last else { continue }
                var area = linePath(run)
                area.addLine(to: CGPoint(x: last.x, y: plotHeight))
                area.addLine(to: CGPoint(x: first.x, y: plotHeight))
                area.closeSubpath()
                context.fill(area, with: .color(Self.temperatureColor.opacity(0.25)))
                context.stroke(linePath(run), with: .color(Self.temperatureColor), lineWidth: 1.25)
            }

            // Fan speed as a dashed line (if data available)
            if showFan {
                for run in runs({ $0.fanSpeed }, y: { yPositionForPercentage($0, height: plotHeight) }) {
                    context.stroke(
                        linePath(run),
                        with: .color(Self.fanColor.opacity(0.8)),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 2])
                    )
                }
            }

            // Speed limit line (shares the 0-100% scale with the fan speed)
            if showSpeed {
                for run in runs({ $0.speedLimit }, y: { yPositionForPercentage($0, height: plotHeight) }) {
                    context.stroke(linePath(run), with: .color(Self.speedColor), lineWidth: 1.5)
                }
            }

            // Current temperature point
            if let temp = latest?.temperature {
                let y = yPositionForTemperature(temp, range: range, height: plotHeight)
                let circle = Path(ellipseIn: CGRect(x: size.width - 4, y: y - 4, width: 8, height: 8))
                context.fill(circle, with: .color(Self.temperatureColor))
            }

            // Temperature range labels (left side)
            let labelStyle = Font.system(size: 8)
            let labelColor = Color.secondary
            let maxLabel = Text("\(Int(range.max))°").font(labelStyle).foregroundColor(labelColor)
            let minLabel = Text("\(Int(range.min))°").font(labelStyle).foregroundColor(labelColor)
            context.draw(maxLabel, at: CGPoint(x: 4, y: 1), anchor: .topLeading)
            context.draw(minLabel, at: CGPoint(x: 4, y: plotHeight - 2), anchor: .bottomLeading)

            // Hover indicator
            if let location = hoverLocation, let result = entryAt(x: location.x, width: size.width, in: sampled) {
                let entry = result.entry
                let hoverX = result.xPosition

                var hoverLine = Path()
                hoverLine.move(to: CGPoint(x: hoverX, y: 0))
                hoverLine.addLine(to: CGPoint(x: hoverX, y: size.height))
                context.stroke(hoverLine, with: .color(.primary.opacity(0.3)), lineWidth: 1)

                func hoverPoint(y: CGFloat, color: Color, radius: CGFloat) {
                    let circle = Path(ellipseIn: CGRect(x: hoverX - radius, y: y - radius, width: radius * 2, height: radius * 2))
                    context.fill(circle, with: .color(color))
                    context.stroke(circle, with: .color(.primary.opacity(0.6)), lineWidth: 1)
                }

                if let temp = entry.temperature {
                    hoverPoint(y: yPositionForTemperature(temp, range: range, height: plotHeight),
                               color: Self.temperatureColor, radius: 4)
                }
                if showSpeed, let speed = entry.speedLimit {
                    hoverPoint(y: yPositionForPercentage(speed, height: plotHeight), color: Self.speedColor, radius: 3)
                }
                if showFan, let fan = entry.fanSpeed {
                    hoverPoint(y: yPositionForPercentage(fan, height: plotHeight), color: Self.fanColor, radius: 3)
                }
            }
        }
        .frame(height: Self.graphHeight)
        .drawingGroup()
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3), lineWidth: 1))
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                hoverLocation = location
            case .ended:
                hoverLocation = nil
            }
        }
    }

    @ViewBuilder
    private func tooltipView(_ sampled: [HistoryEntry]) -> some View {
        if let location = hoverLocation, let result = entryAt(x: location.x, width: graphWidth, in: sampled) {
            let entry = result.entry
            if let temp = entry.temperature {
                let timeAgo = Date().timeIntervalSince(entry.timestamp)
                let timeStr = timeAgo < 60 ? "\(Int(timeAgo))s ago" : formatTimeAgo(timeAgo)
                // Aggregated points show the peak values of their time bucket
                let peakStr = isAggregated ? "max " : ""
                let fanStr = showFanSpeed ? entry.fanSpeed.map { " • Fan \(Int($0))%" } ?? "" : ""
                // Aggregated points show the lowest speed limit of their time bucket
                let speedStr = entry.speedLimit.map { " • Speed \(isAggregated ? "min " : "")\(Int($0.rounded()))%" } ?? ""
                let label = "\(peakStr)\(Int(temp))° • \(entry.pressure.displayName)\(speedStr)\(fanStr) • \(timeStr)"
                if #available(macOS 26.0, *) {
                    Text(label)
                        .font(.system(size: 8, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 6))
                        .padding(4)
                } else {
                    Text(label)
                        .font(.system(size: 8, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .padding(4)
                }
            }
        }
    }

    private func formatTimeAgo(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        if minutes < 60 {
            return "\(minutes)m ago"
        } else {
            let hours = minutes / 60
            let mins = minutes % 60
            if mins == 0 {
                return "\(hours)h ago"
            }
            return "\(hours)h \(mins)m ago"
        }
    }
}

struct TimeBreakdownView: View {
    let timeInEachState: [(pressure: ThermalPressure, duration: TimeInterval)]
    let totalDuration: TimeInterval

    private static let allStates: [ThermalPressure] = [.nominal, .moderate, .heavy, .critical]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Self.allStates, id: \.self) { pressure in
                let duration = timeInEachState.first { $0.pressure == pressure }?.duration ?? 0
                HStack {
                    Circle()
                        .fill(pressure.color)
                        .frame(width: 8, height: 8)
                    HStack(spacing: 2) {
                        Text(pressure.displayName)
                        if pressure.isThrottling {
                            Text("(throttling)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(formatDuration(duration))
                        .foregroundStyle(.secondary)
                    if totalDuration > 0 {
                        let percentage = (duration / totalDuration * 100).rounded()
                        Text("(\(Int(percentage))%)")
                            .foregroundStyle(.secondary)
                            .frame(width: 45, alignment: .trailing)
                    }
                }
                .font(.caption)
            }
        }
    }

}

struct SpeedBreakdownView: View {
    let statistics: SpeedStatistics

    var body: some View {
        let fullDuration = statistics.bandDurations[.full] ?? 0

        VStack(alignment: .leading, spacing: 4) {
            row(color: SpeedBand.full.color, duration: fullDuration) {
                Text(SpeedBand.full.title)
                Text(SpeedBand.full.detail ?? "")
                    .foregroundStyle(.secondary)
            }
            row(color: .orange, duration: statistics.totalDuration - fullDuration) {
                Text("Limited")
                Text("(<95%)")
                    .foregroundStyle(.secondary)
            }
            // Breakdown of the limited time by speed band
            ForEach(SpeedBand.allCases.filter { $0 != .full }, id: \.self) { band in
                row(color: band.color, duration: statistics.bandDurations[band] ?? 0, indented: true) {
                    Text(band.title)
                }
            }
            row(color: colorForSpeedLimit(statistics.lowest), duration: statistics.lowestDuration) {
                Text("Lowest")
                Text("\(Int(statistics.lowest))%")
                    .fontWeight(.semibold)
            }
        }
        .font(.caption)
    }

    private func row<Title: View>(
        color: Color,
        duration: TimeInterval,
        indented: Bool = false,
        @ViewBuilder title: () -> Title
    ) -> some View {
        HStack {
            Circle()
                .fill(color)
                .frame(width: indented ? 6 : 8, height: indented ? 6 : 8)
                .frame(width: 8)
            HStack(spacing: 2) {
                title()
            }
            .foregroundStyle(indented ? .secondary : .primary)
            Spacer()
            Text(formatDuration(duration))
                .foregroundStyle(.secondary)
            Text(shareText(duration))
                .foregroundStyle(.secondary)
                .frame(width: 45, alignment: .trailing)
        }
        .padding(.leading, indented ? 14 : 0)
    }

    /// Short but non-zero times show "<1%" instead of a misleading "0%".
    private func shareText(_ duration: TimeInterval) -> String {
        let share = duration / statistics.totalDuration * 100
        if duration > 0 && share < 0.5 {
            return "(<1%)"
        }
        return "(\(Int(share.rounded()))%)"
    }
}

private func formatDuration(_ duration: TimeInterval) -> String {
    let totalSeconds = Int(duration)
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let seconds = totalSeconds % 60

    if hours > 0 {
        return String(format: "%dh %dm", hours, minutes)
    } else if minutes > 0 {
        return String(format: "%dm %ds", minutes, seconds)
    } else {
        return String(format: "%ds", seconds)
    }
}
