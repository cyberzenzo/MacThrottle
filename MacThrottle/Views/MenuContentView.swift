import SwiftUI

func colorForSpeedLimit(_ percentage: Double) -> Color {
    switch percentage {
    case 95...: return .green
    case 85..<95: return .yellow
    case 70..<85: return .orange
    default: return .red
    }
}

func colorForTemperature(_ temp: Double) -> Color {
    switch temp {
    case ..<60: return .green
    case 60..<80: return .yellow
    case 80..<95: return .orange
    default: return .red
    }
}

struct MenuContentView: View {
    @Bindable var monitor: ThermalMonitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Thermal Pressure:")
                Text(monitor.pressure.displayName)
                    .foregroundColor(monitor.pressure.color)
                    .fontWeight(.semibold)
                Spacer()
                if let temp = monitor.temperature {
                    Text("\(Int(temp.rounded()))°C")
                        .foregroundColor(colorForTemperature(temp))
                        .fontWeight(.semibold)
                        .help("Source: \(monitor.temperatureSource ?? "Unknown")")
                }
            }
            .font(.headline)

            CPUSpeedView(
                speed: monitor.cpuSpeed,
                availableCPUs: monitor.availableCPUs,
                totalCPUs: monitor.totalCPUs
            )

            Picker("History", selection: $monitor.historyRange) {
                ForEach(HistoryRange.allCases) { range in
                    Text(range.rawValue).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            let visibleHistory = monitor.visibleHistory
            if visibleHistory.count >= 2 {
                HistoryGraphView(
                    history: visibleHistory,
                    showFanSpeed: monitor.showFanSpeed,
                    maxGap: ThermalMonitor.maxSampleGapSeconds
                )
            }

            let statistics = monitor.stateStatistics
            if !statistics.durations.isEmpty {
                Divider()
                Text("Statistics (last \(monitor.historyRange.rawValue))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Thermal Pressure")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                TimeBreakdownView(
                    timeInEachState: statistics.durations,
                    totalDuration: statistics.total
                )
                if let speedStatistics = monitor.speedStatistics {
                    Text("CPU Speed Limit")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    SpeedBreakdownView(statistics: speedStatistics)
                }
            }

            Divider()

            Text("Settings")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Launch at Login", isOn: Binding(
                get: { LaunchAtLoginManager.shared.isEnabled },
                set: { _ in LaunchAtLoginManager.shared.toggle() }
            ))
            .controlSize(.small)

            if monitor.hasFans {
                Toggle("Show Fan Speed", isOn: $monitor.showFanSpeed)
                    .controlSize(.small)
            }

            Toggle("Show Temperature in Menu Bar", isOn: $monitor.showTemperatureInMenuBar)
                .controlSize(.small)

            Toggle("Show Speed Limit in Menu Bar", isOn: $monitor.showSpeedLimitInMenuBar)
                .controlSize(.small)

            Divider()

            Text("Notifications")
                .font(.caption)
                .foregroundStyle(.secondary)

            Group {
                Toggle("On Heavy", isOn: $monitor.notifyOnHeavy)
                Toggle("On Critical", isOn: $monitor.notifyOnCritical)
                Toggle("On Recovery", isOn: $monitor.notifyOnRecovery)
                Toggle("Sound", isOn: $monitor.notificationSound)
            }
            .controlSize(.small)

            Divider()

            HStack {
                Button("About") {
                    openAboutWindow()
                }
                .controlSize(.small)

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 260)
    }

    private func openAboutWindow() {
        openWindow(id: "about")
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct CPUSpeedView: View {
    let speed: CPUSpeedReading?
    let availableCPUs: Int?
    let totalCPUs: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let speed {
                row("Speed Limit") {
                    Circle()
                        .fill(colorForSpeedLimit(speed.speedLimit))
                        .frame(width: 7, height: 7)
                    Text("\(Int(speed.speedLimit.rounded()))%")
                        .fontWeight(.semibold)
                }
                ForEach(speed.coreTypes, id: \.name) { coreType in
                    row("\(coreType.name) Cores (\(coreType.coreCount))") {
                        Text(String(format: "%.2f GHz", coreType.limitMHz / 1000))
                        Text("(\(Int(coreType.percentage.rounded()))%)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let availableCPUs, let totalCPUs {
                row("Available CPUs") {
                    Text("\(availableCPUs) / \(totalCPUs)")
                }
            }
        }
        .font(.caption)
        .monospacedDigit()
        .help(
            "Speed Limit: the highest CPU clock the cores reached in the last 10 seconds, "
                + "as a share of the maximum. When macOS limits the speed because of heat or power, "
                + "it drops below 100%. Light work can also show lower values for a moment."
        )
    }

    private func row<Value: View>(_ label: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            value()
        }
    }
}
