import RealityKit
import SwiftUI

struct NavigationImmersiveView: View {
    @ObservedObject var route: RouteModel
    @State private var renderer = RouteRenderer()

    // Head-local coordinates: right, down, and forward. About arm's length away.
    private let controlsOffset = SIMD3<Float>(0.22, -0.22, -0.55)

    var body: some View {
        RealityView { content, attachments in
            content.add(renderer.root)
            if let controls = attachments.entity(for: "controls") {
                let headAnchor = AnchorEntity(.head)
                controls.position = controlsOffset
                headAnchor.addChild(controls)
                content.add(headAnchor)
            }
            renderer.sync(with: route)
        } update: { _, _ in
            // Reading these values makes changes trigger the RealityView update.
            let _ = route.routeRevision
            let _ = route.arrowGroundClearance
            let _ = route.isTrackingDevice
            let _ = route.isOffRoute
            renderer.sync(with: route)
        } attachments: {
            Attachment(id: "controls") {
                MarkerPanel(route: route)
            }
        }
        .task { await route.startTracking() }
        .onDisappear { Task { await route.stopTracking() } }
    }
}
