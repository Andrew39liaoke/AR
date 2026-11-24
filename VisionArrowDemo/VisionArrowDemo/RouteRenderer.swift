import RealityKit
import simd
import UIKit

/// Consumes the same layout result used by diagnostics and tests.
@MainActor
final class RouteRenderer {
    let root = Entity()
    private var glyphs: [ArrowGlyph] = []
    private var markers: [ModelEntity] = []
    private var lastTick: Int?
    var enabledArrowCount: Int { glyphs.filter { $0.entity.isEnabled }.count }

    func sync(with route: RouteModel) {
        guard lastTick != route.renderTick else { return }
        lastTick = route.renderTick
        let placements = route.layout.placements
        while glyphs.count < placements.count {
            let glyph = ArrowGlyph()
            root.addChild(glyph.entity)
            glyphs.append(glyph)
        }
        for (index, glyph) in glyphs.enumerated() {
            glyph.entity.isEnabled = index < placements.count
            if index < placements.count {
                let placement = placements[index]
                glyph.entity.name = placement.id
                glyph.entity.position = placement.position
                glyph.entity.orientation = simd_quatf(from: [0, 0, -1], to: placement.direction)
                glyph.setActive(placement.isActive)
            }
        }
        var visible: [(SIMD3<Float>, Bool)] = []
        if route.navigationBlockReason == .none, route.phase != .arrived, let device = route.currentPosition {
            let indices = Set(route.activeSegmentIndices().flatMap { [$0 - 1, $0] })
            for index in indices.sorted() {
                guard let point = route.usablePosition(for: index), horizontalDistance(device, point) <= route.configuration.lookAhead,
                      let height = route.floorHeight(near: point) else { continue }
                visible.append(([point.x, height + Float(route.arrowGroundClearance) + 0.045, point.z], route.waypoints[index].kind == .end))
            }
        }
        while markers.count < visible.count {
            let marker = ModelEntity(mesh: .generateSphere(radius: 0.045), materials: [SimpleMaterial(color: .yellow, isMetallic: false)])
            root.addChild(marker)
            markers.append(marker)
        }
        for (index, marker) in markers.enumerated() {
            marker.isEnabled = index < visible.count
            if index < visible.count {
                marker.position = visible[index].0
                marker.model?.materials = [SimpleMaterial(color: visible[index].1 ? .green : .yellow, isMetallic: false)]
            }
        }
    }
}

/// 用三个细长方块拼成的简易箭头，不依赖外部 3D 模型资源。
@MainActor
private final class ArrowGlyph {
    let entity = Entity()
    private var parts: [ModelEntity] = []

    init() {
        // 中间是箭身，另外两个旋转 45° 的方块组成箭头尖端。
        addBar(size: [0.025, 0.008, 0.18], position: [0, 0, 0.015], angle: 0)
        addBar(size: [0.025, 0.008, 0.11], position: [-0.038, 0, -0.085], angle: -.pi / 4)
        addBar(size: [0.025, 0.008, 0.11], position: [0.038, 0, -0.085], angle: .pi / 4)
    }

    /// 当前导航路段显示青色，其余已记录路段显示灰色。
    func setActive(_ active: Bool) {
        let material = SimpleMaterial(color: active ? .cyan : .gray, isMetallic: false)
        for part in parts { part.model?.materials = [material] }
    }

    /// 创建一个长方体部件，并挂到箭头根实体下。
    private func addBar(size: SIMD3<Float>, position: SIMD3<Float>, angle: Float) {
        let bar = ModelEntity(mesh: .generateBox(size: size),
                              materials: [SimpleMaterial(color: .gray, isMetallic: false)])
        bar.position = position
        bar.orientation = simd_quatf(angle: angle, axis: [0, 1, 0])
        entity.addChild(bar)
        parts.append(bar)
    }
}
