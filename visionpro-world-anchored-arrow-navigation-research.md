# Apple Vision Pro 世界固定箭头导航 Demo：手动标记路线方案

> 更新日期：2026-11-03。本文根据 Apple 官方文档核对关键 API。目标是：**在同一次运行中，手动记录一条室内路线，再用固定在空间中的箭头引导用户试走**。文中的 Swift 片段是关键逻辑示意，完整实现见下方工程。

对应的可编译工程见 [VisionArrowDemo](VisionArrowDemo/README.md)。当前版本已通过 Xcode 26.3 的 visionOS 设备 SDK 编译，并已安装到 Vision Pro 真机（构建号 3）；地面贴附效果仍需在头显中试走验证。

**可行性结论：** 这个范围内的 Demo 可以实现。设备位置查询、世界锚点、RealityKit 渲染和混合沉浸空间分别覆盖了所需能力。`.mixed` 沉浸模式没有 `.progressive` / `.full` 模式约 1.5 米的移动边界，但仍需控制箭头遮挡并在安全区域试走。[Immersive experiences](https://developer.apple.com/design/human-interface-guidelines/immersive-experiences)

## 1. 第一版到底做什么

| 问题 | 做法 |
| --- | --- |
| 需要预先扫描或录制整个房间吗？ | **不用。** 戴上头显沿已确认安全的路线走一遍，在起点、转弯点和终点分别按按钮。应用保存的是一串空间位置，不是视频或房间地图。 |
| 应用怎么知道起点、终点？ | 第一次按“记录起点”时保存头显位置；沿途按“添加路点”；最后按“记录终点”。设备姿态由 `WorldTrackingProvider.queryDeviceAnchor(atTimestamp:)` 提供。[Apple 设备姿态 API](https://developer.apple.com/documentation/arkit/worldtrackingprovider/querydeviceanchor%28attimestamp%3A%29) |
| 箭头为什么能固定不动？ | 每个关键路点注册为 ARKit `WorldAnchor`，用其最新世界姿态生成箭头，在沉浸空间的 `RealityView` 中放置。导航时设备位置只用于判断进度，不把箭头重新放到眼前。[Tracking specific points in world space](https://developer.apple.com/documentation/visionos/tracking-points-in-world-space) |

**边界：** 第一版针对一间房或短走廊、少量路点、单次运行；没有自动寻路、障碍检测或跨启动恢复。`WorldAnchor` 虽能由 ARKit 持久保存，第一版不恢复路线；重录或结束路线时应清理不再使用的锚点。它也不是经纬度导航：Apple 指出 visionOS ARKit 没有 iOS geotracking／经纬度锚点的等价 API。[Bringing your ARKit app to visionOS](https://developer.apple.com/documentation/visionos/bringing-your-arkit-app-to-visionos)

## 2. 用户如何标记与试走

以“门口 → 转弯处 → 桌子”为例：

1. **进入记录模式。** 在应用窗口按“开始标记”，打开 `.mixed` `ImmersiveSpace`。混合沉浸空间同时显示环境透视与 3D 内容，ARKit 数据只在应用呈现 Full Space 时可用。[Immersive spaces](https://developer.apple.com/documentation/swiftui/immersive-spaces) · [设置 ARKit 访问](https://developer.apple.com/documentation/visionos/setting-up-access-to-arkit-data)
2. **站在门口，按“记录起点”。** 程序保存这一刻的设备世界位置，以其水平坐标近似表示**人所站的位置**；它不是脚底的精确位置，也不是眼睛注视或手指指向的位置。[设备姿态 API](https://developer.apple.com/documentation/arkit/worldtrackingprovider/querydeviceanchor%28attimestamp%3A%29)
3. **走到转弯处，停下并按“添加路点”。** 可重复添加多个点；界面显示已记录数量，并提供“撤销上一个点”。太近的重复路点应拒绝记录。
4. **走到桌子旁，按“记录终点”。** 应用预览已识别地面区域内的路线及箭头，允许调整箭头离地间隙或重录错误路点。
5. **返回起点。** 记录结束时人站在终点，必须先沿已确认安全的路线返回起点；回到起点允许范围后才能按“开始导航”试走。
6. **沿箭头试走。** 接近当前目标路点后，应用高亮下一段；抵达终点时显示“已到达”。

第一版保留简洁的 SwiftUI 窗口用于开始、状态和错误提示；沿途标记需要一个人走到转弯处后仍能找到的控制面板。可在混合沉浸空间中放一个小型标记面板，让它随用户位置移动或按需出现在用户面前，站稳后再交互；不要只把标记按钮放在起点的固定窗口中。面板和箭头都应避免遮挡真实路面。`WindowGroup`、`ImmersiveSpace`、`openImmersiveSpace` 是 Apple 官方示例采用的结构；Apple 也提供了头部锚定实体的示例，可供面板定位参考。[Adding 3D content to your app](https://developer.apple.com/documentation/visionos/adding-3d-content-to-your-app/) · [Placing entities using head and device transform](https://developer.apple.com/documentation/visionos/placing-entities-using-head-and-device-transform)

## 3. 记录的数据与箭头生成

核心数据是**有序路点列表和本次路线的锚点 ID**，不是一段环境影像：

```text
路线 A
  0: 起点    (WorldAnchor UUID, 最新姿态)
  1: 转弯点  (WorldAnchor UUID, 最新姿态)
  2: 终点    (WorldAnchor UUID, 最新姿态)
```

每次按标记按钮，确认 `WorldTrackingProvider` 正在运行，调用 `queryDeviceAnchor(atTimestamp: CACurrentMediaTime())` 读取**当前**设备姿态。如果返回 `nil` 或 `DeviceAnchor.isTracked == false`，拒绝本次标记并提示等待追踪恢复。拿到姿态后检查与上一点的水平距离，再注册 `WorldAnchor`；注册失败不能算作成功路点。[queryDeviceAnchor](https://developer.apple.com/documentation/arkit/worldtrackingprovider/querydeviceanchor%28attimestamp%3A%29) · [DeviceAnchor](https://developer.apple.com/documentation/arkit/deviceanchor) · [WorldAnchor](https://developer.apple.com/documentation/arkit/worldanchor)

```swift
// 标记按钮的核心逻辑示意；省略异步状态管理、距离检查和错误 UI。
guard worldTracking.state == .running,
      let device = worldTracking.queryDeviceAnchor(
          atTimestamp: CACurrentMediaTime()
      ), device.isTracked else {
    showTrackingUnavailable()
    return
}

let anchor = WorldAnchor(originFromAnchorTransform: device.originFromAnchorTransform)
try await worldTracking.addAnchor(anchor)
// 注册成功后，记录 anchor.id 与路点顺序；位置以 anchorUpdates 的最新姿态为准。
```

记录成功后，保存 `anchor.id → 路点顺序/类型`。消费 `WorldTrackingProvider.anchorUpdates`：`.added` / `.updated` 时使用锚点的最新 `originFromAnchorTransform` 更新路点；`.removed` 或 `isTracked == false` 时，将相关路段标记为不可用并暂停可信的方向提示。撤销路点或重录路线时清理对应的 ARKit 锚点。世界原点发生变化时也以**最新锚点姿态**重新计算路线，不沿用先前缓存的绝对坐标。[Tracking specific points in world space](https://developer.apple.com/documentation/visionos/tracking-points-in-world-space)

箭头方向由相邻路点的**最新位置**算出：从 `P₀` 指向 `P₁` 时，用 `P₁ - P₀` 的水平分量计算朝向；到 `P₁` 后再指向 `P₂`。因此不需要用户按按钮时特意看向下一段。路段太短时拒绝记录或不生成箭头，避免零长度方向；路段较长时沿线段插入若干箭头。用户应在实际转弯和绕开家具的位置补点，不自动越过墙或家具。

路点记录的是**设备高度**。最初版本用“设备高度减固定值”估算箭头高度，容易让箭头悬空。当前工程增加 `PlaneDetectionProvider`：只接收被 ARKit 分类为水平地面的平面，用其最新姿态与范围估计每个箭头所在处的地面高度；箭头中心默认放在地面上方约 1 厘米，避免模型与地面重叠闪烁。没有识别到附近地面时，该处不显示箭头。世界锚点与地面平面更新时都会重算箭头位置。地面分类及覆盖范围仍可能不完整，台阶、坡道和跨房间路线需要进一步处理；离地间隙、大小、间距和模型前向轴都需在真机调整。[Placing content on detected planes](https://developer.apple.com/documentation/visionos/placing-content-on-detected-planes)

## 4. 世界固定与导航推进

```text
按按钮记录路点 → 注册 WorldAnchor → 消费 anchorUpdates → 用最新路点生成箭头
                                                ↓
持续读取设备位置 → 检查起点/当前路段/下一路点 → 更新提示与高亮
```

在混合沉浸空间中，`RealityView` 的 scene 坐标与 ARKit 世界原点对应；可按最新路点位置给箭头实体设置世界姿态。`AnchorEntity(world:)` 适合初步验证固定位置，但它接收的一个变换矩阵不能代替 ARKit `WorldAnchor` 的更新流。正式 Demo 应保留关键路点的 ARKit 锚点，并在其姿态变化时更新或重建对应箭头。实体创建后复用，只有路线、锚点姿态或高亮状态变化时才修改实体。[RealityCoordinateSpace.scene](https://developer.apple.com/documentation/realitykit/realitycoordinatespace/scene) · [AnchorEntity(world:)](https://developer.apple.com/documentation/realitykit/anchorentity/init%28world%3A%29-4snw2)

导航时通过 RealityKit `System` 或独立更新任务持续查询设备当前位置；`RealityView` 的 `update` 闭包在视图状态变化时运行，不能单独承担逐帧位置采样。位置采样与 SwiftUI 文本刷新可以采用不同频率。[Placing entities using head and device transform](https://developer.apple.com/documentation/visionos/placing-entities-using-head-and-device-transform) · [RealityView init(make:update:)](https://developer.apple.com/documentation/realitykit/realityview/init%28make%3Aupdate%3A%29-666xr)

开始导航前，确认用户已回到起点附近。导航中只检查**当前路段的下一个路点**：水平距离小于初始阈值（如 `0.7 m`）时，再结合用户沿当前路段的进展和横向偏离决定是否切换；转角处不能只凭“离下一点近”就提前指向后段。路段只按顺序推进，明显偏离时提示返回路线。这个阈值和偏离范围需要真机实测，尤其要避免连续跳过密集路点。不能因用户看向箭头就判定到达；设备或所需路点追踪不可用时，暂停进度和方向提示。[设备姿态 API](https://developer.apple.com/documentation/arkit/worldtrackingprovider/querydeviceanchor%28attimestamp%3A%29)

标记和试走只应在受控、无障碍的室内区域进行。第一版不会识别墙、家具、门槛或后来出现的障碍，箭头只是视觉辅助。Apple 建议混合沉浸内容不要过多遮挡环境透视，尤其当用户需要移动时。[Immersive experiences](https://developer.apple.com/design/human-interface-guidelines/immersive-experiences)

## 5. 技术组成与限制

| 组件 | 第一版职责 |
| --- | --- |
| SwiftUI `WindowGroup` + 沿途控制面板 | 开始、标记、撤销、路点数量与错误提示；沿途控制应始终可找回。 |
| `.mixed` `ImmersiveSpace` + RealityKit `RealityView` | 在环境透视中显示路点、箭头和必要的控制面板。[Immersive spaces](https://developer.apple.com/documentation/swiftui/immersive-spaces) |
| ARKit `ARKitSession` + `WorldTrackingProvider` | 启动世界追踪，查询设备位置，接收世界锚点更新。[Tracking specific points in world space](https://developer.apple.com/documentation/visionos/tracking-points-in-world-space) |
| ARKit `WorldAnchor` | 追踪关键路点，提供空间重定位后的最新姿态；第一版不做跨启动路线恢复。 |
| ARKit `PlaneDetectionProvider` | 识别水平地面，提供箭头的贴地高度；未覆盖区域暂不显示箭头。 |
| 位置更新循环 | 持续采样设备姿态，判断当前路段进度；不依赖 `RealityView.update` 逐帧调用。 |
| 路线状态 | 管理“未开始 → 记录中 → 已完成 → 返回起点 → 导航中 → 已到达／暂停”。 |

**权限：** 单用 world tracking 不要求 world sensing 授权；当前工程已加入平面检测，因此配置了 `NSWorldSensingUsageDescription`，首次运行时需允许世界感知权限。[设置 ARKit 访问](https://developer.apple.com/documentation/visionos/setting-up-access-to-arkit-data)

**设备：** Apple 的 `DataProvider.isSupported` 文档指出 ARKit data providers 在 Simulator 中不受支持。可以用模拟器检查静态界面，但世界追踪和箭头固定效果必须在 Vision Pro 真机验证。[DataProvider.isSupported](https://developer.apple.com/documentation/arkit/dataprovider/issupported)

建议的项目文件：

```text
VisionArrowDemo/
  App.swift                     // WindowGroup + ImmersiveSpace(.mixed)
  RouteState.swift              // 路点顺序、锚点 ID、记录与导航状态
  WorldTrackingService.swift    // ARKitSession、设备姿态和锚点更新
  NavigationImmersiveView.swift // RealityView、控制面板、箭头与高亮
  NavigationUpdateSystem.swift  // 持续位置采样与进度判断（或独立任务）
  Arrow.usdz                    // 首版也可用简单几何代替
```

## 6. 第一版验收

- 在安全、平坦的室内区域标记一条“起点 → 转角 → 终点”的 L 形路线；沿途都能找到标记操作，错误路点可撤销，过近的重复路点会被拒绝。
- 记录完成后只有回到起点附近才能开始导航；沿第一段移动时显示指向转角的箭头，经过转角才切换到终点，终点显示“已到达”。
- 横向移动、转头再回望，箭头仍与实际标记位置对齐；每段箭头的朝向与记录的路线一致。
- 在受控条件下长按 Digital Crown 重定位后，路点与箭头应跟随锚点更新到正确位置；若更新暂不可用，暂停导航，不继续显示可信方向。[Tracking specific points in world space](https://developer.apple.com/documentation/visionos/tracking-points-in-world-space)
- 设备追踪或当前路段所需的世界锚点不可用时，不能记录路点，也不推进导航；恢复后可继续。
- 箭头在已识别区域贴近地面，在未识别区域隐藏，同时不挡住真实路面和障碍；到达阈值、偏离范围、箭头离地间隙与间距用真机试走校准。

这仍是 **Demo 验收**：标记点之间没有环境可通行性证明，也不会检测后来出现的障碍。配套工程已通过编译，本次地面贴附效果必须在 Vision Pro 真机检查。

## 7. 后续扩展：保存多条路线，下次选择后显示箭头

**可以实现。** ARKit 会为同一应用保留已添加的 `WorldAnchor` 标识和空间姿态；应用自己保存路线名称、路点顺序、各路点的锚点 UUID 和显示参数。下次打开时，路线名称可以立即出现在列表中；选择一条路线后，应用启动世界追踪，按 UUID 接收该路线锚点的最新姿态，再生成世界固定箭头。[Tracking specific points in world space](https://developer.apple.com/documentation/visionos/tracking-points-in-world-space) · [WorldAnchor](https://developer.apple.com/documentation/arkit/worldanchor)

建议的本地记录格式如下。一个路点的 UUID 只归属于一条路线；保存路线时保留其世界锚点，删除路线时才逐个移除对应锚点。

```text
路线 ID、名称、创建时间、离地间隙
  路点 0：起点，WorldAnchor UUID
  路点 1：转弯点，WorldAnchor UUID
  路点 2：终点，WorldAnchor UUID
```

选择后的状态应分清楚：**等待环境定位 → 找到附近锚点 → 显示已定位且有地面数据的路段 → 路线可导航**。ARKit 只会回报当前附近的锚点，因此人在另一间房或另一个地点时，列表仍可显示路线，但不能安全地把上次保存的绝对坐标直接画成箭头；进入路线所在区域、重新识别环境后才能显示。较长路线的远端锚点可能尚未回报，界面应标明“已定位 2/5 个路点”，允许先显示可信的局部路段，并在剩余锚点出现后补齐。地面平面也要重新检测；尚未识别地面的地方继续隐藏贴地箭头。导航开始前还需确认起点或当前路段已经定位，且用户处于合理的进入位置。[Tracking specific points in world space](https://developer.apple.com/documentation/visionos/tracking-points-in-world-space) · [Placing content on detected planes](https://developer.apple.com/documentation/visionos/placing-content-on-detected-planes)

**当前工程尚未实现这个扩展。** `RouteModel` 只维护内存中的一条路线，`stopTracking()` 会调用 `clearRoute()` 删除本次锚点，`beginMarking()` 也会清空旧路线。实现多路线时，需要加入本地路线库和选择界面；保存后退出不能删锚点；再次启动时要在处理锚点更新前建立 UUID 到路线/路点的索引，并从 `anchorUpdates`（必要时结合 `allAnchors`）恢复姿态。当前“所有路点都已追踪才允许导航”的判断也要改为支持局部显示、明确提示未定位路段，但不能用旧坐标补画缺失箭头。Apple 说明世界锚点持久化在某些情况下可能不可用，因此应提供“重新定位失败／重新记录路线”的状态和操作。[WorldTrackingProvider](https://developer.apple.com/documentation/arkit/worldtrackingprovider) · [Meet ARKit for spatial computing](https://developer.apple.com/videos/play/wwdc2023/10082/)

地面平面检测已加入当前工程。更精确的地面几何贴合、避障和路径规划属于后续阶段，可分别研究 `SceneReconstructionProvider` 和室内地图/路径算法；世界锚点本身不提供这些能力。[ARKit in visionOS](https://developer.apple.com/documentation/arkit/arkit-in-visionos)

## 官方资料

1. [Setting up access to ARKit data](https://developer.apple.com/documentation/visionos/setting-up-access-to-arkit-data)：Full Space、授权、用途说明。
2. [WorldTrackingProvider](https://developer.apple.com/documentation/arkit/worldtrackingprovider) 与 [queryDeviceAnchor(atTimestamp:)](https://developer.apple.com/documentation/arkit/worldtrackingprovider/querydeviceanchor%28attimestamp%3A%29)：设备姿态与世界追踪。
3. [AnchorEntity(world:)](https://developer.apple.com/documentation/realitykit/anchorentity/init%28world%3A%29-4snw2) 与 [RealityView](https://developer.apple.com/documentation/realitykit/realityview)：3D 箭头放置。
4. [Tracking specific points in world space](https://developer.apple.com/documentation/visionos/tracking-points-in-world-space)：世界锚点、持久化和重定位。
5. [DataProvider.isSupported](https://developer.apple.com/documentation/arkit/dataprovider/issupported)：模拟器限制。
6. [Placing entities using head and device transform](https://developer.apple.com/documentation/visionos/placing-entities-using-head-and-device-transform)：设备位置采样、RealityKit `System`、头部锚定实体。
7. [RealityView init(make:update:)](https://developer.apple.com/documentation/realitykit/realityview/init%28make%3Aupdate%3A%29-666xr) 与 [RealityCoordinateSpace.scene](https://developer.apple.com/documentation/realitykit/realitycoordinatespace/scene)：视图更新时机和沉浸空间中的世界坐标。
8. [Immersive experiences](https://developer.apple.com/design/human-interface-guidelines/immersive-experiences)：混合沉浸空间的移动边界与环境透视设计。
