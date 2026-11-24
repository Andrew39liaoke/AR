# VisionArrowDemo

visionOS 单楼层空间箭头导航原型，保留 `.mixed` 混合沉浸空间、RealityView 和头部跟随操作面板。阶段 1 实现路线保存、依赖 ARKit 世界锚点的空间恢复，以及当前路段的导航稳定性处理。

## 使用

打开 `VisionArrowDemo.xcodeproj`，选择 `VisionArrowDemo` scheme。真机运行时配置开发团队和 Bundle Identifier，并允许世界感知权限。保存和恢复测试期间应保持同一台 Vision Pro、同一安装和 Bundle Identifier。

首页始终提供两个入口：

- **自己设定路线**：打开混合沉浸空间，开始标记，依次记录起点、至少一个路点、终点。可返回起点直接试走，也可点击“保存路线”输入名称和起点说明。未保存路线标明“仅本次使用”。
- **选择已保存路线**：选择列表中的路线并加载，打开空间，在原起点附近观察环境。起点与第一目标锚点恢复后，回到起点约 0.8 米内开始导航，无需重新录制或预先重走完整路线。远处锚点可以随后恢复。

正常关闭空间、卸载当前路线或设定另一条路线都会保留已保存路线的锚点。永久删除在路线列表中单独确认；失败的锚点删除会保留重试记录。切换入口或主动关闭空间时，未保存草稿需要选择保存、放弃或取消。系统直接关闭空间时无法弹出保存决策，未保存草稿会放弃并在后续启动时清理。

前方“路线标记”面板采用无描边的长方形样式和自适应高度，标记时宽 280 点、导航时宽 260 点，无大块留白，记录操作无需滚动；导航时明确显示“前往第 N 个路点”。面板底部提供较小的“返回主页”和“保存路线”按钮，触碰区域高 38 点。点击后主窗口打开或置前，在主窗口完成名称输入及保存／放弃／取消；完成路线后可在导航前、导航中或到达后保存，成功后显示“已保存”。返回主页会结束本次试走、关闭空间并显示两个路线入口；保存失败不会退出。等待时面板提供“打开主窗口”和“取消操作”，主窗口关闭后可重开继续。地面校准和调试操作位于主窗口。面板中心相对头部为右 0.22 m、下 0.22 m、前 0.55 m，直线距离约 0.63 m。

## 导航行为

- 仅当前路段端点参与当前指引的有效性判断；远处路点没有新更新、失追或移除不会关闭有效的当前路段。到达需要该点的路段前暂停。
- 箭头窗口默认沿路线前方 10 米，覆盖当前段和下一段预览；固定段首偏移 0.325 米、间隔 0.65 米，移动只改变显示范围。
- 地面逐箭头检查。部分地面缺失只隐藏相应箭头；完全无地面时可以开始导航，但暂停箭头显示并提示原因，恢复地面后继续同一次试走。
- 备用地面必须在可靠地面处停稳校准，由用户确认平坦楼面并选择路段和段内范围。参考高度冲突、来源移除、端点变化、清空、重启或坐标异常后失效。它不会跨会话自动恢复。
- 已有路点后设备失追采用保守策略：停止空间指引并中止当前试走。保存路线可点击“重新定位”；未保存草稿须重新设定。单个端点暂时失追可以在坐标仍有效时随新观测恢复。
- **没有自动重新定心检测**。受控实验中先点“标记异常”，再重新定心，之后重新定位或设定路线；该流程不代表 SDK 自动识别了原点变化。

这些箭头不提供避障、自动寻路、跨楼层或长期漂移修正。首次现场验证使用安全、平坦的室内走廊。

## 数据与测试记录

应用沙盒内：

```text
Application Support/
  SavedRoutes/<routeID>/route.json       # 顺序、类型、WorldAnchor UUID、段长、名称、试走次数
  SavedRoutes/ownership.json            # 草稿归属、待删除锚点、删除标记
  NavigationTests/<routeID>/<runID>.json # 试走摘要
  NavigationTests/<routeID>/<appRunID>.jsonl # 事件、设备采样
  NavigationTests/Sessions/             # 尚未关联路线的会话事件
  NavigationTests/Exports/              # 摘要和事件的导出文件
```

路线文件不保存可直接回放的世界坐标。空间恢复只使用 ARKit 当前批次报告的有效锚点位姿；日志中的矩阵仅供诊断，不参与导航。没有独立路线快照功能。导出矩阵为列优先 16 个数值，平移单位为米。

“测试记录”可查看历史和导出指定试走记录；试走次数跨启动保留。调试区显示会话/坐标有效期、当前段、全局暂停原因、地面覆盖、箭头数量及日志失败/丢弃计数。

## 构建与自动化测试

在本目录运行（可用 Xcode 的 Product → Test）：

```sh
xcodebuild -project VisionArrowDemo.xcodeproj -scheme VisionArrowDemo -sdk xros -destination 'generic/platform=visionOS' -derivedDataPath /tmp/visionarrow-device-build CODE_SIGNING_ALLOWED=NO build

xcrun simctl list devices available
xcodebuild -project VisionArrowDemo.xcodeproj -scheme VisionArrowDemo -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -derivedDataPath /tmp/visionarrow-tests CODE_SIGNING_ALLOWED=NO test
```

测试 target 使用可注入的假追踪源、时钟和临时目录，与生产路径共用状态判断、布局和存储代码。模拟器不提供本项目需要的真实 ARKit 追踪；合成测试不能证明真实环境的重定位成功率或定位精度。

逐文件改动、测试范围和现场验收步骤见 [阶段 1 实现与验证记录](stage1-implementation-report.md)。构建号 9 已于 2026-11-08 更新安装于连接的 Vision Pro 真机，保存与返回请求改由主窗口承接，并扩展底部按钮的触碰区域。最终完整 54 项自动化测试通过；两个按钮的真实触碰和窗口操作仍需复测。尚未完成头显现场试走，仍需补做至少 5 次真实的“保存 → 退出进程 → 重开 → 重定位 → 导航”验收。
