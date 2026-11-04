import RealityKit
import simd
import UIKit

@MainActor
final class RouteRenderer {
    let root = Entity()
    private var glyphs: [ArrowGlyph] = []
    private var markers: [ModelEntity] = []
    private var lastRevision: Int?
    private var lastGroundClearance: Double?
    private var lastTrackingState: Bool?
    private var lastOffRoute: Bool?

    func sync(with route: RouteModel) {
        guard lastRevision != route.routeRevision ||
              lastGroundClearance != route.arrowGroundClearance ||
              lastTrackingState != route.isTrackingDevice ||
              lastOffRoute != route.isOffRoute else { return }
        lastRevision = route.routeRevision
        lastGroundClearance = route.arrowGroundClearance
        lastTrackingState = route.isTrackingDevice
        lastOffRoute = route.isOffRoute
        let showRoute = route.isTrackingDevice && !route.isOffRoute &&
            (route.phase != .navigating || route.hasTrackedRoute)
        let placements = makePlacements(route)
        while glyphs.count < placements.count {
            let glyph = ArrowGlyph()
            root.addChild(glyph.entity)
            glyphs.append(glyph)
        }
        for (index, glyph) in glyphs.enumerated() {
            let isVisible = showRoute && index < placements.count
            glyph.entity.isEnabled = isVisible
            if isVisible {
                let placement = placements[index]
                glyph.entity.position = placement.position
                glyph.entity.orientation = placement.orientation
                glyph.setActive(placement.isActive)
            }
        }

        let visibleWaypoints = showRoute
            ? route.waypoints.compactMap { waypoint -> (RouteWaypoint, SIMD3<Float>, Float)? in
                guard waypoint.isTracked, let point = waypoint.position,
                      let floorY = route.floorHeight(near: point) else { return nil }
                return (waypoint, point, floorY)
            }
            : []
        while markers.count < visibleWaypoints.count {
            let marker = ModelEntity(
                mesh: .generateSphere(radius: 0.045),
                materials: [SimpleMaterial(color: .yellow, isMetallic: false)]
            )
            root.addChild(marker)
            markers.append(marker)
        }
        for (index, marker) in markers.enumerated() {
            marker.isEnabled = index < visibleWaypoints.count
            if index < visibleWaypoints.count {
                let (waypoint, point, floorY) = visibleWaypoints[index]
                marker.position = [point.x, floorY + Float(route.arrowGroundClearance) + 0.045, point.z]
                marker.model?.materials = [SimpleMaterial(
                    color: waypoint.kind == .end ? .green : .yellow,
                    isMetallic: false
                )]
            }
        }
    }

    private func makePlacements(_ route: RouteModel) -> [ArrowPlacement] {
        guard route.waypoints.count > 1 else { return [] }
        var result: [ArrowPlacement] = []

        for index in 0 ..< route.waypoints.count - 1 {
            let start = route.waypoints[index]
            let end = route.waypoints[index + 1]
            guard start.isTracked, end.isTracked,
                  let a = start.position, let b = end.position else { continue }
            let direction = SIMD3<Float>(b.x - a.x, 0, b.z - a.z)
            let length = simd_length(direction)
            guard length >= 0.5 else { continue }
            let orientation = simd_quatf(from: [0, 0, -1], to: direction / length)
            let count = max(1, Int(length / 0.65))
            for step in 1 ... count {
                let fraction = Float(step) / Float(count + 1)
                let point = SIMD3<Float>(
                    a.x + (b.x - a.x) * fraction,
                    a.y + (b.y - a.y) * fraction,
                    a.z + (b.z - a.z) * fraction
                )
                guard let floorY = route.floorHeight(near: point) else { continue }
                result.append(ArrowPlacement(
                    position: [point.x, floorY + Float(route.arrowGroundClearance), point.z],
                    orientation: orientation,
                    isActive: route.phase == .navigating && route.targetIndex == index + 1
                ))
            }
        }
        return result
    }
}

private struct ArrowPlacement {
    let position: SIMD3<Float>
    let orientation: simd_quatf
    let isActive: Bool
}

@MainActor
private final class ArrowGlyph {
    let entity = Entity()
    private var parts: [ModelEntity] = []

    init() {
        addBar(size: [0.025, 0.008, 0.18], position: [0, 0, 0.015], angle: 0)
        addBar(size: [0.025, 0.008, 0.11], position: [-0.038, 0, -0.085], angle: -.pi / 4)
        addBar(size: [0.025, 0.008, 0.11], position: [0.038, 0, -0.085], angle: .pi / 4)
    }

    func setActive(_ active: Bool) {
        let material = SimpleMaterial(color: active ? .cyan : .gray, isMetallic: false)
        for part in parts { part.model?.materials = [material] }
    }

    private func addBar(size: SIMD3<Float>, position: SIMD3<Float>, angle: Float) {
        let bar = ModelEntity(mesh: .generateBox(size: size),
                              materials: [SimpleMaterial(color: .gray, isMetallic: false)])
        bar.position = position
        bar.orientation = simd_quatf(angle: angle, axis: [0, 1, 0])
        entity.addChild(bar)
        parts.append(bar)
    }
}
