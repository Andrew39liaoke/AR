import SwiftUI

enum AppWindow {
    static let mainID = "main"
    static let mainValue = "routeSelection"
}

/// 应用入口。一个 visionOS 应用可以同时提供普通窗口和沉浸空间。
@main
struct VisionArrowDemoApp: App {
    /// 整个应用共用同一个路线模型，窗口和沉浸空间因此能看到相同状态。
    /// `@StateObject` 会让 SwiftUI 在视图刷新时保留这个对象，而不是反复创建。
    @StateObject private var route = RouteModel()

    var body: some Scene {
        // 普通窗口：负责打开沉浸空间，并显示路线记录与导航状态。
        WindowGroup(id: AppWindow.mainID, for: String.self) { _ in
            ControlWindow(route: route)
        } defaultValue: {
            AppWindow.mainValue
        }
        .defaultSize(width: 540, height: 490)

        // 沉浸空间：显示贴近真实地面的箭头和跟随头部的操作面板。
        ImmersiveSpace(id: "navigation") {
            NavigationImmersiveView(route: route)
        }
        // `.mixed` 会保留对现实环境的透视，只在其中叠加虚拟内容。
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}
