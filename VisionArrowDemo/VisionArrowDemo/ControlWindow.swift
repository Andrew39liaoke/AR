import SwiftUI

struct ControlWindow: View {
    @ObservedObject var route: RouteModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @State private var isSpaceOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("空间箭头导航")
                .font(.largeTitle.bold())
            Text("先沿安全路线记录起点、转弯点和终点，再返回起点试走。")
                .foregroundStyle(.secondary)

            if !isSpaceOpen {
                Button("打开混合沉浸空间") {
                    Task {
                        let result = await openImmersiveSpace(id: "navigation")
                        if case .opened = result { isSpaceOpen = true }
                    }
                }
                .buttonStyle(.borderedProminent)
            } else {
                RouteControls(route: route)
                Button("结束演示并关闭空间") {
                    Task {
                        await route.stopTracking()
                        await dismissImmersiveSpace()
                        isSpaceOpen = false
                    }
                }
                .foregroundStyle(.secondary)
                .disabled(route.isBusy)
            }

            Spacer(minLength: 0)
        }
        .padding(28)
    }
}

struct MarkerPanel: View {
    let route: RouteModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("路线标记")
                .font(.headline)
            RouteControls(route: route)
        }
        .controlSize(.large)
        .padding(14)
        .frame(width: 280)
        .glassBackgroundEffect()
    }
}

struct RouteControls: View {
    @ObservedObject var route: RouteModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(route.statusText)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Text("已记录 \(route.waypoints.count) 个点")
                .foregroundStyle(.secondary)
            if route.waypoints.count >= 2 && !route.hasDetectedFloor {
                Text("正在识别地面，请缓慢环顾路线所在的地面。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            switch route.phase {
            case .idle:
                Button("开始标记") { Task { await route.beginMarking() } }
            case .markingStart:
                Button("记录起点") { Task { await route.recordStart() } }
            case .marking:
                HStack {
                    Button("添加路点") { Task { await route.addTurn() } }
                    Button("记录终点") { Task { await route.recordEnd() } }
                }
                Button("撤销上一个点") { Task { await route.undoLastWaypoint() } }
            case .returning:
                HStack {
                    Button("开始导航") { route.startNavigation() }
                        .disabled(!route.canStartNavigation)
                    Button("撤销终点") { Task { await route.undoLastWaypoint() } }
                }
            case .navigating:
                Text("当前目标：第 \(route.targetIndex + 1) 个点")
            case .arrived:
                Text("已到达")
                    .foregroundStyle(.green)
            }

            if !route.waypoints.isEmpty {
                VStack(alignment: .leading) {
                    Text("箭头离地：\(route.arrowGroundClearance * 100, specifier: "%.1f") cm")
                        .font(.caption)
                    Slider(value: $route.arrowGroundClearance, in: 0.005 ... 0.05, step: 0.005)
                }
            }

            if route.phase != .idle {
                Button("清空路线") { Task { await route.clearRoute() } }
                    .foregroundStyle(.red)
            }
        }
        .buttonStyle(.bordered)
        .disabled(route.isBusy)
    }
}
