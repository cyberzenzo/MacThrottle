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

struct HistoryEntry {
    let pressure: ThermalPressure
    let temperature: Double?
    let fanSpeed: Double?  // Percentage 0-100%
    let timestamp: Date
}
