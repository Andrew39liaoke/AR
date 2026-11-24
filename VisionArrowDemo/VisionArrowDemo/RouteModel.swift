import Combine
import Foundation
import simd

enum PanelActionKind: String { case saveRoute, returnHome }
enum PanelActionStage: String {
    case waitingForWindow, awaitingUser, saving, returningHome, closingSpace
    var isCommitting: Bool { self == .saving || self == .returningHome || self == .closingSpace }
    var message: String {
        switch self {
        case .waitingForWindow: return "正在打开主窗口…"
        case .awaitingUser: return "请在主窗口完成操作"
        case .saving: return "保存中…"
        case .returningHome, .closingSpace: return "返回中…"
        }
    }
}
struct PanelActionRequest: Identifiable {
    let id: UUID
    let kind: PanelActionKind
    let routeID: UUID?
    var stage: PanelActionStage = .waitingForWindow
}

@MainActor
final class RouteModel: ObservableObject {
    private let tracking: any TrackingSource
    let store: RouteStore
    let recorder: NavigationTestRecorder
    private let now: () -> TimeInterval
    private let automaticSampling: Bool
    var configuration: NavigationConfiguration
    let appRunID = UUID()
    private var samplingTask: Task<Void, Never>?
    private var stopOperation: Task<Void, Never>?
    private var logTask: Task<Void, Never>?
    private var pendingLogCount = 0
    private var sequence = 0
    private var callbackToken = 0
    private var isStarting = false
    private var requiresRelocalization = false
    private var deviceWasTracked = false
    private var observationCache: [UUID: WaypointObservation] = [:]
    private var registeredIDs: Set<UUID> = []
    private var segmentLengths: [Float] = []
    private var floorSurfaces: [UUID: FloorSurface] = [:]
    private var offRouteSince: TimeInterval?
    private var localizationStarted: TimeInterval?
    private var localizationAttemptID: UUID?
    private var waitingForNextIndex: Int?
    private var sampleCounter = 0
    private var lastBlockReason: NavigationBlockReason = .none
    private var lastCoverage = "notEvaluated"
    private var runDropBaseline = 0

    @Published private(set) var entryMode: RouteEntryMode?
    @Published private(set) var phase: RoutePhase = .idle
    @Published private(set) var waypoints: [RouteWaypoint] = []
    @Published private(set) var targetIndex = 1
    @Published private(set) var currentPosition: SIMD3<Float>?
    @Published private(set) var isTrackingDevice = false
    @Published private(set) var isSessionActive = false
    @Published var isImmersivePresented = false
    @Published private(set) var isOffRoute = false
    @Published private(set) var isBusy = false
    @Published private(set) var message: String?
    @Published private(set) var routeRevision = 0
    @Published private(set) var renderTick = 0
    @Published private(set) var routeID: UUID?
    @Published private(set) var savedDefinition: SavedRoute?
    @Published private(set) var savedRoutes: [SavedRoute] = []
    @Published private(set) var libraryError: String?
    @Published private(set) var loadState: RouteLoadState = .none
    @Published private(set) var coordinateValidity: CoordinateValidity = .needsRevalidation
    @Published private(set) var sessionGeneration = 0
    @Published private(set) var coordinateEpoch = 0
    @Published private(set) var providerDescription = "未启动"
    @Published private(set) var floorProviderDescription = "未启动"
    @Published private(set) var fallbackReference: FallbackFloorReference?
    @Published private(set) var layout = NavigationLayout()
    @Published private(set) var currentRun: NavigationRunSummary?
    @Published private(set) var trialNumber = 0
    @Published private(set) var logError: String?
    @Published private(set) var droppedEventCount = 0
    @Published private(set) var history: [NavigationRunSummary] = []
    @Published private(set) var exportURL: URL?
    @Published private(set) var panelAction: PanelActionRequest?
    @Published private(set) var panelActionWindowRequestID: UUID?
    @Published private(set) var panelActionFeedback: String?
    @Published var arrowGroundClearance = 0.01 { didSet { refreshLayout() } }

    init(tracking: (any TrackingSource)? = nil, store: RouteStore = RouteStore(),
         recorder: NavigationTestRecorder = NavigationTestRecorder(),
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         automaticSampling: Bool = true, configuration: NavigationConfiguration = NavigationConfiguration()) {
        self.tracking = tracking ?? WorldTrackingService()
        self.store = store
        self.recorder = recorder
        self.now = now
        self.automaticSampling = automaticSampling
        self.configuration = configuration
    }

    var hasUnsavedRoute: Bool { savedDefinition == nil && !waypoints.isEmpty }
    var isPanelActionCommitting: Bool { panelAction?.stage.isCommitting == true }
    var isRouteComplete: Bool { waypoints.count >= 3 && waypoints.first?.kind == .start && waypoints.last?.kind == .end }
    var canSave: Bool { hasUnsavedRoute && isRouteComplete && segmentLengths.count == waypoints.count - 1 && Set(waypoints.map(\.id)).isSubset(of: registeredIDs) }
    var hasDetectedFloor: Bool { !floorSurfaces.isEmpty }
    var floorPlaneCount: Int { floorSurfaces.count }
    var trackedWaypointCount: Int { waypoints.filter { $0.isTracked && $0.sessionGeneration == sessionGeneration && $0.coordinateEpoch == coordinateEpoch }.count }
    var hasTrackedRoute: Bool { waypoints.count >= 3 && trackedWaypointCount == waypoints.count }
    var activeTarget: Int { phase == .marking ? max(1, waypoints.count - 1) : targetIndex }
    var routeName: String { savedDefinition?.name ?? "自己设定的路线（仅本次使用）" }
    var missingStartPoints: String {
        waypoints.indices.prefix(2).filter { candidatePosition($0) == nil }.map { "P\($0 + 1)" }.joined(separator: "、")
    }
    var canStartNavigation: Bool {
        guard phase == .returning, !isBusy, isRouteComplete, coordinateValidity == .usable,
              isTrackingDevice, tracking.isRunning, segment(at: 1) != nil,
              let currentPosition, let start = candidatePosition(0) else { return false }
        return horizontalDistance(currentPosition, start) <= configuration.startDistance
    }
    var navigationBlockReason: NavigationBlockReason {
        guard tracking.isRunning else { return .providerUnavailable }
        guard isTrackingDevice else { return .deviceTrackingUnavailable }
        guard coordinateValidity == .usable else { return .coordinateFrameUncertain }
        guard segment(at: activeTarget) != nil else { return .localSegmentUnavailable }
        if let waitingForNextIndex, segment(at: waitingForNextIndex) == nil { return .localSegmentUnavailable }
        return isOffRoute ? .offRoute : .none
    }
    var statusText: String {
        if requiresRelocalization { return savedDefinition == nil ? "暂停空间引导：位置需要重新确认，请重新设定路线。" : "暂停空间引导：请点击重新定位，在原起点附近观察环境。" }
        if phase == .idle { return entryMode == .custom ? "打开空间后开始标记路线。" : "请选择已保存路线，或自己设定路线。" }
        if !isTrackingDevice { return "暂停空间引导：设备位置不可用，请站稳并等待追踪。" }
        if phase == .markingStart { return "走到起点并停下，记录起点。" }
        if phase == .marking { return "走到转弯处添加路点，最后记录终点。" }
        if phase == .arrived { return "已到达终点。可返回起点再次试走。" }
        if loadState == .unresolved { return "起始路段尚未定位。\(missingStartPoints.isEmpty ? "路段几何需要重新验证。" : "等待 \(missingStartPoints)。")请在原起点附近继续观察环境，或重新定位。" }
        if navigationBlockReason != .none { return "暂停空间引导：\(navigationBlockReason.message)。" }
        if layout.statistics.coverage == "unavailable" { return "暂停空间箭头显示：当前区域无可用地面高度。" }
        if phase == .returning { return "回到起点 0.8 米内后开始导航；无需重走已保存路线。" }
        return "朝第 \(targetIndex + 1) 个点前进。\(layout.statistics.coverage == "partial" ? "部分区域地面未识别。" : "")"
    }

    func refreshLibrary() async {
        do { savedRoutes = try await store.list(); libraryError = nil }
        catch { libraryError = error.localizedDescription }
    }

    /// The attachment publishes an intent. A regular window owns the actual form and return flow.
    @discardableResult
    func requestPanelAction(_ kind: PanelActionKind) -> Bool {
        let operationID = panelAction?.id ?? UUID()
        log("ui.buttonTapped", fields: ["button": kind.rawValue, "source": "markerPanel",
            "operationID": operationID.uuidString,
            "phase": String(describing: phase), "canSave": String(canSave),
            "isBusy": String(isBusy), "isSaved": String(savedDefinition != nil),
            "returningHome": String(panelAction?.kind == .returnHome && isPanelActionCommitting)])
        guard !isBusy, !isPanelActionCommitting else {
            panelActionFeedback = "正在处理操作，请稍候。"
            log("ui.actionRejected", fields: ["reason": "busy", "operationID": operationID.uuidString])
            return false
        }
        guard panelAction == nil else { reopenPanelAction(); return false }
        guard kind != .saveRoute || canSave else {
            panelActionFeedback = savedDefinition != nil ? "该路线已保存。" : "请先完成路线并等待记录成功。"
            log("ui.actionRejected", fields: ["reason": "cannotSave", "operationID": operationID.uuidString])
            return false
        }
        panelAction = PanelActionRequest(id: operationID, kind: kind, routeID: routeID)
        panelActionFeedback = "正在打开主窗口…"
        panelActionWindowRequestID = UUID()
        recordPanelActionEvent("requested", id: panelAction!.id)
        return true
    }
    func reopenPanelAction() {
        guard let request = panelAction, !request.stage.isCommitting else { return }
        panelActionWindowRequestID = UUID()
        panelActionFeedback = "正在重新打开操作窗口…"
        recordPanelActionEvent("windowReopenRequested", id: request.id)
    }
    func panelActionWindowRequested(_ token: UUID) {
        guard token == panelActionWindowRequestID, let request = panelAction else { return }
        recordPanelActionEvent("windowOpenRequested", id: request.id)
    }
    func checkPanelActionPresentation(_ token: UUID) {
        guard token == panelActionWindowRequestID, let request = panelAction,
              request.stage == .waitingForWindow else { return }
        panelActionFeedback = "主窗口尚未显示，请点“打开主窗口”重试。"
        recordPanelActionEvent("windowPresentationPending", id: request.id)
    }
    func panelActionPresented(_ id: UUID) {
        guard let request = panelAction, request.id == id else { return }
        guard request.routeID == routeID else { cancelPanelAction(id, reason: "routeChanged"); return }
        if request.stage == .waitingForWindow {
            panelAction?.stage = .awaitingUser
            panelActionFeedback = "请在主窗口完成操作。"
            recordPanelActionEvent("presented", id: id)
        }
    }
    func panelActionWindowClosed(_ id: UUID) {
        guard let request = panelAction, request.id == id else { return }
        recordPanelActionEvent("windowClosed", id: id)
        if !request.stage.isCommitting {
            panelAction?.stage = .waitingForWindow
            panelActionFeedback = "操作尚未完成，可重新打开主窗口或继续处理。"
        }
    }
    func cancelPanelAction(_ id: UUID, reason: String = "userCancelled") {
        guard panelAction?.id == id, !isPanelActionCommitting else { return }
        recordPanelActionEvent("cancelled", id: id, fields: ["reason": reason])
        panelAction = nil
        panelActionWindowRequestID = nil
        panelActionFeedback = "操作已取消。"
    }
    func recordPanelActionEvent(_ event: String, id: UUID, fields: [String: String] = [:]) {
        guard let request = panelAction, request.id == id else { return }
        var details = fields
        details["operationID"] = id.uuidString
        details["action"] = request.kind.rawValue
        details["stage"] = request.stage.rawValue
        details["requestedRouteID"] = request.routeID?.uuidString ?? ""
        log("ui.\(event)", fields: details)
    }
    @discardableResult
    func savePanelRoute(_ id: UUID, name: String, startDescription: String, returnAfterSaving: Bool = false) async -> Bool {
        guard let request = panelAction, request.id == id, !request.stage.isCommitting,
              !isBusy, request.routeID == routeID,
              !returnAfterSaving || request.kind == .returnHome else { return false }
        guard canSave else {
            panelActionFeedback = "当前路线无法保存，请检查是否已完成或已经保存。"
            recordPanelActionEvent("saveRejected", id: id)
            return false
        }
        panelAction?.stage = .saving
        panelActionFeedback = "保存中…"
        recordPanelActionEvent("saveStarted", id: id)
        let saved = await saveRoute(name: name, startDescription: startDescription)
        guard panelAction?.id == id else { return false }
        guard saved else {
            panelAction?.stage = .awaitingUser
            panelActionFeedback = message ?? "保存失败，请重试。"
            recordPanelActionEvent("saveFailed", id: id, fields: ["reason": panelActionFeedback ?? ""])
            return false
        }
        recordPanelActionEvent("saveSucceeded", id: id)
        if returnAfterSaving { return await performPanelReturn(id, discardDraft: false) }
        finishPanelAction(id, feedback: "路线已保存。")
        return true
    }
    @discardableResult
    func returnPanelHome(_ id: UUID, discardDraft: Bool = false) async -> Bool {
        guard let request = panelAction, request.id == id, request.kind == .returnHome,
              !request.stage.isCommitting, !isBusy, request.routeID == routeID else { return false }
        return await performPanelReturn(id, discardDraft: discardDraft)
    }
    private func performPanelReturn(_ id: UUID, discardDraft: Bool) async -> Bool {
        panelAction?.stage = .returningHome
        panelActionFeedback = "返回中…"
        recordPanelActionEvent("returnStarted", id: id)
        let returned = await returnToRouteSelection(discardDraft: discardDraft)
        guard panelAction?.id == id else { return false }
        guard returned else {
            panelAction?.stage = .awaitingUser
            panelActionFeedback = message ?? "返回未完成，请重试或取消。"
            recordPanelActionEvent("returnFailed", id: id)
            return false
        }
        panelAction?.stage = .closingSpace
        recordPanelActionEvent("modelCleanupCompleted", id: id)
        return true
    }
    func finishPanelReturn(_ id: UUID) {
        guard panelAction?.id == id, panelAction?.stage == .closingSpace else { return }
        isImmersivePresented = false
        recordPanelActionEvent("spaceDismissalCompleted", id: id)
        finishPanelAction(id, feedback: "已返回主页。")
    }
    private func finishPanelAction(_ id: UUID, feedback: String) {
        guard panelAction?.id == id else { return }
        recordPanelActionEvent("completed", id: id)
        panelAction = nil
        panelActionWindowRequestID = nil
        panelActionFeedback = feedback
    }
    func chooseMode(_ mode: RouteEntryMode?, discardDraft: Bool = false) async {
        guard !isBusy else { return }
        guard !hasUnsavedRoute || discardDraft else { message = "请先保存或明确放弃未保存路线。"; return }
        await clearRoute()
        entryMode = mode
        message = nil
        if mode == .saved { await refreshLibrary() }
    }
    @discardableResult
    func returnToRouteSelection(discardDraft: Bool = false) async -> Bool {
        guard !isBusy else { return false }
        guard !hasUnsavedRoute || discardDraft else {
            message = "请先保存或明确放弃未保存路线。"
            return false
        }
        log("returnToRouteSelection")
        await chooseMode(nil, discardDraft: discardDraft)
        guard entryMode == nil, waypoints.isEmpty else { return false }
        isBusy = true
        defer { isBusy = false }
        await stopTracking()
        return true
    }
    func loadRoute(_ id: UUID) async {
        guard !isBusy, !hasUnsavedRoute else { message = "请先保存或放弃草稿。"; return }
        await clearRoute()
        isBusy = true
        defer { isBusy = false }
        loadState = .loadingDefinition
        do {
            let definition = try await store.load(id)
            savedDefinition = definition
            routeID = id
            entryMode = .saved
            segmentLengths = definition.segmentLengths
            waypoints = definition.waypoints.map { RouteWaypoint(id: $0.id, kind: $0.kind) }
            trialNumber = definition.trialNumber
            phase = .returning
            requiresRelocalization = false
            coordinateValidity = .needsRevalidation
            beginLocalization()
            for observation in Array(observationCache.values) { updateWaypoint(observation) }
            resolveLocalSegment()
            log("routeLoaded", fields: ["name": definition.name])
            message = nil
            refreshLayout()
        } catch { loadState = .failed; message = error.localizedDescription }
    }
    @discardableResult func saveRoute(name: String, startDescription: String) async -> Bool {
        guard !isBusy, canSave, let id = routeID else { message = "请先完成路线并等待锚点添加成功。"; return false }
        isBusy = true
        defer { isBusy = false }
        let definition = SavedRoute(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            startDescription: startDescription, createdAt: Date(), waypoints: waypoints.map { SavedWaypoint(id: $0.id, kind: $0.kind) },
            segmentLengths: segmentLengths, trialNumber: trialNumber)
        do {
            try await store.save(definition)
            if routeID == id { savedDefinition = definition }
            log("routeSaved", fields: ["name": definition.name])
            message = "路线已保存，下次可从列表选择。"
            await refreshLibrary()
            return true
        } catch {
            // A definition may have committed before ownership bookkeeping failed; protect its anchors.
            if let committed = try? await store.load(id), routeID == id { savedDefinition = committed }
            message = "保存路线失败：\(error.localizedDescription)"
            log("routeSaveFailed", fields: ["error": error.localizedDescription])
            return false
        }
    }
    func deleteSavedRoute(_ id: UUID) async {
        guard !isBusy else { return }
        if routeID == id { await clearRoute() }
        isBusy = true
        defer { isBusy = false }
        do {
            try await store.beginDeletion(id)
            await cleanupPendingAnchors()
            message = tracking.isRunning ? "删除请求已处理；失败项会保留重试。" : "已标记删除，打开空间后完成锚点清理。"
            await refreshLibrary()
        } catch { message = "删除失败：\(error.localizedDescription)" }
    }

    func startTracking() async {
        if let stopOperation { await stopOperation.value }
        guard !isStarting, !isSessionActive else { return }
        isStarting = true
        callbackToken += 1
        let token = callbackToken
        sessionGeneration += 1
        coordinateEpoch += 1
        requiresRelocalization = false
        deviceWasTracked = false
        resetRuntimeCoordinates()
        tracking.onInput = { [weak self] input in
            guard let self, self.callbackToken == token else { return }
            self.apply(input)
        }
        do {
            try await tracking.start()
            guard callbackToken == token else { return }
            isSessionActive = true
            providerDescription = "running"
            isStarting = false
            if savedDefinition != nil { beginLocalization() }
            if automaticSampling {
                samplingTask = Task { [weak self] in
                    while !Task.isCancelled {
                        guard let self, self.callbackToken == token else { return }
                        self.samplePosition()
                        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    }
                }
            }
            log("sessionStarted")
            await cleanupPendingAnchors()
        } catch {
            guard callbackToken == token else { return }
            isStarting = false
            providerDescription = error.localizedDescription
            message = "启动追踪失败：\(error.localizedDescription)"
            if savedDefinition != nil { loadState = .failed }
            log("sessionStartFailed", fields: ["error": error.localizedDescription])
            refreshLayout()
        }
    }
    func stopTracking() async {
        if let stopOperation { await stopOperation.value; return }
        guard isSessionActive || isStarting else { return }
        let task = Task { [weak self] in await self?.performStop() }
        let operation = Task<Void, Never> { _ = await task.value }
        stopOperation = operation
        await operation.value
        stopOperation = nil
    }
    private func performStop() async {
        callbackToken += 1
        isStarting = false
        samplingTask?.cancel()
        samplingTask = nil
        tracking.onInput = nil
        finishRun(result: "aborted", reason: "空间关闭")
        log("sessionStopped")
        // Saved anchors are never removed here. Unfinished drafts remain journaled for cleanup.
        tracking.stop()
        isSessionActive = false
        providerDescription = "stopped"
        coordinateEpoch += 1
        resetRuntimeCoordinates()
        targetIndex = 1
        phase = savedDefinition == nil ? .idle : .returning
        if savedDefinition == nil { waypoints = []; routeID = nil; registeredIDs = []; segmentLengths = [] }
        else { loadState = .localizing }
        await flushLogs()
    }
    func relocalize() async {
        guard !isBusy, savedDefinition != nil else { return }
        await stopTracking()
        await startTracking()
    }
    private func beginLocalization() {
        localizationAttemptID = UUID()
        localizationStarted = now()
        loadState = .localizing
        log("localizationStarted", fields: localizationFields())
    }
    private func localizationFields() -> [String: String] {
        let indices = Array(waypoints.indices.prefix(2))
        return ["localizationAttemptID": localizationAttemptID?.uuidString ?? "",
            "matched": indices.filter { candidatePosition($0) != nil }.map { waypoints[$0].id.uuidString }.joined(separator: ","),
            "missing": indices.filter { candidatePosition($0) == nil }.map { waypoints[$0].id.uuidString }.joined(separator: ","),
            "elapsed": String(now() - (localizationStarted ?? now()))]
    }
    private func resetRuntimeCoordinates() {
        observationCache.removeAll()
        floorSurfaces.removeAll()
        fallbackReference = nil
        currentPosition = nil
        isTrackingDevice = false
        isOffRoute = false
        offRouteSince = nil
        waitingForNextIndex = nil
        coordinateValidity = .needsRevalidation
        for index in waypoints.indices { waypoints[index].pose = nil; waypoints[index].lastTrackedPose = nil; waypoints[index].trackingState = .pending }
        refreshLayout()
    }
    func markAnomaly(_ note: String = "人工标记异常") { invalidateCoordinates(note) }
    private func invalidateCoordinates(_ reason: String) {
        guard !requiresRelocalization else { return }
        requiresRelocalization = true
        coordinateEpoch += 1
        finishRun(result: "aborted", reason: reason)
        resetRuntimeCoordinates()
        if savedDefinition != nil { loadState = .unresolved }
        log("coordinateInvalidated", fields: ["reason": reason])
    }

    func beginMarking() async {
        guard !isBusy, tracking.isRunning, entryMode == .custom, !hasUnsavedRoute else { message = "请先打开空间，或处理未保存路线。"; return }
        await clearRoute()
        routeID = UUID()
        entryMode = .custom
        phase = .markingStart
        requiresRelocalization = false
        coordinateValidity = isTrackingDevice ? .usable : .needsRevalidation
        message = nil
        refreshLayout()
    }
    func recordStart() async { if phase == .markingStart, await appendWaypoint(.start) { phase = .marking; refreshLayout() } }
    func addTurn() async { if phase == .marking { _ = await appendWaypoint(.turn) } }
    func recordEnd() async {
        guard phase == .marking, waypoints.count >= 2 else { message = "请先记录至少一个转弯点。"; return }
        if await appendWaypoint(.end) { phase = .returning; refreshLayout() }
    }
    private func appendWaypoint(_ kind: WaypointKind) async -> Bool {
        guard !isBusy, !requiresRelocalization, let id = routeID else { return false }
        let sample = tracking.sample()
        guard sample.isTracked, let pose = sample.pose else { message = "设备追踪不可用。"; return false }
        var length: Float?
        if !waypoints.isEmpty {
            guard let previous = candidatePosition(waypoints.count - 1) else { message = "请等待上一路点定位后继续记录。"; return false }
            length = horizontalDistance(previous, pose.translation)
            guard length! >= 0.9 else { message = "新路点离上一个点太近，请至少移动约 0.9 米。"; return false }
        }
        isBusy = true
        defer { isBusy = false }
        let token = callbackToken
        let anchorID = tracking.prepareAnchor(at: pose)
        do {
            try await store.registerDraftAnchor(routeID: id, anchorID: anchorID)
            guard token == callbackToken, routeID == id else { return false }
            waypoints.append(RouteWaypoint(id: anchorID, kind: kind))
            try await tracking.addAnchor(id: anchorID)
            guard token == callbackToken, routeID == id else { return false }
            registeredIDs.insert(anchorID)
            if let length { segmentLengths.append(length) }
            invalidateFallback("路点结构已改变")
            message = nil
            log("waypointRecorded", fields: ["anchorID": anchorID.uuidString, "kind": kind.rawValue])
            refreshLayout()
            return true
        } catch {
            if routeID == id { waypoints.removeAll { $0.id == anchorID } }
            message = "记录路点失败：\(error.localizedDescription)"
            refreshLayout()
            return false
        }
    }
    func undoLastWaypoint() async {
        guard !isBusy, savedDefinition == nil, phase == .marking || phase == .returning, let last = waypoints.last else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await tracking.removeAnchor(id: last.id)
            try await store.acknowledgeRemoval(last.id)
            waypoints.removeLast()
            registeredIDs.remove(last.id)
            if !segmentLengths.isEmpty { segmentLengths.removeLast() }
            phase = waypoints.isEmpty ? .markingStart : .marking
            invalidateFallback("路点已撤销")
            log("waypointUndone", fields: ["anchorID": last.id.uuidString])
            refreshLayout()
        } catch { message = "撤销失败：\(error.localizedDescription)" }
    }
    func clearRoute() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        finishRun(result: "aborted", reason: "卸载路线")
        log("routeUnloaded")
        waypoints = []; routeID = nil; savedDefinition = nil; registeredIDs = []; segmentLengths = []
        targetIndex = 1; trialNumber = 0; phase = .idle; loadState = .none
        fallbackReference = nil; floorSurfaces.removeAll(); waitingForNextIndex = nil
        isOffRoute = false; offRouteSince = nil
        coordinateValidity = !requiresRelocalization && isTrackingDevice ? .usable : .needsRevalidation
        refreshLayout()
        await cleanupPendingAnchors()
    }
    private func cleanupPendingAnchors() async {
        guard tracking.isRunning else { return }
        do {
            let ids = try await store.cleanupIDs(excludingDraft: savedDefinition == nil ? routeID : nil)
            for id in ids {
                do { try await tracking.removeAnchor(id: id); try await store.acknowledgeRemoval(id) }
                catch { log("anchorCleanupFailed", fields: ["id": id.uuidString, "error": error.localizedDescription]); message = "部分锚点清理未完成，将在下次打开空间时重试。" }
            }
        } catch { message = "无法检查锚点归属：\(error.localizedDescription)" }
    }

    func candidatePosition(_ index: Int) -> SIMD3<Float>? {
        guard waypoints.indices.contains(index) else { return nil }
        let point = waypoints[index]
        guard point.trackingState == .tracked, point.sessionGeneration == sessionGeneration,
              point.coordinateEpoch == coordinateEpoch, point.lastTrackedPose?.isFinite == true else { return nil }
        return point.position
    }
    func usablePosition(for index: Int) -> SIMD3<Float>? { coordinateValidity == .usable ? candidatePosition(index) : nil }
    func segment(at target: Int) -> SegmentScope? {
        guard target > 0, let a = candidatePosition(target - 1), let b = candidatePosition(target) else { return nil }
        let length = horizontalDistance(a, b)
        guard length >= 0.5 else { return nil }
        if savedDefinition != nil, segmentLengths.indices.contains(target - 1) {
            let expected = segmentLengths[target - 1]
            guard abs(length - expected) <= max(0.2, expected * 0.05) else { return nil }
        }
        return SegmentScope(index: target, startID: waypoints[target - 1].id, endID: waypoints[target].id, a: a, b: b, from: 0, to: length)
    }
    func activeSegmentIndices() -> [Int] { [activeTarget, activeTarget + 1].filter { segment(at: $0) != nil } }
    func localSegmentStatus() -> Bool { coordinateValidity == .usable && segment(at: activeTarget) != nil }
    private func resolveLocalSegment() {
        guard !requiresRelocalization, isTrackingDevice, tracking.isRunning else { return }
        if savedDefinition == nil { coordinateValidity = .usable; return }
        if segment(at: phase == .navigating ? targetIndex : 1) != nil {
            coordinateValidity = .usable
            if loadState != .localSegmentReady {
                loadState = .localSegmentReady
                log("localizationReady", fields: localizationFields())
            }
        } else if loadState == .localSegmentReady { loadState = .localizing }
    }

    func apply(_ input: TrackingInput) {
        switch input {
        case .waypoint(let observation):
            log("anchor.\(observation.event.rawValue)", fields: ["id": observation.id.uuidString, "tracked": String(observation.isTracked),
                "sourceTimestamp": observation.sourceTimestamp.map { String($0) } ?? "unavailable"], pose: observation.pose)
            guard !requiresRelocalization else { return }
            observationCache[observation.id] = observation
            updateWaypoint(observation)
            resolveLocalSegment()
            validateFallback()
        case .floor(let id, let floor):
            log("floorUpdated", fields: ["id": id.uuidString, "available": String(floor != nil), "width": String(floor?.width ?? 0),
                "depth": String(floor?.depth ?? 0), "classification": floor == nil ? "removedOrNotFloor" : "floor",
                "sourceTimestamp": floor?.sourceTimestamp.map { String($0) } ?? "unavailable"], pose: floor?.transform)
            guard !requiresRelocalization else { return }
            floorSurfaces[id] = floor
            if fallbackReference?.source.id == id && floor == nil { invalidateFallback("参考地面已移除或不再有效") }
            validateFallback()
        case .provider(let world, let running, let description):
            log("providerChanged", fields: ["world": String(world), "running": String(running), "description": description])
            if world {
                providerDescription = description
                if !running, !waypoints.isEmpty, deviceWasTracked { invalidateCoordinates("世界追踪异常：\(description)") }
            } else {
                floorProviderDescription = description
                if !running { floorSurfaces.removeAll(); invalidateFallback("地面检测不可用") }
            }
        case .authorization(let allowed, let description):
            log("authorizationChanged", fields: ["allowed": String(allowed), "description": description])
            if !allowed { floorSurfaces.removeAll(); invalidateFallback("世界感知授权不可用"); if !waypoints.isEmpty { invalidateCoordinates("世界感知授权不可用") } }
        }
        refreshLayout()
    }
    private func updateWaypoint(_ observation: WaypointObservation) {
        guard let index = waypoints.firstIndex(where: { $0.id == observation.id }) else { return }
        waypoints[index].lastAnchorUpdateTime = now()
        waypoints[index].sessionGeneration = sessionGeneration
        waypoints[index].coordinateEpoch = coordinateEpoch
        waypoints[index].pose = observation.pose
        if observation.event == .removed {
            waypoints[index].trackingState = .removed
            waypoints[index].lastTrackedPose = nil
        } else if observation.isTracked, observation.pose?.isFinite == true {
            waypoints[index].trackingState = .tracked
            waypoints[index].lastTrackedPose = observation.pose
        } else { waypoints[index].trackingState = .temporarilyUntracked }
    }
    func samplePosition() {
        let sample = tracking.sample() // one device query per sampling cycle
        let wasTracked = deviceWasTracked
        isTrackingDevice = sample.isTracked
        currentPosition = sample.isTracked ? sample.pose?.translation : nil
        if sample.isTracked { deviceWasTracked = true }
        if !sample.isTracked, wasTracked, !waypoints.isEmpty { invalidateCoordinates(sample.reason) }
        resolveLocalSegment()
        if loadState == .localizing, let started = localizationStarted, now() - started >= configuration.localizationTimeout {
            loadState = .unresolved
            log("localizationTimeout", fields: localizationFields())
        }
        if phase == .navigating, coordinateValidity == .usable, let position = currentPosition,
           let scope = segment(at: targetIndex) {
            let projection = segmentProjection(position, scope.a, scope.b)
            if projection.finiteDistance > configuration.offRouteDistance {
                if offRouteSince == nil { offRouteSince = now() }
                if now() - offRouteSince! >= configuration.offRouteDelay { isOffRoute = true }
            } else if projection.finiteDistance < configuration.offRouteRecovery {
                offRouteSince = nil; isOffRoute = false
            } else if !isOffRoute { offRouteSince = nil }
            if !isOffRoute, horizontalDistance(position, scope.b) <= configuration.arrivalDistance,
               projection.distance / scope.length >= 0.55, projection.lateral <= 0.7 {
                if targetIndex == waypoints.count - 1 { phase = .arrived; finishRun(result: "completed", reason: nil) }
                else if segment(at: targetIndex + 1) != nil { targetIndex += 1; waitingForNextIndex = nil; offRouteSince = nil; log("waypointAdvanced") }
                else { waitingForNextIndex = targetIndex + 1 }
            }
        }
        refreshLayout()
        sampleCounter += 1
        if sampleCounter % 2 == 0 {
            let endpoints = [activeTarget - 1, activeTarget].filter { waypoints.indices.contains($0) }
            log("deviceSample", fields: ["reason": sample.reason, "queryTime": String(sample.queryTime),
                "target": String(targetIndex), "candidate": String(layout.statistics.candidate),
                "placed": String(layout.statistics.placed), "visible": String(layout.statistics.visible),
                "fallback": String(layout.statistics.fallback), "detectedFloor": String(layout.statistics.placed - layout.statistics.fallback),
                "coverage": layout.statistics.coverage,
                "endpoints": endpoints.map { "\(waypoints[$0].id):\(waypoints[$0].trackingState.rawValue)" }.joined(separator: ";")], pose: sample.pose)
        }
    }
    func startNavigation() async {
        guard canStartNavigation, let id = routeID else { message = "请回到起点附近，并等待起始路段定位。"; return }
        isBusy = true
        defer { isBusy = false }
        do {
            if savedDefinition != nil { trialNumber = try await store.reserveTrial(id) }
            else { trialNumber += 1 }
            guard routeID == id, phase == .returning, tracking.isRunning, isTrackingDevice,
                  coordinateValidity == .usable, segment(at: 1) != nil,
                  let position = currentPosition, let start = candidatePosition(0),
                  horizontalDistance(position, start) <= configuration.startDistance else { return }
            targetIndex = 1; isOffRoute = false; offRouteSince = nil; waitingForNextIndex = nil
            phase = .navigating
            let summary = NavigationRunSummary(id: UUID(), appRunID: appRunID, routeID: id, routeName: routeName,
                definitionVersion: savedDefinition?.definitionVersion ?? 1, entryMode: entryMode?.rawValue ?? "custom",
                trialNumber: trialNumber, startedAt: Date(), isSavedRoute: savedDefinition != nil)
            currentRun = summary; runDropBaseline = droppedEventCount
            enqueueSummary(summary)
            log("navigationStarted")
            message = nil
            refreshLayout()
        } catch { message = "无法分配试走编号：\(error.localizedDescription)" }
    }
    func repeatNavigation() {
        guard phase == .arrived else { return }
        phase = .returning; targetIndex = 1; isOffRoute = false; offRouteSince = nil; waitingForNextIndex = nil
        resolveLocalSegment(); refreshLayout()
    }

    func floorHeight(near point: SIMD3<Float>) -> Float? { RouteLayout.detectedFloor(near: point, floors: Array(floorSurfaces.values))?.height }
    func calibrateFallback(scopes requested: [(index: Int, from: Float, to: Float)], confirmedFlat: Bool) async {
        guard !isBusy, confirmedFlat, isRouteComplete, coordinateValidity == .usable, isTrackingDevice,
              let routeID, let position = currentPosition,
              let source = RouteLayout.detectedFloor(near: position, floors: Array(floorSurfaces.values)), !requested.isEmpty else {
            calibrationFailed("请先确认平坦范围，并在已识别地面的位置停下。"); return
        }
        var scopes: [SegmentScope] = []
        for selection in requested {
            guard let scope = segment(at: selection.index), selection.from >= 0, selection.to <= scope.length,
                  selection.to > selection.from else { calibrationFailed("所选路段位置或适用范围无效。"); return }
            scopes.append(SegmentScope(index: scope.index, startID: scope.startID, endID: scope.endID, a: scope.a, b: scope.b, from: selection.from, to: selection.to))
        }
        isBusy = true
        defer { isBusy = false }
        let token = callbackToken, epoch = coordinateEpoch
        let start = now()
        var low = source.height, high = source.height
        repeat {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { calibrationFailed("校准已取消。"); return }
            guard token == callbackToken, coordinateEpoch == epoch, coordinateValidity == .usable,
                  isTrackingDevice, let current = currentPosition, horizontalDistance(position, current) <= 0.2,
                  let floor = floorSurfaces[source.id], floor.supports(current) else { calibrationFailed("校准中断：位置或来源地面不可用。"); return }
            low = min(low, floor.height); high = max(high, floor.height)
            if high - low > configuration.calibrationHeightRange { calibrationFailed("参考地面高度不稳定，请重新校准。"); return }
        } while now() - start < configuration.calibrationWindow
        guard let latest = floorSurfaces[source.id] else { return }
        fallbackReference = FallbackFloorReference(id: UUID(), source: latest, routeID: routeID, generation: sessionGeneration,
            epoch: epoch, calibratedAt: Date(), scopes: scopes, halfWidth: 0.75)
        log("fallbackCalibrated", fields: ["source": latest.id.uuidString, "height": String(latest.height),
            "ranges": scopes.map { "\($0.startID)>\($0.endID):\($0.from)-\($0.to)" }.joined(separator: ";")], pose: latest.transform)
        message = "备用地面已校准，仅对选定范围生效。"
        refreshLayout()
    }
    private func calibrationFailed(_ reason: String) {
        message = reason
        log("fallbackCalibrationFailed", fields: ["reason": reason])
    }
    func disableFallback() { fallbackReference?.enabled = false; log("fallbackDisabled"); refreshLayout() }
    func enableFallback() {
        validateFallback()
        guard fallbackReference?.invalidReason == nil, fallbackReference != nil else { message = "请重新校准备用地面。"; return }
        fallbackReference?.enabled = true; log("fallbackEnabled"); refreshLayout()
    }
    private func invalidateFallback(_ reason: String) {
        guard fallbackReference != nil, fallbackReference?.invalidReason == nil else { return }
        fallbackReference?.invalidReason = reason; fallbackReference?.enabled = false
        log("fallbackInvalidated", fields: ["reason": reason])
    }
    private func validateFallback() {
        guard let reference = fallbackReference, reference.invalidReason == nil else { return }
        guard reference.routeID == routeID, reference.generation == sessionGeneration, reference.epoch == coordinateEpoch,
              let source = floorSurfaces[reference.source.id] else { invalidateFallback("参考来源或有效期已失效"); return }
        if abs(source.height - reference.source.height) > configuration.fallbackHeightConflict { invalidateFallback("参考地面高度发生冲突"); return }
        for scope in reference.scopes {
            guard let current = segment(at: scope.index), current.startID == scope.startID, current.endID == scope.endID,
                  simd_distance(current.a, scope.a) <= configuration.fallbackGeometryTolerance,
                  simd_distance(current.b, scope.b) <= configuration.fallbackGeometryTolerance else { invalidateFallback("校准路段几何已改变或不可用"); return }
            for floor in floorSurfaces.values {
                let distance = min(max(segmentProjection(floor.center, scope.a, scope.b).distance, scope.from), scope.to)
                let point = scope.point(at: distance)
                if floor.supports(point), abs(floor.height - reference.source.height) > configuration.fallbackHeightConflict {
                    invalidateFallback("适用区域检测到冲突地面，请重新校准"); return
                }
            }
        }
    }
    private func refreshLayout() {
        let block = navigationBlockReason
        if block != lastBlockReason { log("navigationBlockChanged", fields: ["reason": block.rawValue]); lastBlockReason = block }
        if phase == .idle || phase == .markingStart || phase == .arrived {
            layout = NavigationLayout(statistics: LayoutStatistics(coverage: "noCandidates"))
        } else if block == .none, let position = currentPosition, let current = segment(at: activeTarget) {
            var nextLayout = RouteLayout.make(current: current, next: segment(at: activeTarget + 1), device: position,
                floors: Array(floorSurfaces.values), fallback: fallbackReference, clearance: Float(arrowGroundClearance),
                navigating: phase == .navigating, configuration: configuration)
            nextLayout.previewUnavailable = activeTarget + 1 < waypoints.count && segment(at: activeTarget + 1) == nil
            layout = nextLayout
        } else { layout = NavigationLayout() }
        if layout.statistics.coverage != lastCoverage {
            lastCoverage = layout.statistics.coverage
            log("floorCoverageChanged", fields: ["coverage": lastCoverage, "candidate": String(layout.statistics.candidate),
                "placed": String(layout.statistics.placed), "fallback": String(layout.statistics.fallback)])
        }
        routeRevision += 1
        renderTick += 1
    }

    private func finishRun(result: String, reason: String?) {
        guard var summary = currentRun else { return }
        log("navigationEnded", fields: ["result": result, "reason": reason ?? ""])
        summary.result = result; summary.reason = reason; summary.endedAt = Date()
        summary.droppedEventCount = droppedEventCount - runDropBaseline
        enqueueSummary(summary)
        currentRun = nil
    }
    private func enqueueSummary(_ summary: NavigationRunSummary) {
        let previous = logTask
        logTask = Task { [weak self, recorder] in
            await previous?.value
            var value = summary
            value.logError = self?.logError
            do { try await recorder.save(value) }
            catch { self?.logError = error.localizedDescription }
        }
    }
    private func log(_ event: String, fields: [String: String] = [:], pose: simd_float4x4? = nil) {
        guard pendingLogCount < 1024 else { droppedEventCount += 1; return }
        sequence += 1; pendingLogCount += 1
        let value = NavigationLogEvent(schemaVersion: 1, sequence: sequence, date: Date(), monotonicTime: now(),
            appRunID: appRunID, routeID: routeID, testRunID: currentRun?.id, sessionGeneration: sessionGeneration,
            coordinateEpoch: coordinateEpoch, event: event, fields: fields, pose: pose?.isFinite == true ? pose?.values : nil)
        let previous = logTask
        logTask = Task { [weak self, recorder] in
            await previous?.value
            do { try await recorder.append(value) }
            catch { self?.logError = error.localizedDescription }
            self?.pendingLogCount -= 1
        }
    }
    func flushLogs() async { await logTask?.value }
    func refreshHistory() async {
        await flushLogs()
        do { history = try await recorder.history(currentAppRun: appRunID) }
        catch { logError = error.localizedDescription }
    }
    func exportLogs(routeID: UUID, testRunID: UUID? = nil) async {
        let cutoff = sequence
        let barrier = logTask
        await barrier?.value
        do { exportURL = try await recorder.export(routeID: routeID, currentAppRun: appRunID, testRunID: testRunID, sequenceCutoff: cutoff) }
        catch { logError = "导出失败：\(error.localizedDescription)" }
    }
}
