import Foundation

/// Persists the thermal history so it survives app restarts and reboots.
/// The file is append-only CSV, one sample per line: `timestamp,pressure,temperature,fan,speed`.
final class HistoryStore {
    private let fileURL: URL
    private var handle: FileHandle?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appendingPathComponent("MacThrottle", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("history.csv")
    }

    deinit {
        try? handle?.close()
    }

    /// Loads all stored entries newer than `cutoff`, oldest first.
    func load(newerThan cutoff: Date) -> [HistoryEntry] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n")
            .compactMap(Self.parse)
            .filter { $0.timestamp >= cutoff }
    }

    func append(_ entry: HistoryEntry) {
        if handle == nil {
            openForAppending()
        }
        guard let handle else { return }
        do {
            try handle.write(contentsOf: Data((Self.format(entry) + "\n").utf8))
        } catch {
            self.handle = nil
        }
    }

    /// Rewrites the file with only the given entries, dropping expired lines.
    func compact(to entries: [HistoryEntry]) {
        try? handle?.close()
        handle = nil
        let text = entries.map { Self.format($0) + "\n" }.joined()
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func openForAppending() {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: fileURL)
        _ = try? handle?.seekToEnd()
    }

    private static func format(_ entry: HistoryEntry) -> String {
        let timestamp = String(format: "%.0f", entry.timestamp.timeIntervalSince1970)
        let temperature = entry.temperature.map { String(format: "%.1f", $0) } ?? ""
        let fan = entry.fanSpeed.map { String(format: "%.0f", $0) } ?? ""
        let speed = entry.speedLimit.map { String(format: "%.0f", $0) } ?? ""
        return "\(timestamp),\(entry.pressure.rawValue),\(temperature),\(fan),\(speed)"
    }

    private static func parse(_ line: Substring) -> HistoryEntry? {
        let fields = line.split(separator: ",", omittingEmptySubsequences: false)
        guard
            fields.count == 4 || fields.count == 5,
            let seconds = Double(fields[0]),
            let pressure = ThermalPressure(rawValue: String(fields[1]))
        else { return nil }

        return HistoryEntry(
            pressure: pressure,
            temperature: Double(fields[2]),
            fanSpeed: Double(fields[3]),
            speedLimit: fields.count == 5 ? Double(fields[4]) : nil,
            timestamp: Date(timeIntervalSince1970: seconds)
        )
    }
}
