import Foundation

struct NavigationLogEvent: Codable {
    let schemaVersion: Int
    let sequence: Int
    let date: Date
    let monotonicTime: Double
    let appRunID: UUID
    let routeID: UUID?
    let testRunID: UUID?
    let sessionGeneration: Int
    let coordinateEpoch: Int
    let event: String
    var fields: [String: String]
    var pose: [Float]?
}

struct NavigationRunSummary: Codable, Identifiable {
    var schemaVersion = 1
    let id: UUID
    let appRunID: UUID
    let routeID: UUID
    let routeName: String
    let definitionVersion: Int
    let entryMode: String
    let trialNumber: Int
    let startedAt: Date
    var isSavedRoute = false
    var appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    var buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    var systemVersion = ProcessInfo.processInfo.operatingSystemVersionString
    var commit = "unknown"
    var endedAt: Date?
    var result = "running"
    var reason: String?
    var droppedEventCount = 0
    var logError: String?
}

actor NavigationTestRecorder {
    let root: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NavigationTests")) { self.root = root }
    private func folder(_ routeID: UUID?) -> URL { root.appendingPathComponent(routeID?.uuidString ?? "Sessions") }
    func append(_ event: NavigationLogEvent) throws {
        let directory = folder(event.routeID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(event.appRunID).jsonl")
        let data = try encoder.encode(event) + Data([0x0A])
        if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url, options: .atomic) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
    func save(_ summary: NavigationRunSummary) throws {
        let directory = folder(summary.routeID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(summary).write(to: directory.appendingPathComponent("\(summary.id).json"), options: .atomic)
    }
    func history(currentAppRun: UUID) throws -> [NavigationRunSummary] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var summaries: [NavigationRunSummary] = []
        for case let url as URL in enumerator where url.pathExtension == "json" && !url.path.contains("/Exports/") {
            var value = try decoder.decode(NavigationRunSummary.self, from: Data(contentsOf: url))
            if value.result == "running" && value.appRunID != currentAppRun {
                value.result = "interrupted"
                value.reason = "上次应用未正常结束"
                try save(value)
            }
            summaries.append(value)
        }
        return summaries.sorted { $0.startedAt > $1.startedAt }
    }
    func export(routeID: UUID, currentAppRun: UUID, testRunID: UUID? = nil, sequenceCutoff: Int = .max) throws -> URL {
        struct Export: Encodable {
            let schemaVersion: Int
            let currentAppRun: UUID
            let sequenceCutoff: Int
            let summaries: [NavigationRunSummary]
            let events: [NavigationLogEvent]
        }
        let summaries = try history(currentAppRun: currentAppRun).filter { $0.routeID == routeID && (testRunID == nil || $0.id == testRunID) }
        let directory = folder(routeID)
        var events: [NavigationLogEvent] = []
        if FileManager.default.fileExists(atPath: directory.path) {
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where url.pathExtension == "jsonl" {
                for line in try Data(contentsOf: url).split(separator: 0x0A) { events.append(try decoder.decode(NavigationLogEvent.self, from: Data(line))) }
            }
        }
        events = events.filter { ($0.appRunID != currentAppRun || $0.sequence <= sequenceCutoff) &&
            (testRunID == nil || $0.testRunID == testRunID || $0.testRunID == nil) }
        events.sort { $0.appRunID == $1.appRunID ? $0.sequence < $1.sequence : $0.date < $1.date }
        let destination = root.appendingPathComponent("Exports").appendingPathComponent("\(routeID)-\(testRunID?.uuidString ?? "all-runs")-\(UUID()).json")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(Export(schemaVersion: 1, currentAppRun: currentAppRun, sequenceCutoff: sequenceCutoff, summaries: summaries, events: events)).write(to: destination, options: .atomic)
        return destination
    }
}
