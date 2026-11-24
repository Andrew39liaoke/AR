import SwiftUI

struct ControlWindow: View {
    @ObservedObject var route: RouteModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @State private var opening = false
    @State private var pendingAction: Action?
    @State private var showDraftDecision = false
    @State private var showSave = false
    @State private var deleteCandidate: SavedRoute?
    private enum Action { case mode(RouteEntryMode?), load(UUID), close }

    var body: some View {
        Group {
            if let request = route.panelAction {
                PanelActionView(route: route, request: request).id(request.id)
            } else {
                mainContent
            }
        }
        .task { await route.refreshLibrary(); await route.refreshHistory() }
        .onChange(of: route.panelAction?.id) { _, id in
            if id != nil {
                showSave = false
                showDraftDecision = false
                pendingAction = nil
                deleteCandidate = nil
            }
        }
        .confirmationDialog("有未保存路线", isPresented: $showDraftDecision, titleVisibility: .visible) {
            if route.canSave { Button("保存路线后继续") { showSave = true } }
            Button("放弃草稿并继续", role: .destructive) { executePending(discard: true) }
            Button("取消", role: .cancel) { pendingAction = nil }
        } message: { Text("未保存的路线仅本次可用。已保存路线不会受影响。") }
        .sheet(isPresented: $showSave) { SaveRouteSheet(route: route) { executePending(discard: false) } }
        .confirmationDialog("删除已保存路线", isPresented: Binding(get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } }), titleVisibility: .visible) {
            Button("永久删除路线及其锚点", role: .destructive) {
                if let id = deleteCandidate?.id { Task { await route.deleteSavedRoute(id) } }
                deleteCandidate = nil
            }
            Button("取消", role: .cancel) { deleteCandidate = nil }
        } message: { Text(deleteCandidate?.name ?? "") }
    }
    private var mainContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("空间箭头导航").font(.largeTitle.bold())
                Text("选择保存的路线，或自己设定一条新路线。录制后保存，下次可在原场景恢复导航。")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("选择已保存路线") { request(.mode(.saved)) }
                    Button("自己设定路线") { request(.mode(.custom)) }
                }.buttonStyle(.borderedProminent).disabled(route.isBusy)
                if route.entryMode == .saved {
                    if let error = route.libraryError {
                        Text("读取路线失败：\(error)").foregroundStyle(.red)
                        Button("重试读取路线") { Task { await route.refreshLibrary() } }
                    } else if route.savedRoutes.isEmpty {
                        Text("暂无已保存路线").foregroundStyle(.secondary)
                    } else {
                        ForEach(route.savedRoutes) { item in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(item.name).font(.headline)
                                    if !item.startDescription.isEmpty { Text(item.startDescription).font(.caption) }
                                    Text("\(item.waypoints.count) 个点 · 已试走 \(item.trialNumber) 次").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("加载路线") { request(.load(item.id)) }
                                Button("删除", role: .destructive) { deleteCandidate = item }
                            }
                        }
                    }
                }
                if route.entryMode != nil {
                    if !route.isImmersivePresented {
                        Button("打开混合沉浸空间") {
                            opening = true
                            Task {
                                let result = await openImmersiveSpace(id: "navigation")
                                if case .opened = result { route.isImmersivePresented = true }
                                opening = false
                            }
                        }.disabled(opening || route.isBusy)
                    }
                    if route.entryMode == .custom || route.savedDefinition != nil { RouteControls(route: route) }
                    if route.isImmersivePresented {
                        Button("结束演示并关闭空间") { request(.close) }.disabled(route.isBusy)
                    }
                    Button("返回路线选择") { request(.mode(nil)) }.disabled(route.isBusy)
                }
                TestHistoryPanel(route: route)
            }.padding(24)
        }
    }
    private func request(_ action: Action) {
        pendingAction = action
        if route.hasUnsavedRoute { showDraftDecision = true } else { executePending(discard: false) }
    }
    private func executePending(discard: Bool) {
        guard let action = pendingAction else { return }
        pendingAction = nil
        Task {
            switch action {
            case .mode(let mode): await route.chooseMode(mode, discardDraft: discard)
            case .load(let id):
                if discard { await route.clearRoute() }
                await route.loadRoute(id)
            case .close:
                if discard { await route.clearRoute() }
                await route.stopTracking()
                await dismissImmersiveSpace()
                route.isImmersivePresented = false
            }
        }
    }
}

/// Compact primary actions, without a scroll container or reserved empty space.
struct MarkerPanel: View {
    @ObservedObject var route: RouteModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(route.phase == .navigating ? "导航中" : "路线标记").font(.subheadline.weight(.semibold))
                Spacer()
                Text(route.phase == .navigating ? "前往第 \(route.targetIndex + 1) 个路点" : "\(route.waypoints.count) 个点")
                    .font(.subheadline).foregroundStyle(route.phase == .navigating ? .primary : .secondary)
            }
            // Keep actions above changing messages so messages do not push buttons down.
            VStack(spacing: 6) {
                switch route.phase {
                case .idle:
                    if route.entryMode == .custom {
                        actionButton("开始标记", enabled: route.isSessionActive) { Task { await route.beginMarking() } }
                    }
                case .markingStart:
                    actionButton("记录起点") { Task { await route.recordStart() } }
                case .marking:
                    HStack(spacing: 6) {
                        actionButton("添加路点") { Task { await route.addTurn() } }
                        actionButton("记录终点") { Task { await route.recordEnd() } }
                    }
                    actionButton("撤销上一个点") { Task { await route.undoLastWaypoint() } }
                case .returning:
                    actionButton("开始导航", enabled: route.canStartNavigation) { Task { await route.startNavigation() } }
                    if route.savedDefinition == nil {
                        actionButton("撤销终点") { Task { await route.undoLastWaypoint() } }
                    } else {
                        actionButton("重新定位") { Task { await route.relocalize() } }
                    }
                case .navigating:
                    actionButton("标记异常") { route.markAnomaly() }
                case .arrived:
                    actionButton("再次试走") { route.repeatNavigation() }
                }
            }
            .disabled(route.isBusy || route.panelAction != nil)
            Text(route.statusText)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let message = route.panelAction == nil ? (route.message ?? route.panelActionFeedback) : route.panelActionFeedback,
               !message.isEmpty {
                Text(message).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            panelActions
        }
        .buttonStyle(.plain)
        .controlSize(.regular)
        .padding(12)
        .frame(width: route.phase == .navigating ? 260 : 280)
        .background(.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder private var panelActions: some View {
        if let request = route.panelAction {
            if request.stage.isCommitting {
                ProgressView(request.stage.message).font(.caption)
            } else {
                HStack(spacing: 8) {
                    auxiliaryButton("打开主窗口") { route.reopenPanelAction() }
                    auxiliaryButton("取消操作") { route.cancelPanelAction(request.id) }
                }
            }
        } else {
            HStack(spacing: 8) {
                auxiliaryButton("返回主页") { route.requestPanelAction(.returnHome) }
                auxiliaryButton(route.savedDefinition == nil ? "保存路线" : "已保存") {
                    route.requestPanelAction(.saveRoute)
                }
                .disabled(!route.canSave)
            }
            .disabled(route.isBusy)
            if route.savedDefinition == nil, !route.isRouteComplete {
                Text("记录终点后可保存路线").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func auxiliaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.caption)
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .controlSize(.small)
        .hoverEffect(.highlight)
    }

    private func actionButton(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.body)
                .frame(maxWidth: .infinity, minHeight: 32)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
        }
        .disabled(!enabled)
    }
}

/// A regular window hosts text input and decisions; the head attachment only publishes requests.
private struct PanelActionView: View {
    @ObservedObject var route: RouteModel
    let request: PanelActionRequest
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @State private var name = ""
    @State private var startDescription = ""
    @State private var editingName = false

    private var showsSaveForm: Bool { request.kind == .saveRoute || editingName }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(request.kind == .returnHome ? "返回主页" : "保存路线").font(.title2.bold())
                Text(route.routeName).font(.headline)
                if request.stage.isCommitting {
                    ProgressView(request.stage.message)
                } else if showsSaveForm, route.canSave {
                    TextField("路线名称", text: $name)
                    TextField("起点位置说明（可选）", text: $startDescription)
                    if let feedback = route.panelActionFeedback { Text(feedback).font(.caption) }
                    HStack {
                        Button("取消") { route.cancelPanelAction(request.id) }
                        Button(request.kind == .returnHome ? "保存并返回主页" : "保存路线") {
                            Task {
                                await route.savePanelRoute(request.id, name: name, startDescription: startDescription,
                                    returnAfterSaving: request.kind == .returnHome)
                            }
                        }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || route.isBusy)
                    }
                } else if request.kind == .returnHome {
                    Text(route.hasUnsavedRoute ? "当前路线尚未保存，返回后将结束本次导航。" : "正在结束本次导航并返回主页。")
                    if let feedback = route.panelActionFeedback { Text(feedback).font(.caption) }
                    if route.canSave {
                        Button("保存路线后返回") {
                            editingName = true
                            route.recordPanelActionEvent("saveFormPresented", id: request.id)
                        }
                    }
                    if route.hasUnsavedRoute {
                        Button("放弃未保存路线并返回", role: .destructive) {
                            Task { await route.returnPanelHome(request.id, discardDraft: true) }
                        }
                    } else {
                        Button("返回主页") { Task { await route.returnPanelHome(request.id) } }
                    }
                    Button("取消") { route.cancelPanelAction(request.id) }
                } else {
                    Text(route.savedDefinition != nil ? "路线已保存。" : "当前路线尚未满足保存条件。")
                    if let feedback = route.panelActionFeedback { Text(feedback).font(.caption) }
                    Button("返回导航") { route.cancelPanelAction(request.id) }
                }
            }
            .buttonStyle(.bordered)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            route.panelActionPresented(request.id)
            if request.kind == .returnHome, !route.hasUnsavedRoute {
                Task { await route.returnPanelHome(request.id) }
            }
        }
        .onDisappear { route.panelActionWindowClosed(request.id) }
        .task(id: request.stage) {
            guard request.stage == .closingSpace else { return }
            route.recordPanelActionEvent("spaceDismissalRequested", id: request.id)
            if route.isImmersivePresented { await dismissImmersiveSpace() }
            route.finishPanelReturn(request.id)
        }
    }
}

struct RouteControls: View {
    @ObservedObject var route: RouteModel
    @State private var showSave = false
    @State private var showCalibration = false
    @State private var showClear = false
    @State private var clearAfterSave = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(route.routeName).font(.headline)
            Text(route.statusText).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            if let message = route.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            Text("已记录 \(route.waypoints.count) 个点").foregroundStyle(.secondary)
            switch route.phase {
            case .idle:
                if route.entryMode == .custom { Button("开始标记") { Task { await route.beginMarking() } }.disabled(!route.isSessionActive) }
            case .markingStart:
                Button("记录起点") { Task { await route.recordStart() } }
            case .marking:
                HStack {
                    Button("添加路点") { Task { await route.addTurn() } }
                    Button("记录终点") { Task { await route.recordEnd() } }
                }
                Button("撤销上一个点") { Task { await route.undoLastWaypoint() } }
            case .returning:
                Button("开始导航") { Task { await route.startNavigation() } }.disabled(!route.canStartNavigation)
                if route.savedDefinition == nil { Button("撤销终点") { Task { await route.undoLastWaypoint() } } }
            case .navigating:
                Text("当前目标：第 \(route.targetIndex + 1) 个点")
            case .arrived:
                Text("已到达").foregroundStyle(.green)
                Button("再次试走") { route.repeatNavigation() }
            }
            if route.canSave { Button("保存路线") { clearAfterSave = false; showSave = true } }
            if route.savedDefinition != nil {
                Text("路线恢复：\(route.loadState.message)").font(.caption)
                if route.loadState == .localizing || route.loadState == .unresolved, !route.missingStartPoints.isEmpty {
                    Text("等待定位：\(route.missingStartPoints)").font(.caption)
                }
                if route.isImmersivePresented { Button("重新定位") { Task { await route.relocalize() } } }
            }
            if !route.waypoints.isEmpty {
                Text("箭头离地：\(route.arrowGroundClearance * 100, specifier: "%.1f") cm").font(.caption)
                Slider(value: $route.arrowGroundClearance, in: 0.005...0.05, step: 0.005)
                if route.isRouteComplete {
                    Button("校准并启用备用地面") { showCalibration = true }
                    if let fallback = route.fallbackReference {
                        Text(fallback.invalidReason.map { "备用地面已失效：\($0)" } ?? (fallback.enabled ? "备用地面已启用，仅限所选范围" : "备用地面已关闭")).font(.caption)
                        if fallback.enabled { Button("关闭备用地面") { route.disableFallback() } }
                        else if fallback.invalidReason == nil { Button("重新启用备用地面") { route.enableFallback() } }
                    }
                }
                Button("标记异常") { route.markAnomaly() }
                Button("清空路线", role: .destructive) {
                    if route.hasUnsavedRoute { showClear = true } else { Task { await route.clearRoute() } }
                }
                Text("清空仅卸载已保存路线；未保存草稿会被放弃。").font(.caption2).foregroundStyle(.secondary)
            }
            DisclosureGroup("显示调试信息") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("设备：\(route.isTrackingDevice ? "正常" : "不可用") · 世界追踪：\(route.providerDescription)")
                    Text("地面 provider：\(route.floorProviderDescription)")
                    Text("会话 \(route.sessionGeneration) / 有效期 \(route.coordinateEpoch)：\(route.coordinateValidity.rawValue)")
                    Text("追踪路点 \(route.trackedWaypointCount)/\(route.waypoints.count) · 当前段 \(route.localSegmentStatus() ? "可用" : "待验证")")
                    Text("地面 \(route.floorPlaneCount) · \(route.layout.statistics.coverage)")
                    Text("箭头 候选 \(route.layout.statistics.candidate) / 放置 \(route.layout.statistics.placed) / 可见 \(route.layout.statistics.visible) / 备用 \(route.layout.statistics.fallback)")
                    Text("全局暂停：\(route.navigationBlockReason.rawValue)")
                    if route.layout.previewUnavailable { Text("下一段尚未定位，预览暂停") }
                    Text("第 \(route.trialNumber) 次 · 丢弃日志 \(route.droppedEventCount)")
                    Text("可保存：\(route.canSave ? "是" : "否") · 忙碌：\(route.isBusy ? "是" : "否")")
                    if let request = route.panelAction {
                        Text("面板操作：\(request.kind.rawValue) / \(request.stage.rawValue)")
                    }
                    if let feedback = route.panelActionFeedback { Text(feedback) }
                    Text(route.logError.map { "日志不完整：\($0)" } ?? "日志正常")
                }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.bordered).disabled(route.isBusy)
        .sheet(isPresented: $showSave) { SaveRouteSheet(route: route) { if clearAfterSave { Task { await route.clearRoute() } } } }
        .sheet(isPresented: $showCalibration) { FloorCalibrationSheet(route: route) }
        .confirmationDialog("处理未保存路线", isPresented: $showClear, titleVisibility: .visible) {
            if route.canSave { Button("保存路线后清空") { clearAfterSave = true; showSave = true } }
            Button("放弃草稿", role: .destructive) { Task { await route.clearRoute() } }
            Button("取消", role: .cancel) {}
        }
    }
}

private struct SaveRouteSheet: View {
    @ObservedObject var route: RouteModel
    var onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var startDescription = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("保存路线").font(.title2)
            TextField("路线名称", text: $name)
            TextField("起点位置说明（可选）", text: $startDescription)
            if let message = route.message { Text(message).font(.caption) }
            HStack {
                Button("取消") { dismiss() }
                Button("保存") {
                    Task {
                        if await route.saveRoute(name: name, startDescription: startDescription) { dismiss(); onSaved() }
                    }
                }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || route.isBusy)
            }
        }.padding(28).frame(width: 420)
    }
}

private struct FloorCalibrationSheet: View {
    struct Range { var from: Double; var to: Double }
    @ObservedObject var route: RouteModel
    @Environment(\.dismiss) private var dismiss
    @State private var ranges: [Int: Range] = [:]
    @State private var confirmed = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("备用地面校准").font(.title2)
                Text("请在已识别地面的位置停下。仅选择你现场确认处于同一平坦楼面的路段，避开台阶、坡道和未知区域。")
                ForEach(1..<max(1, route.waypoints.count), id: \.self) { index in
                    if let segment = route.segment(at: index) {
                        Toggle("P\(index) → P\(index + 1)（\(segment.length, specifier: "%.1f") m）", isOn: Binding(get: { ranges[index] != nil }, set: { ranges[index] = $0 ? Range(from: 0, to: Double(segment.length)) : nil }))
                        if ranges[index] != nil {
                            HStack {
                                TextField("从段首多少米", value: Binding(get: { ranges[index]?.from ?? 0 }, set: { ranges[index]?.from = $0 }), format: .number)
                                TextField("到段首多少米", value: Binding(get: { ranges[index]?.to ?? 0 }, set: { ranges[index]?.to = $0 }), format: .number)
                            }
                        }
                    } else { Text("P\(index) → P\(index + 1)：位置未验证，暂不可选").foregroundStyle(.secondary) }
                }
                Toggle("我已确认所选范围为同一平坦楼面", isOn: $confirmed)
                if let message = route.message { Text(message).font(.caption) }
                HStack {
                    Button("取消") { dismiss() }.disabled(route.isBusy)
                    Button(route.isBusy ? "正在检查稳定性…" : "校准并启用") {
                        Task {
                            await route.calibrateFallback(scopes: ranges.keys.sorted().compactMap { index in ranges[index].map { (index, Float($0.from), Float($0.to)) } }, confirmedFlat: confirmed)
                            if route.fallbackReference?.enabled == true { dismiss() }
                        }
                    }.disabled(!confirmed || ranges.isEmpty || route.isBusy)
                }
            }.padding(28)
        }.frame(width: 500, height: 480)
    }
}

private struct TestHistoryPanel: View {
    @ObservedObject var route: RouteModel
    var body: some View {
        DisclosureGroup("测试记录") {
            VStack(alignment: .leading, spacing: 10) {
                Button("刷新记录") { Task { await route.refreshHistory() } }
                if route.history.isEmpty { Text("暂无试走记录").foregroundStyle(.secondary) }
                ForEach(route.history) { item in
                    HStack {
                        VStack(alignment: .leading) {
                            Text("\(item.routeName) · 第 \(item.trialNumber) 次")
                            Text("\(item.result) · \(item.startedAt.formatted())").font(.caption)
                            if let reason = item.reason { Text(reason).font(.caption) }
                        }
                        Spacer()
                        Button("导出测试记录") { Task { await route.exportLogs(routeID: item.routeID, testRunID: item.id) } }
                    }
                }
                if let url = route.exportURL { ShareLink("分享导出的日志", item: url) }
                if let error = route.logError { Text(error).foregroundStyle(.red).font(.caption) }
            }
        }
    }
}
