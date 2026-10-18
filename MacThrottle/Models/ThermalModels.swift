import Foundation
import SwiftUI

enum ThermalPressure: String, Codable {
    case nominal
    case moderate
    case heavy
    case critical
    case unknown

    var displayName: String {
        switch self {
        case .nominal: return "Nominal"
        case .moderate: return "Moderate"
        case .heavy: return "Heavy"
        case .critical: return "Critical"
        case .unknown: return "Unknown"
        }
    }

    var isThrottling: Bool {
        switch self {
        case .heavy, .critical:
            return true
        default:
            return false
        }
    }

    var color: Color {
        switch self {
        case .nominal: return .green
        case .moderate: return .yellow
        case .heavy: return .orange
        case .critical: return .red
        case .unknown: return .gray
        }
    }

    /// Ordering used to keep the worst state when history is aggregated.
    var severity: Int {
        switch self {
        case .unknown: return 0
        case .nominal: return 1
        case .moderate: return 2
        case .heavy: return 3
        case .critical: return 4
        }
    }
}

enum HistoryRange: String, CaseIterable, Identifiable {
    case tenMinutes = "10m"
    case oneHour = "1h"
    case sixHours = "6h"
    case day = "24h"

    var id: String { rawValue }

    var duration: TimeInterval {
        switch self {
        case .tenMinutes: return 600
        case .oneHour: return 3600
        case .sixHours: return 6 * 3600
        case .day: return 24 * 3600
        }
    }
}

/// Speed limit ranges for the statistics breakdown.
enum SpeedBand: CaseIterable {
    case full
    case above90
    case above80
    case above70
    case above60
    case below60

    init(speed: Double) {
        switch speed {
        case 95...: self = .full
        case 90..<95: self = .above90
        case 80..<90: self = .above80
        case 70..<80: self = .above70
        case 60..<70: self = .above60
        default: self = .below60
        }
    }

    var title: String {
        switch self {
        case .full: return "Full speed"
        case .above90: return "90\u{2013}95%"
        case .above80: return "80\u{2013}90%"
        case .above70: return "70\u{2013}80%"
        case .above60: return "60\u{2013}70%"
        case .below60: return "Below 60%"
        }
    }

    var detail: String? {
        self == .full ? "(\u{2265}95%)" : nil
    }

    var color: Color {
        switch self {
        case .full: return .green
        case .above90: return .yellow
        case .above80: return .orange
        case .above70: return .red
        case .above60: return .pink
        case .below60: return .purple
        }
    }
}

struct SpeedStatistics {
    let bandDurations: [SpeedBand: TimeInterval]
    let totalDuration: TimeInterval
    let lowest: Double
    let lowestDuration: TimeInterval  // Time spent at the lowest value (whole percent)

    /// Time spent in each speed band and at the lowest speed limit.
    /// Gaps longer than `maxGap` (sleep, app not running) are not counted.
    init?(entries: [HistoryEntry], maxGap: TimeInterval, now: Date = Date()) {
        var bandDurations: [SpeedBand: TimeInterval] = [:]
        var total: TimeInterval = 0
        var lowest: Double?
        var lowestDuration: TimeInterval = 0

        for (index, entry) in entries.enumerated() {
            guard let speed = entry.speedLimit?.rounded() else { continue }
            if speed < lowest ?? .infinity {
                lowest = speed
                lowestDuration = 0
            }
            // The last sample counts up to now
            let end = index + 1 < entries.count ? entries[index + 1].timestamp : now
            let duration = end.timeIntervalSince(entry.timestamp)
            guard duration <= maxGap else { continue }
            total += duration
            bandDurations[SpeedBand(speed: speed), default: 0] += duration
            if speed == lowest {
                lowestDuration += duration
            }
        }

        guard let lowest, total > 0 else { return nil }
        self.bandDurations = bandDurations
        self.totalDuration = total
        self.lowest = lowest
        self.lowestDuration = lowestDuration
    }
}

struct HistoryEntry {
    let pressure: ThermalPressure
    let temperature: Double?
    let fanSpeed: Double?  // Percentage 0-100%
    let speedLimit: Double?  // Percentage 0-100% of the max CPU clock
    let timestamp: Date
}
