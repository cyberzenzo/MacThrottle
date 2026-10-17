import SwiftUI

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
                TimeBreakdownView(
                    timeInEachState: statistics.durations,
                    totalDuration: statistics.total
                )
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
