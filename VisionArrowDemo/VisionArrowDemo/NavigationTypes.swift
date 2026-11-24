import Foundation
import simd

enum RoutePhase { case idle, markingStart, marking, returning, navigating, arrived }
enum RouteEntryMode: String, Codable { case saved, custom }
enum WaypointKind: String, Codable { case start = "起点", turn = "路点", end = "终点" }
enum WaypointTrackingState: String { case pending, tracked, temporarilyUntracked, removed }
enum CoordinateValidity: String { case usable, needsRevalidation }
enum RouteLoadState: String { case none, loadingDefinition, localizing, localSegmentReady, unresolved, failed }
enum NavigationBlockReason: String { case none, providerUnavailable, deviceTrackingUnavailable, coordinateFrameUncertain, localSegmentUnavailable, offRoute }
extension NavigationBlockReason {
    var message: String {
        switch self {
        case .none: return "无"
        case .providerUnavailable: return "世界追踪尚未运行"
        case .deviceTrackingUnavailable: return "设备位置暂时不可用"
        case .coordinateFrameUncertain: return "空间坐标需要重新确认"
        case .localSegmentUnavailable: return "当前或即将进入的路段尚未定位"
        case .offRoute: return "已偏离路线，请回到当前路段附近"
        }
    }
}
extension RouteLoadState {
    var message: String {
        switch self {
        case .none: return "未加载"
        case .loadingDefinition: return "正在读取路线"
        case .localizing: return "正在原场景定位"
        case .localSegmentReady: return "当前路段已定位"
        case .unresolved: return "尚未定位，可继续等待或重试"
        case .failed: return "加载或追踪启动失败"
        }
    }
}
enum ObservationEvent: String { case added, updated, removed }

struct RouteWaypoint: Identifiable {
    let id: UUID
    let kind: WaypointKind
    var pose: simd_float4x4?
    var lastTrackedPose: simd_float4x4?
    var trackingState: WaypointTrackingState = .pending
    var lastAnchorUpdateTime: TimeInterval?
    var sessionGeneration = 0
    var coordinateEpoch = 0
    var isTracked: Bool { trackingState == .tracked }
    var position: SIMD3<Float>? { lastTrackedPose?.translation }
}

struct WaypointObservation {
    let id: UUID
    let event: ObservationEvent
    let pose: simd_float4x4?
    let isTracked: Bool
    var sourceTimestamp: TimeInterval? = nil
}

struct DeviceTrackingSample {
    let pose: simd_float4x4?
    let queryTime: TimeInterval
    let reason: String
    var isTracked: Bool { pose?.isFinite == true }
}

struct FloorSurface: Identifiable {
    let id: UUID
    let transform: simd_float4x4 // worldFromExtent; local X/Z extent
    let width: Float
    let depth: Float
    var sourceTimestamp: TimeInterval? = nil
    var height: Float { transform.translation.y }
    var center: SIMD3<Float> { transform.translation }
    func contains(_ point: SIMD3<Float>) -> Bool {
        guard transform.isFinite, width.isFinite, depth.isFinite, width > 0, depth > 0,
              abs(simd_determinant(transform)) > 0.001 else { return false }
        let local = simd_inverse(transform) * SIMD4<Float>(point.x, height, point.z, 1)
        return abs(local.x) <= width / 2 && abs(local.z) <= depth / 2
    }
    func supports(_ point: SIMD3<Float>) -> Bool {
        let difference = point.y - height
        return difference >= 0.45 && difference <= 2.2 && contains(point)
    }
}

enum TrackingInput {
    case waypoint(WaypointObservation)
    case floor(UUID, FloorSurface?)
    case provider(world: Bool, running: Bool, description: String)
    case authorization(allowed: Bool, description: String)
}

@MainActor protocol TrackingSource: AnyObject {
    var onInput: ((TrackingInput) -> Void)? { get set }
    var isRunning: Bool { get }
    func start() async throws
    func stop()
    func sample() -> DeviceTrackingSample
    func prepareAnchor(at pose: simd_float4x4) -> UUID
    func addAnchor(id: UUID) async throws
    func removeAnchor(id: UUID) async throws
}

struct NavigationConfiguration {
    var startDistance: Float = 0.8
    var arrivalDistance: Float = 0.55
    var offRouteDistance: Float = 1
    var offRouteRecovery: Float = 0.75
    var offRouteDelay: Double = 0.5
    var lookAhead: Float = 10
    var arrowSpacing: Float = 0.65
    var arrowOffset: Float = 0.325
    var localizationTimeout: Double = 30
    var calibrationWindow: Double = 1
    var calibrationHeightRange: Float = 0.03
    var fallbackHeightConflict: Float = 0.08
    var fallbackGeometryTolerance: Float = 0.1
}

struct SegmentScope {
    let index: Int // segment ends at this waypoint index
    let startID: UUID
    let endID: UUID
    let a: SIMD3<Float>
    let b: SIMD3<Float>
    let from: Float
    let to: Float
    var length: Float { horizontalDistance(a, b) }
    func point(at distance: Float) -> SIMD3<Float> { a + (b - a) * (distance / max(length, 0.001)) }
}

struct FallbackFloorReference {
    let id: UUID
    let source: FloorSurface
    let routeID: UUID
    let generation: Int
    let epoch: Int
    let calibratedAt: Date
    let scopes: [SegmentScope]
    let halfWidth: Float
    var enabled = true
    var invalidReason: String?
    func covers(_ point: SIMD3<Float>, segment: Int) -> Bool {
        guard enabled, invalidReason == nil else { return false }
        return scopes.contains { scope in
            guard scope.index == segment else { return false }
            let projection = segmentProjection(point, scope.a, scope.b)
            return projection.distance >= scope.from && projection.distance <= scope.to && projection.lateral <= halfWidth
        }
    }
}

struct ArrowPlacement: Identifiable {
    let id: String
    let segment: Int
    let position: SIMD3<Float>
    let direction: SIMD3<Float>
    let isActive: Bool
    let usesFallback: Bool
}

struct LayoutStatistics: Equatable, Codable {
    var candidate = 0
    var placed = 0
    var visible = 0
    var fallback = 0
    var coverage = "notEvaluated"
    var missing: Int { candidate - placed }
}

struct NavigationLayout {
    var placements: [ArrowPlacement] = []
    var statistics = LayoutStatistics()
    var previewUnavailable = false
}

/// Pure layout shared by production and tests. Device movement clips fixed samples.
enum RouteLayout {
    static func make(current: SegmentScope, next: SegmentScope?, device: SIMD3<Float>, floors: [FloorSurface],
                     fallback: FallbackFloorReference?, clearance: Float, navigating: Bool,
                     configuration: NavigationConfiguration) -> NavigationLayout {
        var result = NavigationLayout()
        let s = min(max(segmentProjection(device, current.a, current.b).distance, 0), current.length)
        let remaining = max(0, configuration.lookAhead - (current.length - s))
        var windows: [(SegmentScope, Float, Float)] = [(current, s, min(current.length, s + configuration.lookAhead))]
        if remaining > 0, let next { windows.append((next, 0, min(next.length, remaining))) }
        for (scope, lower, upper) in windows where scope.length >= 0.5 {
            let first = max(0, Int(ceil((lower - configuration.arrowOffset) / configuration.arrowSpacing)))
            let last = Int(floor((upper - configuration.arrowOffset) / configuration.arrowSpacing))
            guard last >= first else { continue }
            for k in first...last {
                let d = configuration.arrowOffset + Float(k) * configuration.arrowSpacing
                guard d < scope.length else { continue }
                let point = scope.point(at: d)
                result.statistics.candidate += 1
                let floor = detectedFloor(near: point, floors: floors)
                let usesFallback = floor == nil && fallback?.covers(point, segment: scope.index) == true
                guard let height = floor?.height ?? (usesFallback ? fallback?.source.height : nil) else { continue }
                let direction = SIMD3<Float>(scope.b.x - scope.a.x, 0, scope.b.z - scope.a.z)
                result.placements.append(ArrowPlacement(id: "\(scope.startID)-\(scope.endID)-\(k)", segment: scope.index,
                    position: [point.x, height + clearance, point.z], direction: simd_normalize(direction),
                    isActive: navigating && scope.index == current.index, usesFallback: usesFallback))
                if usesFallback { result.statistics.fallback += 1 }
            }
        }
        result.statistics.placed = result.placements.count
        result.statistics.visible = result.placements.count
        result.statistics.coverage = result.statistics.candidate == 0 ? "noCandidates" :
            (result.statistics.placed == 0 ? "unavailable" : (result.statistics.missing == 0 ? "complete" : "partial"))
        return result
    }

    static func detectedFloor(near point: SIMD3<Float>, floors: [FloorSurface]) -> FloorSurface? {
        floors.filter { $0.supports(point) }.min {
            let da = horizontalDistance(point, $0.center), db = horizontalDistance(point, $1.center)
            return da == db ? $0.id.uuidString < $1.id.uuidString : da < db
        }
    }
}

func horizontalDistance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { simd_length(SIMD2(a.x - b.x, a.z - b.z)) }
func segmentProjection(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>) -> (distance: Float, lateral: Float, finiteDistance: Float) {
    let v = SIMD2(b.x - a.x, b.z - a.z), w = SIMD2(p.x - a.x, p.z - a.z)
    let length = simd_length(v)
    guard length > 0.001 else { return (0, simd_length(w), simd_length(w)) }
    let d = simd_dot(w, v) / length
    return (d, simd_length(w - v * (d / length)), simd_length(w - v * (min(max(d / length, 0), 1))))
}

extension simd_float4x4 {
    var translation: SIMD3<Float> { SIMD3(columns.3.x, columns.3.y, columns.3.z) }
    var values: [Float] { (0..<4).flatMap { c in (0..<4).map { r in self[c][r] } } }
    var isFinite: Bool { values.allSatisfy(\.isFinite) }
}
