import ARKit
import Foundation
import QuartzCore
import simd

/// ARKit adapter. Each start owns fresh providers; stop never deletes persisted anchors.
@MainActor
final class WorldTrackingService: TrackingSource {
    private var session: ARKitSession?
    private var provider: WorldTrackingProvider?
    private var planeProvider: PlaneDetectionProvider?
    private var tasks: [Task<Void, Never>] = []
    private var prepared: [UUID: WorldAnchor] = [:]
    private var generation = 0
    var onInput: ((TrackingInput) -> Void)?
    var isRunning: Bool { provider?.state == .running }

    func start() async throws {
        stop()
        guard WorldTrackingProvider.isSupported else { throw TrackingError.unsupported }
        generation += 1
        let token = generation
        let session = ARKitSession()
        let world = WorldTrackingProvider()
        let planes = PlaneDetectionProvider.isSupported ? PlaneDetectionProvider(alignments: [.horizontal]) : nil
        self.session = session
        provider = world
        planeProvider = planes
        // Subscribe before run, so early restored anchors and authorization events are retained.
        tasks.append(Task { [weak self] in
            for await update in world.anchorUpdates {
                guard let self, !Task.isCancelled, token == self.generation else { return }
                let event: ObservationEvent
                switch update.event { case .added: event = .added; case .updated: event = .updated; case .removed: event = .removed }
                self.onInput?(.waypoint(WaypointObservation(id: update.anchor.id, event: event,
                    pose: event == .removed ? nil : update.anchor.originFromAnchorTransform,
                    isTracked: update.anchor.isTracked, sourceTimestamp: update.timestamp)))
            }
        })
        if let planes {
            tasks.append(Task { [weak self] in
                for await update in planes.anchorUpdates {
                    guard let self, !Task.isCancelled, token == self.generation else { return }
                    let anchor = update.anchor
                    let isFloor: Bool
                    if #available(visionOS 26.0, *) { isFloor = anchor.surfaceClassification == .floor }
                    else { isFloor = anchor.classification == .floor }
                    var surface: FloorSurface?
                    if update.event != .removed, anchor.alignment == .horizontal, isFloor {
                        let extent = anchor.geometry.extent
                        surface = FloorSurface(id: anchor.id,
                            transform: anchor.originFromAnchorTransform * extent.anchorFromExtentTransform,
                            width: extent.width, depth: extent.height, sourceTimestamp: update.timestamp)
                    }
                    self.onInput?(.floor(anchor.id, surface))
                }
            })
        } else { onInput?(.provider(world: false, running: false, description: "地面检测不受支持")) }
        tasks.append(Task { [weak self] in
            for await event in session.events {
                guard let self, !Task.isCancelled, token == self.generation else { return }
                switch event {
                case .authorizationChanged(let type, let status):
                    if type == .worldSensing, status != .notDetermined {
                        self.onInput?(.authorization(allowed: status == .allowed, description: String(describing: status)))
                    }
                case .dataProviderStateChanged(let providers, let state, let error):
                    for changed in providers {
                        self.onInput?(.provider(world: changed is WorldTrackingProvider, running: state == .running,
                            description: "\(state)\(error.map { ": \($0.localizedDescription)" } ?? "")"))
                    }
                @unknown default: break
                }
            }
        })
        var providers: [any DataProvider] = [world]
        if let planes { providers.append(planes) }
        do { try await session.run(providers) }
        catch {
            if generation == token { stop() }
            throw error
        }
        guard token == generation else { throw CancellationError() }
    }

    func sample() -> DeviceTrackingSample {
        let time = CACurrentMediaTime()
        guard let provider, provider.state == .running else { return .init(pose: nil, queryTime: time, reason: "providerNotRunning") }
        guard let device = provider.queryDeviceAnchor(atTimestamp: time) else { return .init(pose: nil, queryTime: time, reason: "deviceAnchorNil") }
        guard device.isTracked else { return .init(pose: nil, queryTime: time, reason: "deviceUntracked") }
        return .init(pose: device.originFromAnchorTransform, queryTime: time, reason: "tracked")
    }
    func devicePose() -> simd_float4x4? { sample().pose }
    func devicePosition() -> SIMD3<Float>? { sample().pose?.translation }
    func prepareAnchor(at pose: simd_float4x4) -> UUID {
        let anchor = WorldAnchor(originFromAnchorTransform: pose)
        prepared[anchor.id] = anchor
        return anchor.id
    }
    func addAnchor(id: UUID) async throws {
        guard let provider, let anchor = prepared.removeValue(forKey: id), isRunning else { throw TrackingError.notRunning }
        try await provider.addAnchor(anchor)
    }
    func removeAnchor(id: UUID) async throws {
        prepared.removeValue(forKey: id)
        guard let provider, isRunning else { throw TrackingError.notRunning }
        try await provider.removeAnchor(forID: id)
    }
    func stop() {
        generation += 1
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        session?.stop()
        session = nil
        provider = nil
        planeProvider = nil
        prepared.removeAll()
    }
}

enum TrackingError: LocalizedError {
    case unsupported, notRunning
    var errorDescription: String? {
        switch self {
        case .unsupported: return "当前设备不支持世界追踪；请在 Vision Pro 真机运行。"
        case .notRunning: return "世界追踪尚未运行。"
        }
    }
}
