import ARKit
import Combine
import Foundation
import simd

enum RoutePhase {
    case idle
    case markingStart
    case marking
    case returning
    case navigating
    case arrived
}

enum WaypointKind: String {
    case start = "起点"
    case turn = "路点"
    case end = "终点"
}

struct RouteWaypoint: Identifiable {
    let id: UUID
    let kind: WaypointKind
    var pose: simd_float4x4?
    var isTracked = false

    var position: SIMD3<Float>? { pose?.translation }
}

private struct FloorSurface {
    let center: SIMD3<Float>
    let height: Float
    let radius: Float
}

@MainActor
final class RouteModel: ObservableObject {
    private let tracking = WorldTrackingService()
    private var samplingTask: Task<Void, Never>?
    private var floorSurfaces: [UUID: FloorSurface] = [:]

    @Published private(set) var phase: RoutePhase = .idle
    @Published private(set) var waypoints: [RouteWaypoint] = []
    @Published private(set) var targetIndex = 1
    @Published private(set) var currentPosition: SIMD3<Float>?
    @Published private(set) var isTrackingDevice = false
    @Published private(set) var isOffRoute = false
    @Published private(set) var isBusy = false
    @Published private(set) var message: String?
    @Published private(set) var routeRevision = 0
    @Published var arrowGroundClearance = 0.01

    var hasDetectedFloor: Bool { !floorSurfaces.isEmpty }

    func floorHeight(near point: SIMD3<Float>) -> Float? {
        floorSurfaces.values
            .filter { surface in
                let headToFloor = point.y - surface.height
                return headToFloor >= 0.45 && headToFloor <= 2.2 &&
                    horizontalDistance(point, surface.center) <= surface.radius + 0.3
            }
            .min { a, b in
                horizontalDistance(point, a.center) - a.radius <
                    horizontalDistance(point, b.center) - b.radius
            }?
            .height
    }

    var hasTrackedRoute: Bool {
        waypoints.count >= 3 && waypoints.allSatisfy { $0.isTracked && $0.position != nil }
    }

    var canStartNavigation: Bool {
        guard phase == .returning, hasTrackedRoute, let currentPosition,
              let start = waypoints.first?.position else { return false }
        return horizontalDistance(currentPosition, start) <= 0.8
    }

    var statusText: String {
        if let message { return message }
        if !isTrackingDevice && phase != .idle { return "设备追踪暂停，请站稳并等待恢复。" }
        switch phase {
        case .idle: return "打开混合沉浸空间，开始标记室内路线。"
        case .markingStart: return "走到起点并停下，记录起点。"
        case .marking: return "走到转弯处添加路点，最后记录终点。"
        case .returning:
            if !hasTrackedRoute { return "等待全部路点定位完成。" }
            if !hasDetectedFloor { return "正在识别地面；识别后箭头会贴近地面显示。" }
            return "沿安全路线返回起点，进入 0.8 米范围后开始导航。"
        case .navigating:
            if !hasTrackedRoute { return "路点追踪暂停，暂不提供方向提示。" }
            if !hasDetectedFloor { return "正在识别地面；暂不显示箭头。" }
            if isOffRoute { return "已偏离记录的路段，请停下并确认周围环境。" }
            return "朝第 \(targetIndex + 1) 个点前进。"
        case .arrived: return "已到达终点。"
        }
    }

    func startTracking() async {
        guard !tracking.isRunning else { return }
        tracking.onAnchorUpdate = { [weak self] update in
            self?.receive(update)
        }
        tracking.onPlaneUpdate = { [weak self] update in
            self?.receiveFloor(update)
        }
        do {
            try await tracking.start()
            message = nil
            samplingTask?.cancel()
            samplingTask = Task { [weak self] in
                while let self, !Task.isCancelled {
                    self.samplePosition()
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        } catch {
            message = "启动空间追踪或地面检测失败：\(error.localizedDescription)。请确认已允许世界感知权限。"
        }
    }

    func beginMarking() async {
        guard tracking.isRunning, !isBusy else {
            message = "世界追踪尚未就绪。"
            return
        }
        await clearRoute()
        phase = .markingStart
        message = nil
    }

    func recordStart() async {
        guard phase == .markingStart else { return }
        if await appendWaypoint(.start) { phase = .marking }
    }

    func addTurn() async {
        guard phase == .marking else { return }
        _ = await appendWaypoint(.turn)
    }

    func recordEnd() async {
        guard phase == .marking else { return }
        guard waypoints.count >= 2 else {
            message = "请先记录至少一个转弯点。"
            return
        }
        if await appendWaypoint(.end) { phase = .returning }
    }

    func undoLastWaypoint() async {
        guard !isBusy, phase == .marking || phase == .returning,
              let last = waypoints.last else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await tracking.removeAnchor(id: last.id)
            waypoints.removeLast()
            routeRevision += 1
            phase = waypoints.isEmpty ? .markingStart : .marking
            message = nil
        } catch {
            message = "撤销失败：\(error.localizedDescription)"
        }
    }

    func startNavigation() {
        guard canStartNavigation else {
            message = "请回到起点附近，并等待所有路点定位。"
            return
        }
        targetIndex = 1
        isOffRoute = false
        phase = .navigating
        message = nil
        routeRevision += 1
    }

    func clearRoute() async {
        guard !isBusy else { return }
        isBusy = true
        let ids = waypoints.map(\.id)
        var failures = 0
        for id in ids {
            do { try await tracking.removeAnchor(id: id) }
            catch { failures += 1 }
        }
        waypoints = []
        targetIndex = 1
        isOffRoute = false
        phase = .idle
        routeRevision += 1
        isBusy = false
        message = failures == 0 ? nil : "有 \(failures) 个旧锚点未能清理。"
    }

    func stopTracking() async {
        samplingTask?.cancel()
        samplingTask = nil
        await clearRoute()
        tracking.stop()
        floorSurfaces.removeAll()
        routeRevision += 1
        isTrackingDevice = false
        currentPosition = nil
    }

    private func appendWaypoint(_ kind: WaypointKind) async -> Bool {
        guard !isBusy, let pose = tracking.devicePose() else {
            message = "设备追踪不可用，请站稳后重试。"
            return false
        }
        if let previous = waypoints.last?.position,
           horizontalDistance(previous, pose.translation) < 0.9 {
            message = "新路点离上一个点太近，请至少移动约 0.9 米。"
            return false
        }

        isBusy = true
        defer { isBusy = false }
        let anchor = tracking.makeAnchor(at: pose)
        // Insert first: ARKit may emit .added before addAnchor returns.
        waypoints.append(RouteWaypoint(id: anchor.id, kind: kind))
        do {
            try await tracking.addAnchor(anchor)
            message = nil
            routeRevision += 1
            return true
        } catch {
            waypoints.removeAll { $0.id == anchor.id }
            message = "记录路点失败：\(error.localizedDescription)"
            routeRevision += 1
            return false
        }
    }

    private func receive(_ update: AnchorUpdate<WorldAnchor>) {
        guard let index = waypoints.firstIndex(where: { $0.id == update.anchor.id }) else { return }
        switch update.event {
        case .added, .updated:
            waypoints[index].pose = update.anchor.originFromAnchorTransform
            waypoints[index].isTracked = update.anchor.isTracked
        case .removed:
            waypoints[index].pose = nil
            waypoints[index].isTracked = false
        }
        routeRevision += 1
    }

    private func receiveFloor(_ update: AnchorUpdate<PlaneAnchor>) {
        let anchor = update.anchor
        switch update.event {
        case .added, .updated:
            let isFloor: Bool
            if #available(visionOS 26.0, *) {
                isFloor = anchor.surfaceClassification == .floor
            } else {
                isFloor = anchor.classification == .floor
            }
            if anchor.alignment == .horizontal && isFloor {
                let extent = anchor.geometry.extent
                let center = (anchor.originFromAnchorTransform * extent.anchorFromExtentTransform).translation
                floorSurfaces[anchor.id] = FloorSurface(
                    center: center,
                    height: center.y,
                    radius: hypot(extent.width, extent.height) * 0.5
                )
            } else {
                floorSurfaces.removeValue(forKey: anchor.id)
            }
        case .removed:
            floorSurfaces.removeValue(forKey: anchor.id)
        }
        routeRevision += 1
    }

    private func samplePosition() {
        let position = tracking.devicePosition()
        currentPosition = position
        isTrackingDevice = position != nil
        guard phase == .navigating, let position, hasTrackedRoute,
              targetIndex < waypoints.count,
              let start = waypoints[targetIndex - 1].position,
              let target = waypoints[targetIndex].position else { return }

        let segment = SIMD2(target.x - start.x, target.z - start.z)
        let fromStart = SIMD2(position.x - start.x, position.z - start.z)
        let lengthSquared = simd_length_squared(segment)
        guard lengthSquared > 0.01 else { return }
        let progress = simd_dot(fromStart, segment) / lengthSquared
        let lateral = simd_length(fromStart - segment * progress)
        let nearestProgress = min(max(progress, 0), 1)
        isOffRoute = simd_length(fromStart - segment * nearestProgress) > 1.0
        guard !isOffRoute else { return }
        if horizontalDistance(position, target) <= 0.55 && progress >= 0.55 && lateral <= 0.7 {
            if targetIndex == waypoints.count - 1 {
                phase = .arrived
            } else {
                targetIndex += 1
            }
            routeRevision += 1
        }
    }
}

func horizontalDistance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
    simd_length(SIMD2(a.x - b.x, a.z - b.z))
}
