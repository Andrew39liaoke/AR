import SwiftUI

@main
struct VisionArrowDemoApp: App {
    @StateObject private var route = RouteModel()

    var body: some Scene {
        WindowGroup {
            ControlWindow(route: route)
        }
        .defaultSize(width: 540, height: 490)

        ImmersiveSpace(id: "navigation") {
            NavigationImmersiveView(route: route)
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}
