# AR 项目仓库

本仓库用于存放 AR / 空间计算相关的研究文档、原型工程和后续实验项目。

README 主要作为仓库的目录导航。以后新增项目文件夹时，可以继续在下方的“目录说明”中补充对应用途。

## 目录结构

```text
AR/
├── VisionArrowDemo/                                  # Apple Vision Pro 空间箭头导航原型
├── visionpro-world-anchored-arrow-navigation-research.md
│                                                      # 原型对应的研究与设计文档
└── README.md                                          # 仓库目录说明
```

## 目录说明

### `VisionArrowDemo/`

Apple Vision Pro 世界固定箭头导航的 visionOS 原型工程。

该目录负责验证以下流程：

- 使用 ARKit 获取设备位置并记录起点、转弯点和终点；
- 使用 `WorldAnchor` 将路线关键点固定在真实空间中；
- 检测地面，并使用 RealityKit 在地面附近绘制方向箭头；
- 引导用户返回起点，再按照记录顺序完成路线导航；
- 在追踪丢失或用户偏离路线时暂停方向提示。

目录内部结构：

```text
VisionArrowDemo/
├── VisionArrowDemo.xcodeproj/       # Xcode 工程配置、构建设置和共享 Scheme
├── VisionArrowDemo/                 # visionOS 应用的 Swift 源代码
│   ├── App.swift                    # 应用入口，创建主窗口和混合沉浸空间
│   ├── ControlWindow.swift          # 路线标记、导航和状态提示界面
│   ├── NavigationImmersiveView.swift # RealityView 及沉浸空间中的控制面板
│   ├── RouteModel.swift             # 路点数据、路线状态和导航推进逻辑
│   ├── RouteRenderer.swift          # 空间箭头和路点标记的 RealityKit 渲染
│   └── WorldTrackingService.swift   # ARKit 世界追踪、世界锚点和地面检测
└── README.md                        # 原型的运行方式、能力范围和安全说明
```

运行该原型时，请先阅读 [`VisionArrowDemo/README.md`](VisionArrowDemo/README.md)。世界追踪和地面检测需要 Apple Vision Pro 真机；模拟器主要用于检查静态界面。

## 根目录文档

[`visionpro-world-anchored-arrow-navigation-research.md`](visionpro-world-anchored-arrow-navigation-research.md) 记录了世界固定箭头导航方案的研究结论、交互流程、技术选型、实现边界和后续扩展方向。

## 后续目录约定

后续增加新的独立实验或应用时，建议每个项目使用单独的顶层文件夹，并在文件夹内提供自己的 `README.md`。根目录 README 只需要补充项目名称、主要职责和入口文档，避免在这里堆积过多实现细节。

建议结构：

```text
AR/
├── VisionArrowDemo/
├── FutureProjectA/
│   └── README.md
├── FutureProjectB/
│   └── README.md
└── README.md
```
