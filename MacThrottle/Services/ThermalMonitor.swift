import Foundation
import SwiftUI
import UserNotifications

@Observable
final class ThermalMonitor {
    // MARK: - Constants
    private static let historyDurationSeconds: TimeInterval = 24 * 3600  // 24 hours
    private static let pollIntervalSeconds: TimeInterval = 2.0
    // Samples further apart than this mean the Mac slept or the app was not running
    static let maxSampleGapSeconds: TimeInterval = 10
    private static let compactionIntervalSeconds: TimeInterval = 3600

    // MARK: - State
    private(set) var pressure: ThermalPressure = .unknown
    private(set) var temperature: Double?
    private(set) var temperatureSource: String?  // SMC key or "HID"
    private(set) var fanSpeed: Double?  // Percentage 0-100%
    private(set) var hasFans: Bool = false
    private(set) var cpuSpeed: CPUSpeedReading?
    private(set) var availableCPUs: Int?
    let totalCPUs: Int? = CPUSpeedReader.sysctlInt("hw.ncpu")
    private(set) var history: [HistoryEntry] = []
    private var timer: Timer?
    private var previousPressure: ThermalPressure = .unknown
    private let store = HistoryStore()
    private var lastCompaction = Date()

    // Notification settings
    var notifyOnHeavy: Bool = UserDefaults.standard.object(forKey: "notifyOnHeavy") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notifyOnHeavy, forKey: "notifyOnHeavy") }
    }

    var notifyOnCritical: Bool = UserDefaults.standard.object(forKey: "notifyOnCritical") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notifyOnCritical, forKey: "notifyOnCritical") }
    }

    var notifyOnRecovery: Bool = UserDefaults.standard.object(forKey: "notifyOnRecovery") as? Bool ?? false {
        didSet { UserDefaults.standard.set(notifyOnRecovery, forKey: "notifyOnRecovery") }
    }

    var notificationSound: Bool = UserDefaults.standard.object(forKey: "notificationSound") as? Bool ?? false {
        didSet { UserDefaults.standard.set(notificationSound, forKey: "notificationSound") }
    }

    // Graph settings
    var showFanSpeed: Bool = UserDefaults.standard.object(forKey: "showFanSpeed") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showFanSpeed, forKey: "showFanSpeed") }
    }

    // Menu bar settings
    // swiftlint:disable:next line_length
    var showTemperatureInMenuBar: Bool = UserDefaults.standard.object(forKey: "showTemperatureInMenuBar") as? Bool ?? false {
        didSet { UserDefaults.standard.set(showTemperatureInMenuBar, forKey: "showTemperatureInMenuBar") }
    }

    // swiftlint:disable:next line_length
    var showSpeedLimitInMenuBar: Bool = UserDefaults.standard.object(forKey: "showSpeedLimitInMenuBar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showSpeedLimitInMenuBar, forKey: "showSpeedLimitInMenuBar") }
    }

    // History settings
    var historyRange: HistoryRange = HistoryRange(
        rawValue: UserDefaults.standard.string(forKey: "historyRange") ?? ""
    ) ?? .tenMinutes {
        didSet { UserDefaults.standard.set(historyRange.rawValue, forKey: "historyRange") }
    }

    /// History entries within the selected range, oldest first.
    var visibleHistory: [HistoryEntry] {
        let cutoff = Date().addingTimeInterval(-historyRange.duration)
        let start = history.firstIndex { $0.timestamp >= cutoff } ?? history.endIndex
        return Array(history[start...])
    }

    /// Time spent in each state within the selected range, sorted by duration descending.
    /// Gaps (sleep, app not running) are not counted, so `total` is the time actually observed.
    var stateStatistics: (durations: [(pressure: ThermalPressure, duration: TimeInterval)], total: TimeInterval) {
        let entries = visibleHistory
        guard entries.count >= 2 else { return ([], 0) }

        var durations: [ThermalPressure: TimeInterval] = [:]

        for (index, entry) in entries.enumerated() {
            // The last state counts up to now
            let end = index + 1 < entries.count ? entries[index + 1].timestamp : Date()
            let duration = end.timeIntervalSince(entry.timestamp)
            guard duration <= Self.maxSampleGapSeconds else { continue }
            durations[entry.pressure, default: 0] += duration
        }

        let sorted = durations.map { (pressure: $0.key, duration: $0.value) }
            .sorted { $0.duration > $1.duration }
        return (sorted, sorted.reduce(0) { $0 + $1.duration })
    }

    /// Time the CPU speed was limited within the selected range, and the lowest speed limit.
    /// Gaps (sleep, app not running) are not counted.
    var speedStatistics: SpeedStatistics? {
        let entries = visibleHistory
        var limited: TimeInterval = 0
        var total: TimeInterval = 0
        var lowest: Double?
        var lowestDuration: TimeInterval = 0

        for (index, entry) in entries.enumerated() {
            guard let speed = entry.speedLimit?.rounded() else { continue }
            if speed < lowest ?? .infinity {
                lowest = speed
                lowestDuration = 0
            }
            let end = index + 1 < entries.count ? entries[index + 1].timestamp : Date()
            let duration = end.timeIntervalSince(entry.timestamp)
            guard duration <= Self.maxSampleGapSeconds else { continue }
            total += duration
            if speed == lowest {
                lowestDuration += duration
            }
            if speed < SpeedStatistics.fullSpeedThreshold {
                limited += duration
            }
        }

        guard let lowest, total > 0 else { return nil }
        return SpeedStatistics(
            limitedDuration: limited,
            totalDuration: total,
            lowest: lowest,
            lowestDuration: lowestDuration
        )
    }

    init() {
        history = store.load(newerThan: Date().addingTimeInterval(-Self.historyDurationSeconds))
        store.compact(to: history)
        requestNotificationPermission()
        startMonitoring()
    }

    deinit {
        timer?.invalidate()
    }

    private func startMonitoring() {
        // Initial read
        updateThermalState()

        timer = Timer.scheduledTimer(withTimeInterval: Self.pollIntervalSeconds, repeats: true) { [weak self] _ in
            self?.updateThermalState()
        }
    }

    private func updateThermalState() {
        let newPressure = ThermalPressureReader.shared.readPressure() ?? .unknown

        if newPressure != previousPressure {
            // Check for throttling notifications
            if shouldNotify(for: newPressure, previous: previousPressure) {
                sendThrottleNotification(pressure: newPressure)
            }

            // Check for recovery notification
            let recovered = previousPressure.isThrottling && !newPressure.isThrottling
            if notifyOnRecovery && recovered && newPressure != .unknown {
                sendRecoveryNotification()
            }

            previousPressure = newPressure
        }

        pressure = newPressure

        // Read CPU temperature (SMC primary, HID fallback)
        if let smcReading = SMCReader.shared.readCPUTemperature() {
            temperature = smcReading.value
            temperatureSource = smcReading.source
        } else if let hidReading = HIDTemperatureReader.shared.readCPUTemperature() {
            temperature = hidReading.value
            temperatureSource = hidReading.source
        } else {
            temperature = nil
            temperatureSource = nil
        }

        // Read fan speed
        if let fan = SMCReader.shared.readFanSpeed() {
            fanSpeed = fan.percentage
            if !hasFans { hasFans = true }
        }

        // Read CPU speed limit and active core count
        cpuSpeed = CPUSpeedReader.shared.read()
        availableCPUs = CPUSpeedReader.sysctlInt("hw.activecpu")

        // Record history
        let entry = HistoryEntry(
            pressure: newPressure,
            temperature: temperature,
            fanSpeed: fanSpeed,
            speedLimit: cpuSpeed?.speedLimit,
            timestamp: Date()
        )
        history.append(entry)
        store.append(entry)

        // Trim old entries (history is sorted, so only a prefix can be expired)
        let cutoff = Date().addingTimeInterval(-Self.historyDurationSeconds)
        if let firstKept = history.firstIndex(where: { $0.timestamp >= cutoff }), firstKept > 0 {
            history.removeFirst(firstKept)
        }

        // Drop expired lines from the history file once an hour
        if Date().timeIntervalSince(lastCompaction) >= Self.compactionIntervalSeconds {
            store.compact(to: history)
            lastCompaction = Date()
        }
    }

    private func shouldNotify(for pressure: ThermalPressure, previous: ThermalPressure) -> Bool {
        switch pressure {
        case .heavy:
            return notifyOnHeavy && !previous.isThrottling
        case .critical:
            return notifyOnCritical && previous != .critical
        default:
            return false
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func sendThrottleNotification(pressure: ThermalPressure) {
        let content = UNMutableNotificationContent()
        content.title = "Thermal Throttling"
        content.body = pressure == .critical
            ? "Your Mac is severely throttled!"
            : "Your Mac is being throttled (Heavy pressure)"
        if notificationSound {
            content.sound = .default
        }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    private func sendRecoveryNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Thermal Pressure Recovered"
        content.body = "Your Mac is no longer being throttled"
        if notificationSound {
            content.sound = .default
        }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }
}
