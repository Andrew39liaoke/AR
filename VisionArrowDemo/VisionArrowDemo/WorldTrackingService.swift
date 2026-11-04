import ARKit
import Foundation
import QuartzCore
import simd

@MainActor
final class WorldTrackingService {
    private let session = ARKitSession()
    private let provider = WorldTrackingProvider()
    private let planeProvider = PlaneDetectionProvider(alignments: [.horizontal])
    private var updatesTask: Task<Void, Never>?
    private var planeUpdatesTask: Task<Void, Never>?

    var onAnchorUpdate: ((AnchorUpdate<WorldAnchor>) -> Void)?
    var onPlaneUpdate: ((AnchorUpdate<PlaneAnchor>) -> Void)?

    var isRunning: Bool { provider.state == .running }

    func start() async throws {
        guard WorldTrackingProvider.isSupported else {
            throw TrackingError.unsupported
        }
        guard PlaneDetectionProvider.isSupported else {
            throw TrackingError.unsupportedPlaneDetection
        }
        try await session.run([provider, planeProvider])
        updatesTask?.cancel()
        updatesTask = Task { [weak self] in
            guard let self else { return }
            for await update in provider.anchorUpdates {
                guard !Task.isCancelled else { break }
                onAnchorUpdate?(update)
            }
        }
        planeUpdatesTask?.cancel()
        planeUpdatesTask = Task { [weak self] in
            guard let self else { return }
            for await update in planeProvider.anchorUpdates {
                guard !Task.isCancelled else { break }
                onPlaneUpdate?(update)
            }
        }
    }

    func devicePosition() -> SIMD3<Float>? {
        guard isRunning,
              let device = provider.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()),
              device.isTracked else { return nil }
        return device.originFromAnchorTransform.translation
    }

    func devicePose() -> simd_float4x4? {
        guard isRunning,
              let device = provider.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()),
              device.isTracked else { return nil }
        return device.originFromAnchorTransform
    }

    // Keep the ID before awaiting addAnchor so an early .added event is not lost.
    func makeAnchor(at pose: simd_float4x4) -> WorldAnchor {
        WorldAnchor(originFromAnchorTransform: pose)
    }

    func addAnchor(_ anchor: WorldAnchor) async throws {
        try await provider.addAnchor(anchor)
    }

    func removeAnchor(id: UUID) async throws {
        try await provider.removeAnchor(forID: id)
    }

    func stop() {
        updatesTask?.cancel()
        updatesTask = nil
        planeUpdatesTask?.cancel()
        planeUpdatesTask = nil
        session.stop()
    }
}

enum TrackingError: LocalizedError {
    case unsupported
    case unsupportedPlaneDetection

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return "当前设备不支持世界追踪；请在 Vision Pro 真机上试走。"
        case .unsupportedPlaneDetection:
            return "当前设备不支持地面检测；请在 Vision Pro 真机上试走。"
        }
    }
}

extension simd_float4x4 {
    var translation: SIMD3<Float> {
        SIMD3(columns.3.x, columns.3.y, columns.3.z)
    }
}
