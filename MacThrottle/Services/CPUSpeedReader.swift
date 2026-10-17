import Foundation
import IOKit

struct CoreTypeSpeed {
    let name: String  // e.g. "Performance", "Efficiency", "Super"
    let coreCount: Int
    let limitMHz: Double  // Highest clock the cores reached recently
    let maxMHz: Double

    var percentage: Double {
        min(100, limitMHz / maxMHz * 100)
    }
}

struct CPUSpeedReading {
    let coreTypes: [CoreTypeSpeed]

    /// Share of the maximum CPU clock the Mac can currently use (0-100%), weighted by core count.
    var speedLimit: Double {
        let maxCapacity = coreTypes.reduce(0) { $0 + Double($1.coreCount) * $1.maxMHz }
        guard maxCapacity > 0 else { return 100 }
        let capacity = coreTypes.reduce(0) { $0 + Double($1.coreCount) * min($1.limitMHz, $1.maxMHz) }
        return capacity / maxCapacity * 100
    }
}

/// Estimates the CPU speed limit on Apple Silicon from IOReport clock-state residency.
/// macOS does not expose the throttling cap directly, but when it throttles (heat or power)
/// it stops using the top clock steps. The highest step a core type used during the last
/// few samples is therefore the clock it can currently reach.
/// Channel layout based on https://github.com/vladkens/macmon
final class CPUSpeedReader {
    nonisolated(unsafe) static let shared = CPUSpeedReader()

    private static let windowSamples = 5  // 10 s at the 2 s poll interval
    private static let minStateShare = 0.02  // Ignore clock steps used for less than 2% of active time
    private static let inactiveStates: Set<String> = ["IDLE", "DOWN", "OFF"]
    private static let minSampleInterval: TimeInterval = 1  // Shorter deltas (e.g. right after launch) are not representative

    private struct Cluster {
        let level: Int  // hw.perflevelN
        let frequencies: [Double]  // MHz, one per clock step
    }

    private let api: IOReportAPI?
    private var subscription: CFTypeRef?
    private var subscribedChannels: CFMutableDictionary?
    private var previousSample: CFDictionary?
    private var previousSampleDate = Date()
    private var clusters: [String: Cluster] = [:]
    private var recentLimits: [[Int: Double]] = []  // Per sample: perf level -> highest MHz used

    private init() {
        api = IOReportAPI()
        setUp()
    }

    /// Reads the clock steps used since the previous call. Returns nil if IOReport is unavailable.
    func read() -> CPUSpeedReading? {
        guard
            let api,
            let subscription,
            let subscribedChannels,
            let current = api.createSamples(subscription, subscribedChannels, nil)?.takeRetainedValue()
        else { return nil }

        let now = Date()
        guard now.timeIntervalSince(previousSampleDate) >= Self.minSampleInterval else { return nil }
        defer {
            previousSample = current
            previousSampleDate = now
        }
        guard
            let previousSample,
            let delta = api.createSamplesDelta(previousSample, current, nil)?.takeRetainedValue(),
            let items = (delta as NSDictionary)["IOReportChannels"] as? [NSDictionary]
        else { return nil }

        var sampleLimits: [Int: Double] = [:]
        for item in items {
            let channel = item as CFDictionary
            guard
                let name = api.channelName(channel)?.takeUnretainedValue() as String?,
                let cluster = clusters[name]
            else { continue }

            let residencies = activeResidencies(of: channel, api: api)
            guard residencies.count == cluster.frequencies.count else { continue }
            let active = Double(residencies.reduce(0, +))
            guard active > 0 else { continue }

            if let top = residencies.indices.last(where: { Double(residencies[$0]) >= active * Self.minStateShare }) {
                sampleLimits[cluster.level] = max(sampleLimits[cluster.level] ?? 0, cluster.frequencies[top])
            }
        }

        recentLimits.append(sampleLimits)
        if recentLimits.count > Self.windowSamples {
            recentLimits.removeFirst(recentLimits.count - Self.windowSamples)
        }

        let levels = Set(clusters.values.map(\.level)).sorted()
        let coreTypes: [CoreTypeSpeed] = levels.compactMap { level in
            guard
                let maxMHz = clusters.values.filter({ $0.level == level }).compactMap({ $0.frequencies.last }).max(),
                let limitMHz = recentLimits.compactMap({ $0[level] }).max()
            else { return nil }
            return CoreTypeSpeed(
                name: Self.sysctlString("hw.perflevel\(level).name") ?? "Level \(level)",
                coreCount: Self.sysctlInt("hw.perflevel\(level).logicalcpu") ?? 1,
                limitMHz: limitMHz,
                maxMHz: maxMHz
            )
        }

        return coreTypes.isEmpty ? nil : CPUSpeedReading(coreTypes: coreTypes)
    }

    private func setUp() {
        guard
            let api,
            let channels = api.copyChannelsInGroup(
                "CPU Stats" as CFString, "CPU Complex Performance States" as CFString, 0, 0, 0
            )?.takeRetainedValue()
        else { return }

        var subscribed: Unmanaged<CFMutableDictionary>?
        guard
            let subscription = api.createSubscription(nil, channels, &subscribed, 0, nil)?.takeRetainedValue(),
            let subscribedChannels = subscribed?.takeRetainedValue(),
            let first = api.createSamples(subscription, subscribedChannels, nil)?.takeRetainedValue(),
            let items = (first as NSDictionary)["IOReportChannels"] as? [NSDictionary]
        else { return }

        // Cluster channels are named like "ECPU", "PCPU", "PCPU1", "MCPU0"
        let tables = Self.readFrequencyTables()
        for item in items {
            let channel = item as CFDictionary
            guard
                let name = api.channelName(channel)?.takeUnretainedValue() as String?,
                name.range(of: #"^[A-Z]CPU\d*$"#, options: .regularExpression) != nil
            else { continue }

            let stepCount = activeResidencies(of: channel, api: api).count
            guard let frequencies = tables.first(where: { $0.count == stepCount }) else { continue }
            // "P" clusters hold the fastest cores (perflevel0), the others the second core type
            clusters[name] = Cluster(level: name.hasPrefix("P") ? 0 : 1, frequencies: frequencies)
        }

        self.subscription = subscription
        self.subscribedChannels = subscribedChannels
        previousSample = first
        previousSampleDate = Date()
    }

    private func activeResidencies(of channel: CFDictionary, api: IOReportAPI) -> [Int64] {
        (0..<api.stateCount(channel)).compactMap { index in
            let state = api.stateName(channel, index)?.takeUnretainedValue() as String? ?? ""
            return Self.inactiveStates.contains(state) ? nil : api.stateResidency(channel, index)
        }
    }

    /// CPU clock tables (MHz) from the power manager's `voltage-states*-sram` properties.
    private static func readFrequencyTables() -> [[Double]] {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("pmgr"))
        guard service != 0 else { return [] }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard
            IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
            let dict = properties?.takeRetainedValue() as? [String: Any]
        else { return [] }

        let keys = dict.keys
            .filter { $0.hasPrefix("voltage-states") && $0.hasSuffix("-sram") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        return keys.compactMap { key in
            guard let data = dict[key] as? Data, data.count >= 8 else { return nil }
            // Each step is 8 bytes: clock (UInt32), voltage (UInt32)
            let raw = stride(from: 0, to: data.count - 7, by: 8).map { offset in
                data.withUnsafeBytes { Double($0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
            }
            // CPU tables start above zero; GPU and other tables start with an off state
            guard let first = raw.first, first > 0, let top = raw.max() else { return nil }
            // Older chips store Hz, newer ones kHz
            let divisor = top > 100_000_000 ? 1_000_000.0 : 1_000.0
            return raw.map { $0 / divisor }
        }
    }

    static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

// MARK: - IOReport (private framework, loaded at runtime)

private struct IOReportAPI {
    typealias CopyChannelsInGroup = @convention(c) (
        CFString?, CFString?, UInt64, UInt64, UInt64
    ) -> Unmanaged<CFMutableDictionary>?
    typealias CreateSubscription = @convention(c) (
        UnsafeMutableRawPointer?, CFMutableDictionary,
        UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?
    ) -> Unmanaged<CFTypeRef>?
    typealias CreateSamples = @convention(c) (CFTypeRef, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    typealias CreateSamplesDelta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    typealias ChannelGetName = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    typealias StateGetCount = @convention(c) (CFDictionary) -> Int32
    typealias StateGetName = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
    typealias StateGetResidency = @convention(c) (CFDictionary, Int32) -> Int64

    let copyChannelsInGroup: CopyChannelsInGroup
    let createSubscription: CreateSubscription
    let createSamples: CreateSamples
    let createSamplesDelta: CreateSamplesDelta
    let channelName: ChannelGetName
    let stateCount: StateGetCount
    let stateName: StateGetName
    let stateResidency: StateGetResidency

    init?() {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }

        func load<T>(_ symbol: String, as type: T.Type) -> T? {
            dlsym(handle, symbol).map { unsafeBitCast($0, to: type) }
        }

        guard
            let copyChannelsInGroup = load("IOReportCopyChannelsInGroup", as: CopyChannelsInGroup.self),
            let createSubscription = load("IOReportCreateSubscription", as: CreateSubscription.self),
            let createSamples = load("IOReportCreateSamples", as: CreateSamples.self),
            let createSamplesDelta = load("IOReportCreateSamplesDelta", as: CreateSamplesDelta.self),
            let channelName = load("IOReportChannelGetChannelName", as: ChannelGetName.self),
            let stateCount = load("IOReportStateGetCount", as: StateGetCount.self),
            let stateName = load("IOReportStateGetNameForIndex", as: StateGetName.self),
            let stateResidency = load("IOReportStateGetResidency", as: StateGetResidency.self)
        else { return nil }

        self.copyChannelsInGroup = copyChannelsInGroup
        self.createSubscription = createSubscription
        self.createSamples = createSamples
        self.createSamplesDelta = createSamplesDelta
        self.channelName = channelName
        self.stateCount = stateCount
        self.stateName = stateName
        self.stateResidency = stateResidency
    }
}
