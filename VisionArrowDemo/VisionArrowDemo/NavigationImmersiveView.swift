import RealityKit
import SwiftUI

/// 混合沉浸空间的主视图，把 SwiftUI 状态与 RealityKit 场景连接起来。
struct NavigationImmersiveView: View {
    @ObservedObject var route: RouteModel
    @Environment(\.openWindow) private var openWindow
    /// 渲染器持有已经创建的 RealityKit 实体，避免每次状态变化都重建场景。
    @State private var renderer = RouteRenderer()

    // 头部局部坐标：向右 22 cm、向下 22 cm、向前 55 cm，约为手臂可触范围。
    private let controlsOffset = SIMD3<Float>(0.22, -0.22, -0.55)

    var body: some View {
        // 第一个闭包只在创建 RealityView 时设置场景基础结构。
        RealityView { content, attachments in
            // 所有路线箭头和路点标记都会挂在 renderer.root 下。
            content.add(renderer.root)
            if let controls = attachments.entity(for: "controls") {
                // AnchorEntity(.head) 会跟随用户头部，保证面板始终容易找到。
                let headAnchor = AnchorEntity(.head)
                controls.position = controlsOffset
                headAnchor.addChild(controls)
                content.add(headAnchor)
            }
            renderer.sync(with: route)
        } update: { _, _ in
            // 显式读取这些 ObservableObject 属性，让它们变化时触发此更新闭包。
            let _ = route.routeRevision
            let _ = route.renderTick
            let _ = route.arrowGroundClearance
            let _ = route.isTrackingDevice
            let _ = route.isOffRoute
            renderer.sync(with: route)
        } attachments: {
            // Attachment 把 SwiftUI 视图转换成可放入 RealityKit 场景的实体。
            Attachment(id: "controls") {
                MarkerPanel(route: route)
            }
        }
        // 离开时停止追踪与显示；已保存路线的世界锚点保留。
        .task { await route.startTracking() }
        .task(id: route.panelActionWindowRequestID) {
            guard let token = route.panelActionWindowRequestID else { return }
            route.panelActionWindowRequested(token)
            openWindow(id: AppWindow.mainID, value: AppWindow.mainValue)
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            route.checkPanelActionPresentation(token)
        }
        .onAppear { route.isImmersivePresented = true }
        .onDisappear {
            route.isImmersivePresented = false
            Task { await route.stopTracking() }
        }
    }
}
