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
        let padding: CGFloat = 4
        let normalized = (temp - range.min) / (range.max - range.min)
        return padding + (1.0 - CGFloat(normalized)) * (height - padding * 2)
    }

    private func yPositionForFanSpeed(_ percentage: Double, height: CGFloat) -> CGFloat {
        let padding: CGFloat = 4
        let normalized = percentage / 100.0
        return padding + (1.0 - CGFloat(normalized)) * (height - padding * 2)
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

        VStack(spacing: 2) {
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
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
        }
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

            func xPosition(_ date: Date) -> CGFloat {
                CGFloat(date.timeIntervalSince(startTime) / totalDuration) * size.width
            }

            func isGap(before index: Int) -> Bool {
                index > 0 && sampled[index].timestamp.timeIntervalSince(sampled[index - 1].timestamp) > gapThreshold
            }

            // Draw thermal pressure background as merged segments by pressure state, leaving gaps empty
            func fillSegment(from start: CGFloat, to end: CGFloat, pressure: ThermalPressure) {
                let rect = CGRect(x: start, y: 0, width: end - start, height: size.height)
                context.fill(Path(rect), with: .color(pressure.color.opacity(0.3)))
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

            // Draw temperature line, broken at gaps
            var tempPath = Path()
            var startNewSubpath = true

            for (i, entry) in sampled.enumerated() {
                guard let temp = entry.temperature else { continue }

                let point = CGPoint(
                    x: xPosition(entry.timestamp),
                    y: yPositionForTemperature(temp, range: range, height: size.height)
                )

                if startNewSubpath || isGap(before: i) {
                    tempPath.move(to: point)
                    startNewSubpath = false
                } else {
                    tempPath.addLine(to: point)
                }
            }

            if let temp = latest?.temperature {
                let y = yPositionForTemperature(temp, range: range, height: size.height)
                tempPath.addLine(to: CGPoint(x: size.width, y: y))
            }

            context.stroke(tempPath, with: .color(.primary.opacity(0.8)), lineWidth: 1.5)

            // Draw fan speed line (if data available)
            let fanColor = Color.cyan
            if showFan {
                var fanPath = Path()
                var startNewFanSubpath = true

                for (i, entry) in sampled.enumerated() {
                    guard let fan = entry.fanSpeed else { continue }

                    let point = CGPoint(
                        x: xPosition(entry.timestamp),
                        y: yPositionForFanSpeed(fan, height: size.height)
                    )

                    if startNewFanSubpath || isGap(before: i) {
                        fanPath.move(to: point)
                        startNewFanSubpath = false
                    } else {
                        fanPath.addLine(to: point)
                    }
                }

                if let fan = latest?.fanSpeed {
                    let y = yPositionForFanSpeed(fan, height: size.height)
                    fanPath.addLine(to: CGPoint(x: size.width, y: y))
                }

                context.stroke(
                    fanPath,
                    with: .color(fanColor.opacity(0.5)),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 2])
                )

                // Current fan speed point (smaller)
                if let fan = latest?.fanSpeed {
                    let y = yPositionForFanSpeed(fan, height: size.height)
                    let circle = Path(ellipseIn: CGRect(x: size.width - 3, y: y - 3, width: 6, height: 6))
                    context.fill(circle, with: .color(fanColor.opacity(0.7)))
                }
            }

            // Draw speed limit line (shares the 0-100% scale with the fan speed)
            let speedColor = Color.blue
            if showSpeed {
                var speedPath = Path()
                var startNewSpeedSubpath = true

                for (i, entry) in sampled.enumerated() {
                    guard let speed = entry.speedLimit else { continue }

                    let point = CGPoint(
                        x: xPosition(entry.timestamp),
                        y: yPositionForFanSpeed(speed, height: size.height)
                    )

                    if startNewSpeedSubpath || isGap(before: i) {
                        speedPath.move(to: point)
                        startNewSpeedSubpath = false
                    } else {
                        speedPath.addLine(to: point)
                    }
                }

                if let speed = latest?.speedLimit {
                    let y = yPositionForFanSpeed(speed, height: size.height)
                    speedPath.addLine(to: CGPoint(x: size.width, y: y))
                }

                context.stroke(speedPath, with: .color(speedColor.opacity(0.8)), lineWidth: 1.5)
            }

            // Current temperature point
            if let temp = latest?.temperature {
                let y = yPositionForTemperature(temp, range: range, height: size.height)
                let circle = Path(ellipseIn: CGRect(x: size.width - 4, y: y - 4, width: 8, height: 8))
                context.fill(circle, with: .color(.primary))
            }

            // Temperature range labels (left side)
            let labelStyle = Font.system(size: 8)
            let labelColor = Color.secondary.opacity(0.8)
            let maxLabel = Text("\(Int(range.max))°").font(labelStyle).foregroundColor(labelColor)
            let minLabel = Text("\(Int(range.min))°").font(labelStyle).foregroundColor(labelColor)
            context.draw(maxLabel, at: CGPoint(x: 4, y: 4), anchor: .topLeading)
            context.draw(minLabel, at: CGPoint(x: 4, y: size.height - 4), anchor: .bottomLeading)

            // Fan speed and speed limit range labels (right side)
            if showFan || showSpeed {
                let percentColor = showFan ? fanColor : speedColor
                let fanMaxLabel = Text("100%").font(labelStyle).foregroundColor(percentColor.opacity(0.8))
                let fanMinLabel = Text("0%").font(labelStyle).foregroundColor(percentColor.opacity(0.8))
                context.draw(fanMaxLabel, at: CGPoint(x: size.width - 4, y: 4), anchor: .topTrailing)
                context.draw(fanMinLabel, at: CGPoint(x: size.width - 4, y: size.height - 4), anchor: .bottomTrailing)
            }

            // Hover indicator
            if let location = hoverLocation, let result = entryAt(x: location.x, width: size.width, in: sampled) {
                let entry = result.entry
                let hoverX = result.xPosition

                var linePath = Path()
                linePath.move(to: CGPoint(x: hoverX, y: 0))
                linePath.addLine(to: CGPoint(x: hoverX, y: size.height))
                context.stroke(linePath, with: .color(.primary.opacity(0.3)), lineWidth: 1)

                // Temperature hover point
                if let temp = entry.temperature {
                    let y = yPositionForTemperature(temp, range: range, height: size.height)
                    let circle = Path(ellipseIn: CGRect(x: hoverX - 4, y: y - 4, width: 8, height: 8))
                    context.fill(circle, with: .color(entry.pressure.color))
                    context.stroke(circle, with: .color(.primary), lineWidth: 1.5)
                }

                // Fan speed hover point (smaller, subtler)
                if showFan, let fan = entry.fanSpeed {
                    let y = yPositionForFanSpeed(fan, height: size.height)
                    let circle = Path(ellipseIn: CGRect(x: hoverX - 3, y: y - 3, width: 6, height: 6))
                    context.fill(circle, with: .color(fanColor.opacity(0.8)))
                    context.stroke(circle, with: .color(.primary.opacity(0.6)), lineWidth: 1)
                }
            }
        }
        .frame(height: 70)
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
}
