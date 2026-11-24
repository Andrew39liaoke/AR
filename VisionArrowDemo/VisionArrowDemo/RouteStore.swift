import Foundation

struct SavedWaypoint: Codable, Identifiable, Equatable {
    let id: UUID
    let kind: WaypointKind
}

struct SavedRoute: Codable, Identifiable, Equatable {
    var schemaVersion = 1
    var definitionVersion = 1
    let id: UUID
    var name: String
    var startDescription: String
    let createdAt: Date
    var waypoints: [SavedWaypoint]
    var segmentLengths: [Float]
    var trialNumber = 0

    func validate() throws {
        guard schemaVersion == 1, definitionVersion > 0, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              waypoints.count >= 3, waypoints.first?.kind == .start, waypoints.last?.kind == .end,
              waypoints.dropFirst().dropLast().allSatisfy({ $0.kind == .turn }),
              Set(waypoints.map(\.id)).count == waypoints.count, segmentLengths.count == waypoints.count - 1,
              segmentLengths.allSatisfy({ $0.isFinite && $0 >= 0.5 }), trialNumber >= 0 else { throw RouteStoreError.invalidDefinition }
    }
}

enum RouteStoreError: LocalizedError {
    case invalidDefinition, deleted, missing
    var errorDescription: String? {
        switch self {
        case .invalidDefinition: return "路线文件格式或路点结构无效。"
        case .deleted: return "该路线已进入永久删除流程。"
        case .missing: return "找不到保存的路线。"
        }
    }
}

/// All disk operations are isolated off the main actor. No world transforms are persisted here.
actor RouteStore {
    struct Ledger: Codable {
        var drafts: [String: [UUID]] = [:]
        var deletions: [String: [UUID]] = [:] // empty entries remain tombstones
    }
    let root: URL
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SavedRoutes")) {
        self.root = root
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }
    private func routeURL(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString).appendingPathComponent("route.json") }
    private var ledgerURL: URL { root.appendingPathComponent("ownership.json") }
    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(value).write(to: url, options: .atomic)
    }
    private func ledger() throws -> Ledger {
        guard FileManager.default.fileExists(atPath: ledgerURL.path) else { return Ledger() }
        return try decoder.decode(Ledger.self, from: Data(contentsOf: ledgerURL))
    }
    func list() throws -> [SavedRoute] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let deleted = try ledger().deletions
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .compactMap { folder -> SavedRoute? in
                guard let id = UUID(uuidString: folder.lastPathComponent), deleted[id.uuidString] == nil else { return nil }
                let route = try decoder.decode(SavedRoute.self, from: Data(contentsOf: routeURL(id)))
                try route.validate()
                guard route.id == id else { throw RouteStoreError.invalidDefinition }
                return route
            }.sorted { $0.createdAt > $1.createdAt }
    }
    func load(_ id: UUID) throws -> SavedRoute {
        guard try ledger().deletions[id.uuidString] == nil else { throw RouteStoreError.deleted }
        let route = try decoder.decode(SavedRoute.self, from: Data(contentsOf: routeURL(id)))
        try route.validate()
        guard route.id == id else { throw RouteStoreError.invalidDefinition }
        return route
    }
    func save(_ route: SavedRoute) throws {
        try route.validate()
        var ownership = try ledger()
        guard ownership.deletions[route.id.uuidString] == nil else { throw RouteStoreError.deleted }
        try write(route, to: routeURL(route.id)) // commit first; stale draft ledger is protected by saved ownership
        ownership.drafts.removeValue(forKey: route.id.uuidString)
        try write(ownership, to: ledgerURL)
    }
    func registerDraftAnchor(routeID: UUID, anchorID: UUID) throws {
        var value = try ledger()
        guard value.deletions[routeID.uuidString] == nil else { throw RouteStoreError.deleted }
        if !value.drafts[routeID.uuidString, default: []].contains(anchorID) { value.drafts[routeID.uuidString, default: []].append(anchorID) }
        try write(value, to: ledgerURL)
    }
    func reserveTrial(_ id: UUID) throws -> Int {
        var route = try load(id)
        route.trialNumber += 1
        try write(route, to: routeURL(id))
        return route.trialNumber
    }
    func beginDeletion(_ id: UUID) throws {
        var value = try ledger()
        if value.deletions[id.uuidString] == nil {
            let route = try load(id)
            value.deletions[id.uuidString] = route.waypoints.map(\.id)
            try write(value, to: ledgerURL) // durable intent BEFORE calling ARKit
        }
    }
    func cleanupIDs(excludingDraft: UUID? = nil) throws -> [UUID] {
        let value = try ledger()
        let protected = Set(try list().flatMap { $0.waypoints.map(\.id) })
        let drafts = value.drafts.filter { $0.key != excludingDraft?.uuidString }.values.flatMap { $0 }
        return Array(Set(drafts + value.deletions.values.flatMap { $0 }).subtracting(protected)).sorted { $0.uuidString < $1.uuidString }
    }
    func acknowledgeRemoval(_ id: UUID) throws {
        var value = try ledger()
        for key in Array(value.drafts.keys) {
            value.drafts[key]?.removeAll { $0 == id }
            if value.drafts[key]?.isEmpty == true { value.drafts.removeValue(forKey: key) }
        }
        for key in Array(value.deletions.keys) { value.deletions[key]?.removeAll { $0 == id } }
        try write(value, to: ledgerURL)
        for (key, pending) in value.deletions where pending.isEmpty {
            if let routeID = UUID(uuidString: key), FileManager.default.fileExists(atPath: routeURL(routeID).path) {
                try FileManager.default.removeItem(at: routeURL(routeID))
            }
        }
    }
}
