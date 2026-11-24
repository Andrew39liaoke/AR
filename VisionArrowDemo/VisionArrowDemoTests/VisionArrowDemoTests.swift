import XCTest
import simd
@testable import VisionArrowDemo

private func pose(_ x: Float, _ z: Float = 0, y: Float = 1.6) -> simd_float4x4 {
    var value = matrix_identity_float4x4
    value.columns.3 = [x, y, z, 1]
    return value
}
private func floor(_ x: Float = 8, width: Float = 50, height: Float = 0, id: UUID = UUID()) -> FloorSurface {
    FloorSurface(id: id, transform: pose(x, y: height), width: width, depth: 20)
}

@MainActor private final class FakeTracking: TrackingSource {
    var onInput: ((TrackingInput) -> Void)?
    var isRunning = false
    var device: simd_float4x4? = pose(0)
    var anchors: [UUID: simd_float4x4] = [:]
    var prepared: [UUID: simd_float4x4] = [:]
    var added: [UUID] = []
    var removed: [UUID] = []
    var removalFailures: Set<UUID> = []
    var addFails = false
    var restoreOnStart = false
    var starts = 0
    var stops = 0
    func start() async throws {
        starts += 1; isRunning = true
        onInput?(.provider(world: true, running: true, description: "running"))
        if restoreOnStart { for (id, value) in anchors { emit(id, value) } }
    }
    func stop() { stops += 1; isRunning = false }
    func sample() -> DeviceTrackingSample { .init(pose: isRunning ? device : nil, queryTime: 0, reason: device == nil ? "deviceAnchorNil" : "tracked") }
    func prepareAnchor(at pose: simd_float4x4) -> UUID { let id = UUID(); prepared[id] = pose; return id }
    func addAnchor(id: UUID) async throws {
        if addFails { throw CocoaError(.fileWriteUnknown) }
        added.append(id); anchors[id] = prepared[id]
        emit(id, prepared[id]) // exercises .added arriving before addAnchor returns
    }
    func removeAnchor(id: UUID) async throws {
        if removalFailures.contains(id) { throw CocoaError(.fileWriteUnknown) }
        removed.append(id); anchors.removeValue(forKey: id)
        emit(id, nil, event: .removed)
    }
    func emit(_ id: UUID, _ value: simd_float4x4?, tracked: Bool = true, event: ObservationEvent = .updated) {
        onInput?(.waypoint(.init(id: id, event: event, pose: value, isTracked: tracked)))
    }
}
@MainActor private final class Clock { var time: Double = 0 }
@MainActor private final class Fixture {
    let root: URL
    let source = FakeTracking()
    let clock = Clock()
    let model: RouteModel
    let store: RouteStore
    let recorder: NavigationTestRecorder
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = RouteStore(root: self.root.appendingPathComponent("SavedRoutes"))
        recorder = NavigationTestRecorder(root: self.root.appendingPathComponent("NavigationTests"))
        let clock = clock
        var config = NavigationConfiguration(); config.calibrationWindow = 0
        model = RouteModel(tracking: source, store: store, recorder: recorder, now: { clock.time }, automaticSampling: false, configuration: config)
    }
    func start() async { await model.startTracking(); model.samplePosition() }
    func move(_ x: Float, _ z: Float = 0) { source.device = pose(x, z); clock.time += 0.1; model.samplePosition() }
    func record(count: Int = 3) async {
        await start(); await model.chooseMode(.custom); await model.beginMarking(); await model.recordStart()
        for i in 1..<(count - 1) { move(Float(i) * 3); await model.addTurn() }
        move(Float(count - 1) * 3); await model.recordEnd()
        move(0)
    }
    func navigateLastSegment() async {
        await record(count: 6)
        model.apply(.floor(UUID(), floor()))
        await model.startNavigation()
        for i in 1...4 { move(Float(i) * 3) }
    }
    func save() async -> UUID {
        let saved = await model.saveRoute(name: "测试走廊", startDescription: "门口")
        XCTAssertTrue(saved, model.message ?? "")
        return model.routeID!
    }
    func calibrate() async {
        let value = floor()
        model.apply(.floor(value.id, value))
        await model.calibrateFallback(scopes: [(1, 0, 3)], confirmedFlat: true)
    }
}

@MainActor
final class VisionArrowDemoTests: XCTestCase {
    func testPanelRequestSurvivesClosedWindowAndRejectsDuplicateOrStaleCallbacks() async throws {
        let f = Fixture(); await f.record(); await f.model.startNavigation()
        let runID = f.model.currentRun?.id
        XCTAssertTrue(f.model.requestPanelAction(.saveRoute))
        let id = try XCTUnwrap(f.model.panelAction?.id)
        let token = try XCTUnwrap(f.model.panelActionWindowRequestID)
        XCTAssertEqual(f.model.panelAction?.stage, .waitingForWindow)
        f.model.checkPanelActionPresentation(token)
        XCTAssertTrue(f.model.panelActionFeedback?.contains("尚未显示") == true)
        XCTAssertFalse(f.model.isBusy)
        XCTAssertFalse(f.model.requestPanelAction(.returnHome))
        XCTAssertEqual(f.model.panelAction?.id, id)
        XCTAssertEqual(f.model.panelAction?.kind, .saveRoute)
        XCTAssertNotEqual(f.model.panelActionWindowRequestID, token)
        f.model.panelActionPresented(id)
        XCTAssertEqual(f.model.panelAction?.stage, .awaitingUser)
        f.model.checkPanelActionPresentation(token) // stale timeout cannot overwrite presentation feedback
        XCTAssertFalse(f.model.panelActionFeedback?.contains("尚未显示") == true)
        f.model.panelActionWindowClosed(id)
        XCTAssertEqual(f.model.panelAction?.id, id)
        XCTAssertEqual(f.model.panelAction?.stage, .waitingForWindow)
        f.model.reopenPanelAction(); f.model.panelActionPresented(id)
        f.model.cancelPanelAction(id)
        XCTAssertNil(f.model.panelAction)
        XCTAssertEqual(f.model.currentRun?.id, runID)
        XCTAssertEqual(f.model.phase, .navigating)
        XCTAssertTrue(f.model.requestPanelAction(.returnHome))
        let nextID = try XCTUnwrap(f.model.panelAction?.id)
        f.model.cancelPanelAction(id); f.model.panelActionPresented(id); f.model.finishPanelReturn(id)
        XCTAssertEqual(f.model.panelAction?.id, nextID)
        f.model.cancelPanelAction(nextID)
        await f.model.stopTracking()
    }
    func testPanelSaveKeepsNavigationAndWritesOrderedInteractionEvents() async throws {
        let f = Fixture(); await f.record(); await f.model.startNavigation()
        let routeID = try XCTUnwrap(f.model.routeID)
        let runID = f.model.currentRun?.id, target = f.model.targetIndex
        let before = f.model.layout.statistics
        XCTAssertTrue(f.model.requestPanelAction(.saveRoute))
        let id = try XCTUnwrap(f.model.panelAction?.id)
        f.model.panelActionWindowRequested(try XCTUnwrap(f.model.panelActionWindowRequestID))
        f.model.panelActionPresented(id)
        async let first = f.model.savePanelRoute(id, name: "面板保存", startDescription: "门口")
        async let second = f.model.savePanelRoute(id, name: "重复提交", startDescription: "")
        let results = await [first, second]
        XCTAssertEqual(results.filter { $0 }.count, 1)
        XCTAssertNil(f.model.panelAction)
        XCTAssertEqual(f.model.phase, .navigating)
        XCTAssertEqual(f.model.currentRun?.id, runID)
        XCTAssertEqual(f.model.targetIndex, target)
        XCTAssertEqual(f.model.layout.statistics, before)
        XCTAssertFalse(f.model.canSave)
        await f.model.flushLogs()
        let directory = f.root.appendingPathComponent("NavigationTests/\(routeID)")
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first { $0.pathExtension == "jsonl" })
        let events = try Data(contentsOf: file).split(separator: 0x0A).map { try JSONDecoder().decode(NavigationLogEvent.self, from: Data($0)) }
        let operation = events.filter { $0.fields["operationID"] == id.uuidString }
        XCTAssertEqual(operation.filter { $0.event == "ui.saveStarted" }.count, 1)
        let names = operation.map(\.event)
        let expected = ["ui.buttonTapped", "ui.requested", "ui.windowOpenRequested", "ui.presented", "ui.saveStarted", "ui.saveSucceeded", "ui.completed"]
        XCTAssertEqual(names, expected)
        let definition = try await f.store.load(routeID)
        XCTAssertEqual(definition.trialNumber, 1)
        await f.model.stopTracking()
    }
    func testPanelHomeDecisionCancelLeavesUnsavedNavigationIntact() async throws {
        let f = Fixture(); await f.record(); await f.model.startNavigation()
        let idBefore = f.model.routeID, runID = f.model.currentRun?.id
        XCTAssertTrue(f.model.requestPanelAction(.returnHome))
        let id = try XCTUnwrap(f.model.panelAction?.id)
        f.model.panelActionPresented(id)
        let returned = await f.model.returnPanelHome(id)
        XCTAssertFalse(returned)
        XCTAssertEqual(f.model.panelAction?.stage, .awaitingUser)
        XCTAssertFalse(f.model.isBusy)
        f.model.cancelPanelAction(id)
        XCTAssertNil(f.model.panelAction)
        XCTAssertEqual(f.model.routeID, idBefore)
        XCTAssertEqual(f.model.currentRun?.id, runID)
        XCTAssertEqual(f.model.phase, .navigating)
        XCTAssertTrue(f.model.isSessionActive)
        XCTAssertTrue(f.source.removed.isEmpty)
        await f.model.stopTracking()
    }
    func testPanelSavedHomeWaitsForSpaceDismissalAndFinishesOnce() async throws {
        let f = Fixture(); await f.record(); let savedID = await f.save(); await f.model.startNavigation()
        f.model.isImmersivePresented = true
        XCTAssertTrue(f.model.requestPanelAction(.returnHome))
        let id = try XCTUnwrap(f.model.panelAction?.id)
        f.model.panelActionPresented(id)
        f.model.finishPanelReturn(id) // cannot finish before model cleanup
        XCTAssertNotNil(f.model.panelAction)
        let returned = await f.model.returnPanelHome(id)
        XCTAssertTrue(returned)
        XCTAssertEqual(f.model.panelAction?.stage, .closingSpace)
        XCTAssertTrue(f.model.isImmersivePresented)
        XCTAssertNil(f.model.entryMode)
        XCTAssertFalse(f.model.isSessionActive)
        XCTAssertTrue(f.source.removed.isEmpty)
        let definition = try await f.store.load(savedID)
        XCTAssertEqual(definition.waypoints.count, 3)
        f.model.finishPanelReturn(id); f.model.finishPanelReturn(id)
        XCTAssertNil(f.model.panelAction)
        XCTAssertFalse(f.model.isImmersivePresented)
        XCTAssertFalse(f.model.isPanelActionCommitting)
        await f.model.refreshHistory()
        XCTAssertEqual(f.model.history.count, 1)
        XCTAssertEqual(f.source.stops, 1)
    }
    func testPanelSaveFailureStaysOpenAndRetryCanSaveThenReturn() async throws {
        let f = Fixture(); await f.record(); await f.model.startNavigation()
        let routeID = try XCTUnwrap(f.model.routeID)
        let runID = f.model.currentRun?.id
        XCTAssertTrue(f.model.requestPanelAction(.returnHome))
        let id = try XCTUnwrap(f.model.panelAction?.id)
        f.model.panelActionPresented(id)
        let root = f.root.appendingPathComponent("SavedRoutes"), backup = f.root.appendingPathComponent("saved-backup")
        try FileManager.default.moveItem(at: root, to: backup)
        try Data("blocked".utf8).write(to: root)
        let failed = await f.model.savePanelRoute(id, name: "失败后重试", startDescription: "", returnAfterSaving: true)
        XCTAssertFalse(failed)
        XCTAssertEqual(f.model.panelAction?.id, id)
        XCTAssertEqual(f.model.panelAction?.stage, .awaitingUser)
        XCTAssertFalse(f.model.isBusy)
        XCTAssertEqual(f.model.currentRun?.id, runID)
        XCTAssertEqual(f.model.phase, .navigating)
        XCTAssertTrue(f.model.panelActionFeedback?.contains("失败") == true)
        try FileManager.default.removeItem(at: root)
        try FileManager.default.moveItem(at: backup, to: root)
        let saved = await f.model.savePanelRoute(id, name: "失败后重试", startDescription: "", returnAfterSaving: true)
        XCTAssertTrue(saved)
        XCTAssertEqual(f.model.panelAction?.stage, .closingSpace)
        XCTAssertTrue(f.source.removed.isEmpty)
        let definition = try await f.store.load(routeID)
        XCTAssertEqual(definition.name, "失败后重试")
        f.model.finishPanelReturn(id)
        XCTAssertNil(f.model.panelAction)
    }
    func testPanelDiscardReturnsWithoutDeletingOtherSavedRoute() async throws {
        let f = Fixture(); await f.record(); let savedID = await f.save()
        let protected = Set(f.model.waypoints.map(\.id))
        await f.record(); await f.model.startNavigation()
        let draft = Set(f.model.waypoints.map(\.id))
        XCTAssertTrue(f.model.requestPanelAction(.returnHome))
        let id = try XCTUnwrap(f.model.panelAction?.id)
        f.model.panelActionPresented(id)
        let returned = await f.model.returnPanelHome(id, discardDraft: true)
        XCTAssertTrue(returned)
        f.model.finishPanelReturn(id)
        XCTAssertEqual(Set(f.source.removed), draft)
        XCTAssertTrue(protected.isSubset(of: Set(f.source.anchors.keys)))
        let library = try await f.store.list()
        XCTAssertEqual(library.map(\.id), [savedID])
        XCTAssertNil(f.model.entryMode)
    }
    func testPanelStaleRouteRequestCannotSaveAnotherRoute() async throws {
        let f = Fixture(); await f.record()
        XCTAssertTrue(f.model.requestPanelAction(.saveRoute))
        let id = try XCTUnwrap(f.model.panelAction?.id)
        await f.model.chooseMode(.custom, discardDraft: true)
        await f.model.beginMarking(); await f.model.recordStart()
        let saved = await f.model.savePanelRoute(id, name: "stale", startDescription: "")
        XCTAssertFalse(saved)
        f.model.panelActionPresented(id)
        XCTAssertNil(f.model.panelAction)
        XCTAssertEqual(f.model.waypoints.count, 1)
        await f.model.stopTracking()
    }
    func testPanelSaveDisabledForIncompleteAndAlreadySavedRoutes() async {
        let f = Fixture(); await f.start(); await f.model.chooseMode(.custom); await f.model.beginMarking(); await f.model.recordStart()
        XCTAssertFalse(f.model.requestPanelAction(.saveRoute))
        XCTAssertNil(f.model.panelAction)
        XCTAssertTrue(f.model.panelActionFeedback?.contains("完成路线") == true)
        await f.model.chooseMode(.custom, discardDraft: true)
        await f.record(); _ = await f.save()
        XCTAssertFalse(f.model.requestPanelAction(.saveRoute))
        XCTAssertNil(f.model.panelAction)
        XCTAssertTrue(f.model.panelActionFeedback?.contains("已保存") == true)
        XCTAssertTrue(f.model.requestPanelAction(.returnHome))
        f.model.cancelPanelAction(f.model.panelAction!.id)
        await f.model.stopTracking()
    }
    func testSaveDuringNavigationThenReturnHomeKeepsSavedAnchorsAndCounts() async throws {
        let f = Fixture(); await f.record(); await f.model.startNavigation(); f.move(1)
        let routeID = try XCTUnwrap(f.model.routeID)
        let runID = try XCTUnwrap(f.model.currentRun?.id)
        let pointIDs = f.model.waypoints.map(\.id)
        let target = f.model.targetIndex
        let saved = await f.model.saveRoute(name: "导航中保存", startDescription: "原起点")
        XCTAssertTrue(saved)
        XCTAssertEqual(f.model.phase, .navigating)
        XCTAssertEqual(f.model.currentRun?.id, runID)
        XCTAssertEqual(f.model.targetIndex, target)
        XCTAssertFalse(f.model.canSave)
        let returned = await f.model.returnToRouteSelection()
        XCTAssertTrue(returned)
        XCTAssertNil(f.model.entryMode)
        XCTAssertEqual(f.model.phase, .idle)
        XCTAssertTrue(f.model.waypoints.isEmpty)
        XCTAssertFalse(f.model.isSessionActive)
        XCTAssertTrue(f.source.removed.isEmpty)
        let definition = try await f.store.load(routeID)
        XCTAssertEqual(definition.waypoints.map(\.id), pointIDs)
        XCTAssertEqual(definition.trialNumber, 1)
        await f.model.stopTracking(); await f.model.refreshHistory()
        XCTAssertEqual(f.model.history.count, 1)
        XCTAssertEqual(f.model.history.first?.id, runID)
        XCTAssertEqual(f.model.history.first?.result, "aborted")
        XCTAssertEqual(f.source.stops, 1)
    }
    func testReturnHomeWithoutDraftDecisionLeavesNavigationActive() async throws {
        let f = Fixture(); await f.record(); await f.model.startNavigation()
        let runID = try XCTUnwrap(f.model.currentRun?.id)
        let returned = await f.model.returnToRouteSelection()
        XCTAssertFalse(returned)
        XCTAssertEqual(f.model.entryMode, .custom)
        XCTAssertEqual(f.model.phase, .navigating)
        XCTAssertEqual(f.model.currentRun?.id, runID)
        XCTAssertTrue(f.model.isSessionActive)
        XCTAssertEqual(f.model.waypoints.count, 3)
        XCTAssertTrue(f.source.removed.isEmpty)
        await f.model.stopTracking()
    }
    func testDiscardDraftOnReturnHomePreservesOtherSavedRoute() async throws {
        let f = Fixture(); await f.record(); let savedID = await f.save()
        let savedAnchors = Set(f.model.waypoints.map(\.id))
        await f.record(); await f.model.startNavigation()
        let draftAnchors = Set(f.model.waypoints.map(\.id))
        let returned = await f.model.returnToRouteSelection(discardDraft: true)
        XCTAssertTrue(returned)
        XCTAssertNil(f.model.entryMode)
        XCTAssertFalse(f.model.isSessionActive)
        XCTAssertEqual(Set(f.source.removed), draftAnchors)
        XCTAssertTrue(savedAnchors.isSubset(of: Set(f.source.anchors.keys)))
        let library = try await f.store.list()
        XCTAssertEqual(library.map(\.id), [savedID])
        await f.model.refreshHistory()
        XCTAssertEqual(f.model.history.first?.result, "aborted")
    }
    func testFailedSaveCannotBypassUnsavedRouteReturnGuard() async throws {
        let f = Fixture(); await f.record(); await f.model.startNavigation()
        let root = f.root.appendingPathComponent("SavedRoutes")
        try FileManager.default.removeItem(at: root)
        try Data("unwritable store".utf8).write(to: root)
        let saved = await f.model.saveRoute(name: "保存失败", startDescription: "")
        XCTAssertFalse(saved)
        XCTAssertNil(f.model.savedDefinition)
        let returned = await f.model.returnToRouteSelection()
        XCTAssertFalse(returned)
        XCTAssertEqual(f.model.phase, .navigating)
        XCTAssertEqual(f.model.waypoints.count, 3)
        XCTAssertTrue(f.source.removed.isEmpty)
        await f.model.stopTracking()
    }
    func testDeviceLossInvalidatesMarkingReturningAndArrivedPhases() async {
        for stage in ["marking", "returning", "arrived"] {
            let f = Fixture(); await f.record()
            if stage == "marking" { await f.model.undoLastWaypoint() }
            if stage == "arrived" { await f.model.startNavigation(); f.move(3); f.move(6) }
            let epoch = f.model.coordinateEpoch
            f.source.device = nil; f.model.samplePosition()
            XCTAssertGreaterThan(f.model.coordinateEpoch, epoch, stage)
            f.move(0)
            XCTAssertEqual(f.model.coordinateValidity, .needsRevalidation, stage)
            XCTAssertEqual(f.model.layout.statistics.visible, 0, stage)
            await f.model.stopTracking()
        }
    }
    func testBoundedLogOverflowIsReportedWithoutBlockingNavigation() async {
        let f = Fixture(); await f.record(); await f.model.startNavigation(); await f.model.flushLogs()
        for _ in 0..<1100 { f.model.apply(.floor(UUID(), nil)) }
        XCTAssertGreaterThan(f.model.droppedEventCount, 0)
        XCTAssertEqual(f.model.navigationBlockReason, .none)
        await f.model.stopTracking(); await f.model.refreshHistory()
        XCTAssertGreaterThan(f.model.history.first?.droppedEventCount ?? 0, 0)
    }
    func testCalibrationRejectsUnstableSourceAndClearRemovesReference() async {
        let f = Fixture(); await f.record()
        let source = floor(); f.model.apply(.floor(source.id, source))
        let calibration = Task { await f.model.calibrateFallback(scopes: [(1, 0, 3)], confirmedFlat: true) }
        while !f.model.isBusy { await Task.yield() }
        f.model.apply(.floor(source.id, floor(height: 0.1, id: source.id)))
        await calibration.value
        XCTAssertNil(f.model.fallbackReference)
        XCTAssertTrue(f.model.message?.contains("不稳定") == true)
        await f.calibrate(); XCTAssertNotNil(f.model.fallbackReference)
        await f.model.clearRoute()
        XCTAssertNil(f.model.fallbackReference)
        XCTAssertTrue(f.model.waypoints.isEmpty)
        await f.model.stopTracking()
    }
    func testRelocalizingFromLaterSegmentResetsTargetToStart() async {
        let f = Fixture(); await f.navigateLastSegment(); _ = await f.save()
        XCTAssertEqual(f.model.targetIndex, 5)
        f.source.restoreOnStart = false
        await f.model.relocalize()
        f.source.emit(f.model.waypoints[0].id, pose(0))
        f.source.emit(f.model.waypoints[1].id, pose(3))
        f.move(0)
        XCTAssertEqual(f.model.targetIndex, 1)
        XCTAssertEqual(f.model.navigationBlockReason, .none)
        XCTAssertTrue(f.model.canStartNavigation)
        await f.model.stopTracking()
    }
    func testExportUsesFixedSequenceCutoffAndRunFilename() async throws {
        let f = Fixture(); await f.record(); let routeID = await f.save()
        await f.model.startNavigation()
        let runID = try XCTUnwrap(f.model.currentRun?.id)
        await f.model.flushLogs()
        let late = NavigationLogEvent(schemaVersion: 1, sequence: 999999, date: Date(), monotonicTime: 0,
            appRunID: f.model.appRunID, routeID: routeID, testRunID: runID, sessionGeneration: 1, coordinateEpoch: 1,
            event: "afterExportCutoff", fields: [:])
        try await f.recorder.append(late)
        let url = try await f.recorder.export(routeID: routeID, currentAppRun: f.model.appRunID, testRunID: runID, sequenceCutoff: 999998)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertFalse(events.contains { $0["event"] as? String == "afterExportCutoff" })
        XCTAssertTrue(url.lastPathComponent.contains(runID.uuidString))
        let summaries = try XCTUnwrap(json["summaries"] as? [[String: Any]])
        XCTAssertEqual(summaries.first?["isSavedRoute"] as? Bool, true)
        XCTAssertNotNil(summaries.first?["systemVersion"])
        await f.model.stopTracking()
    }
    func testAnchorAddFailureCannotSaveIncompleteRoute() async {
        let f = Fixture(); await f.start(); await f.model.chooseMode(.custom); await f.model.beginMarking()
        f.source.addFails = true; await f.model.recordStart()
        XCTAssertTrue(f.model.waypoints.isEmpty)
        XCTAssertFalse(f.model.canSave)
        XCTAssertNotNil(f.model.message)
        await f.model.stopTracking()
    }
    func testNonFiniteCurrentPoseCannotRenderOrAdvance() async {
        let f = Fixture(); await f.navigateLastSegment()
        f.source.emit(f.model.waypoints[5].id, pose(.nan))
        f.move(15)
        XCTAssertEqual(f.model.navigationBlockReason, .localSegmentUnavailable)
        XCTAssertEqual(f.model.layout.statistics.visible, 0)
        XCTAssertEqual(f.model.phase, .navigating)
        await f.model.stopTracking()
    }
    func testMixedDetectedFallbackAndMissingFloorStatistics() async {
        let s = scope(b: [8, 1.6, 0])
        let reference = FallbackFloorReference(id: UUID(), source: floor(), routeID: UUID(), generation: 1, epoch: 1,
            calibratedAt: Date(), scopes: [SegmentScope(index: 1, startID: s.startID, endID: s.endID, a: s.a, b: s.b, from: 2, to: 4)], halfWidth: 0.75)
        let layout = RouteLayout.make(current: s, next: nil, device: s.a, floors: [floor(1, width: 2)],
            fallback: reference, clearance: 0.01, navigating: true, configuration: .init())
        XCTAssertEqual(layout.statistics.candidate, 12)
        XCTAssertEqual(layout.statistics.placed, 6)
        XCTAssertEqual(layout.statistics.fallback, 3)
        XCTAssertEqual(layout.statistics.missing, 6)
        XCTAssertEqual(layout.statistics.coverage, "partial")
    }
    // T01/T11/T12: each scenario starts with the same independent, valid P5→P6.
    func testRemoteAnchorSilenceUntrackedAndRemovedDoNotGateLocalSegment() async {
        for event in ["silent", "untracked", "removed"] {
            let f = Fixture(); await f.navigateLastSegment()
            XCTAssertEqual(f.model.targetIndex, 5)
            let remote = f.model.waypoints[0].id
            if event == "untracked" { f.source.emit(remote, pose(0), tracked: false) }
            if event == "removed" { f.source.emit(remote, nil, event: .removed) }
            f.clock.time += 60; f.model.samplePosition()
            XCTAssertEqual(f.model.navigationBlockReason, .none, event)
            XCTAssertGreaterThan(f.model.layout.statistics.visible, 0, event)
            if event != "silent" { XCTAssertFalse(f.model.hasTrackedRoute) }
            await f.model.stopTracking()
        }
    }
    func testEitherCurrentEndpointRemovalStopsArrowsAndProgress() async {
        for index in [4, 5] {
            let f = Fixture(); await f.navigateLastSegment()
            f.source.emit(f.model.waypoints[index].id, nil, event: .removed)
            f.move(15)
            XCTAssertEqual(f.model.navigationBlockReason, .localSegmentUnavailable)
            XCTAssertEqual(f.model.layout.statistics.visible, 0)
            XCTAssertEqual(f.model.targetIndex, 5)
            XCTAssertEqual(f.model.phase, .navigating)
            await f.model.stopTracking()
        }
    }
    func testLocalUntrackedRecoveryUsesNewValidObservation() async {
        let f = Fixture(); await f.navigateLastSegment()
        let id = f.model.waypoints[4].id
        f.source.emit(id, pose(100), tracked: false)
        XCTAssertEqual(f.model.layout.statistics.visible, 0)
        f.source.emit(id, pose(12))
        XCTAssertEqual(f.model.navigationBlockReason, .none)
        XCTAssertEqual(f.model.usablePosition(for: 4)?.x, 12)
        await f.model.stopTracking()
    }
    func testDeviceLossLatchesUntilExplicitRelocalization() async {
        let f = Fixture(); await f.record(); _ = await f.save()
        await f.model.startNavigation()
        f.source.device = nil; f.model.samplePosition()
        XCTAssertEqual(f.model.coordinateValidity, .needsRevalidation)
        XCTAssertNil(f.model.currentRun)
        f.source.device = pose(0); f.model.samplePosition()
        XCTAssertFalse(f.model.canStartNavigation)
        XCTAssertEqual(f.model.layout.statistics.visible, 0)
        f.source.restoreOnStart = true
        await f.model.relocalize(); f.model.samplePosition()
        XCTAssertTrue(f.model.canStartNavigation)
        await f.model.stopTracking()
    }
    func testStartupNilDoesNotRepeatedlyInvalidateEpoch() async {
        let f = Fixture(); f.source.device = nil; await f.start()
        let epoch = f.model.coordinateEpoch
        for _ in 0..<10 { f.model.samplePosition() }
        XCTAssertEqual(f.model.coordinateEpoch, epoch)
        await f.model.stopTracking()
    }
    func testNoFloorAllowsStartAndRecoveryKeepsRunID() async {
        let f = Fixture(); await f.record()
        XCTAssertTrue(f.model.canStartNavigation)
        await f.model.startNavigation()
        let run = f.model.currentRun?.id
        XCTAssertEqual(f.model.layout.statistics.coverage, "unavailable")
        let value = floor(); f.model.apply(.floor(value.id, value))
        XCTAssertGreaterThan(f.model.layout.statistics.visible, 0)
        XCTAssertEqual(f.model.currentRun?.id, run)
        await f.model.stopTracking()
    }
    func testOffRouteHysteresisAndRecovery() async {
        let f = Fixture(); await f.record(); await f.model.startNavigation()
        f.move(1, 1.2)
        XCTAssertFalse(f.model.isOffRoute)
        f.clock.time += 0.6; f.model.samplePosition()
        XCTAssertTrue(f.model.isOffRoute)
        f.move(1, 0.8); XCTAssertTrue(f.model.isOffRoute)
        f.move(1, 0.5); XCTAssertFalse(f.model.isOffRoute)
        await f.model.stopTracking()
    }
    func testProviderAndAuthorizationFailuresPause() async {
        for input in [TrackingInput.provider(world: true, running: false, description: "error"), .authorization(allowed: false, description: "denied")] {
            let f = Fixture(); await f.record(); await f.model.startNavigation()
            f.model.apply(input)
            XCTAssertEqual(f.model.coordinateValidity, .needsRevalidation)
            XCTAssertEqual(f.model.layout.statistics.visible, 0)
            XCTAssertNil(f.model.currentRun)
            await f.model.stopTracking()
        }
    }
    func testPendingAnchorCannotStart() async {
        let f = Fixture(); await f.record(); let id = await f.save()
        await f.model.clearRoute()
        await f.model.stopTracking(); await f.start(); await f.model.loadRoute(id)
        XCTAssertFalse(f.model.canStartNavigation)
        XCTAssertEqual(f.model.loadState, .localizing)
        await f.model.stopTracking()
    }
    func testSavedAnchorsSurviveStopUnloadAndNewDraft() async throws {
        let f = Fixture(); await f.record(); let id = await f.save()
        let savedIDs = Set(f.model.waypoints.map(\.id))
        await f.model.stopTracking(); await f.model.stopTracking()
        XCTAssertTrue(f.source.removed.isEmpty)
        await f.start(); await f.model.clearRoute(); await f.model.chooseMode(.custom); await f.model.beginMarking()
        XCTAssertTrue(Set(f.source.removed).isDisjoint(with: savedIDs))
        let stored = try await f.store.load(id)
        XCTAssertEqual(Set(stored.waypoints.map(\.id)), savedIDs)
        await f.model.stopTracking()
    }
    func testNewSessionRestoresIDsUsingChangedWorldOrigin() async throws {
        let first = Fixture(); await first.record(); let id = await first.save()
        let original = first.source.anchors
        await first.model.stopTracking()
        let next = Fixture(root: first.root)
        var transform = simd_float4x4(simd_quatf(angle: .pi / 2, axis: [0, 1, 0]))
        transform.columns.3 = [50, 0, 20, 1]
        next.source.anchors = original.mapValues { transform * $0 }
        next.source.device = transform * pose(0)
        next.source.restoreOnStart = true
        await next.model.loadRoute(id)
        XCTAssertFalse(next.model.canStartNavigation)
        await next.start()
        XCTAssertTrue(next.model.canStartNavigation)
        XCTAssertEqual(next.model.usablePosition(for: 0)!.x, 50, accuracy: 0.001)
        XCTAssertEqual(next.model.usablePosition(for: 0)!.z, 20, accuracy: 0.001)
        XCTAssertTrue(next.source.added.isEmpty)
        await next.model.startNavigation()
        XCTAssertEqual(next.model.phase, .navigating)
        await next.model.stopTracking()
    }
    func testOnlyFirstSegmentNeededForRestorationAndLateSelectionWorks() async {
        let first = Fixture(); await first.record(count: 6); let id = await first.save()
        let points = first.model.waypoints
        await first.model.stopTracking()
        let next = Fixture(root: first.root)
        await next.start()
        next.source.emit(points[0].id, pose(0))
        next.source.emit(points[1].id, pose(3))
        await next.model.loadRoute(id)
        XCTAssertTrue(next.model.canStartNavigation)
        XCTAssertFalse(next.model.hasTrackedRoute)
        await next.model.stopTracking()
    }
    func testOneAnchorTimeoutAndWrongEnvironmentDoNotRecreateRoute() async {
        let first = Fixture(); await first.record(); let id = await first.save(); let origin = first.model.waypoints[0].id
        await first.model.stopTracking()
        let f = Fixture(root: first.root); await f.start(); await f.model.loadRoute(id)
        f.source.emit(UUID(), pose(0)) // unrelated scene
        f.source.emit(origin, pose(0))
        f.clock.time = 31; f.model.samplePosition()
        XCTAssertEqual(f.model.loadState, .unresolved)
        XCTAssertFalse(f.model.canStartNavigation)
        XCTAssertTrue(f.source.added.isEmpty)
        XCTAssertTrue(f.source.removed.isEmpty)
        await f.model.stopTracking()
    }
    func testLengthMismatchRejectsRestoredGeometry() async {
        let first = Fixture(); await first.record(); let id = await first.save(); let points = first.model.waypoints
        await first.model.stopTracking()
        let f = Fixture(root: first.root); await f.start(); await f.model.loadRoute(id)
        f.source.emit(points[0].id, pose(0)); f.source.emit(points[1].id, pose(30))
        XCTAssertFalse(f.model.canStartNavigation)
        await f.model.stopTracking()
    }
    func testOldTaskCallbackCannotPolluteNewSession() async {
        let f = Fixture(); await f.record(); _ = await f.save()
        let callback = f.source.onInput
        let point = f.model.waypoints[0].id
        await f.model.stopTracking(); await f.start()
        callback?(.waypoint(.init(id: point, event: .updated, pose: pose(999), isTracked: true)))
        XCTAssertNil(f.model.candidatePosition(0))
        await f.model.stopTracking()
    }
    func testRepeatAndCrossSessionTrialNumbers() async throws {
        let f = Fixture(); await f.record(); let id = await f.save()
        for number in 1...5 {
            f.move(0); await f.model.startNavigation()
            XCTAssertEqual(f.model.trialNumber, number)
            f.move(3); f.move(6)
            XCTAssertEqual(f.model.phase, .arrived)
            f.model.repeatNavigation()
        }
        let anchors = f.source.anchors
        await f.model.stopTracking()
        let next = Fixture(root: f.root); next.source.anchors = anchors; next.source.restoreOnStart = true
        await next.model.loadRoute(id); await next.start(); await next.model.startNavigation()
        XCTAssertEqual(next.model.trialNumber, 6)
        await next.model.stopTracking(); await next.model.refreshHistory()
        XCTAssertEqual(next.model.history.count, 6)
        XCTAssertEqual(next.model.history.filter { $0.result == "completed" }.count, 5)
    }
    func testDuplicateStopHasOneAbortedSummary() async {
        let f = Fixture(); await f.record(); await f.model.startNavigation()
        await f.model.stopTracking(); await f.model.stopTracking(); await f.model.refreshHistory()
        XCTAssertEqual(f.model.history.count, 1)
        XCTAssertEqual(f.model.history.first?.result, "aborted")
        XCTAssertEqual(f.source.stops, 1)
    }
    func testDeletionRetrySurvivesRestartAndProtectsOtherRoute() async throws {
        let f = Fixture(); await f.record(); let id = await f.save()
        let failure = f.model.waypoints[0].id
        f.source.removalFailures = [failure]
        await f.model.deleteSavedRoute(id)
        let pending = try await f.store.cleanupIDs()
        XCTAssertEqual(pending, [failure])
        let list = try await f.store.list(); XCTAssertTrue(list.isEmpty)
        await f.model.stopTracking()
        let next = Fixture(root: f.root); await next.start()
        XCTAssertTrue(next.source.removed.contains(failure))
        let remaining = try await next.store.cleanupIDs(); XCTAssertTrue(remaining.isEmpty)
        do { _ = try await next.store.load(id); XCTFail("Deleted route must stay tombstoned") } catch {}
        await next.model.stopTracking()
    }
    func testModeSwitchRequiresDraftDecisionAndDoesNotOverwriteSavedRoute() async throws {
        let f = Fixture(); XCTAssertNil(f.model.entryMode)
        await f.model.chooseMode(.saved); XCTAssertTrue(f.model.savedRoutes.isEmpty)
        await f.record(); let first = await f.save()
        await f.model.chooseMode(.custom); await f.model.beginMarking(); await f.model.recordStart()
        await f.model.chooseMode(.saved) // cancellation / no consent to discard
        XCTAssertEqual(f.model.entryMode, .custom)
        XCTAssertEqual(f.model.waypoints.count, 1)
        await f.model.chooseMode(.saved, discardDraft: true)
        XCTAssertEqual(f.model.entryMode, .saved)
        XCTAssertTrue(f.model.waypoints.isEmpty)
        let existing = try await f.store.load(first); XCTAssertEqual(existing.id, first)
        await f.model.stopTracking()
    }
    func testTemporaryRouteIsNotInSavedLibrary() async throws {
        let f = Fixture(); await f.record(); XCTAssertTrue(f.model.canStartNavigation)
        await f.model.startNavigation(); await f.model.clearRoute()
        let list = try await f.store.list(); XCTAssertTrue(list.isEmpty)
        XCTAssertEqual(f.source.removed.count, 3)
        await f.model.stopTracking()
    }
    func testSaveFileContainsNoWorldPoseAndLogsContainNoRouteCopy() async throws {
        let f = Fixture(); await f.record(); let id = await f.save(); await f.model.startNavigation()
        await f.model.stopTracking(); await f.model.refreshHistory(); await f.model.exportLogs(routeID: id)
        let routeURL = f.root.appendingPathComponent("SavedRoutes/\(id)/route.json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: routeURL)) as? [String: Any])
        XCTAssertNil(json["pose"]); XCTAssertNil(json["recordedPose"])
        let points = try XCTUnwrap(json["waypoints"] as? [[String: Any]])
        XCTAssertEqual(Set(points[0].keys), ["id", "kind"])
        let diagnostics = f.root.appendingPathComponent("NavigationTests/\(id)")
        let files = try FileManager.default.contentsOfDirectory(at: diagnostics, includingPropertiesForKeys: nil)
        XCTAssertFalse(files.contains { $0.lastPathComponent == "route.json" })
        let exported = try XCTUnwrap(f.model.exportURL)
        let export = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: exported)) as? [String: Any])
        XCTAssertNotNil(export["summaries"]); XCTAssertNotNil(export["events"])
    }
    func testCorruptAndUnwritableStoreReportErrors() async throws {
        let f = Fixture(); await f.record(); let id = await f.save()
        try Data("broken".utf8).write(to: f.root.appendingPathComponent("SavedRoutes/\(id)/route.json"))
        await f.model.refreshLibrary(); XCTAssertNotNil(f.model.libraryError)
        await f.model.clearRoute(); await f.model.loadRoute(id)
        XCTAssertEqual(f.model.loadState, .failed)
        await f.model.stopTracking()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: root)
        let store = RouteStore(root: root)
        do { try await store.registerDraftAnchor(routeID: UUID(), anchorID: UUID()); XCTFail("File cannot be directory") } catch {}
    }
    func testInterruptedHistoryAndLogWriteFailure() async throws {
        let f = Fixture(); await f.record(); await f.model.startNavigation(); await f.model.flushLogs()
        let history = try await f.recorder.history(currentAppRun: UUID())
        XCTAssertEqual(history.first?.result, "interrupted")
        let bad = f.root.appendingPathComponent("bad-log-root"); try Data().write(to: bad)
        let recorder = NavigationTestRecorder(root: bad)
        let model = RouteModel(tracking: FakeTracking(), store: f.store, recorder: recorder, automaticSampling: false)
        await model.startTracking(); model.samplePosition(); await model.flushLogs()
        XCTAssertNotNil(model.logError)
        XCTAssertTrue(model.isTrackingDevice)
        await model.stopTracking(); await f.model.stopTracking()
    }
    func testFallbackCalibrationAndSourceRemoval() async {
        let f = Fixture(); await f.record(); await f.calibrate()
        XCTAssertTrue(f.model.fallbackReference?.enabled == true, f.model.message ?? "")
        let source = f.model.fallbackReference!.source.id
        f.model.apply(.floor(source, nil))
        XCTAssertFalse(f.model.fallbackReference!.enabled)
        XCTAssertNotNil(f.model.fallbackReference!.invalidReason)
        await f.model.stopTracking()
    }
    func testCalibrationRequiresFloorAndExplicitConfirmation() async {
        let f = Fixture(); await f.record()
        await f.model.calibrateFallback(scopes: [(1,0,3)], confirmedFlat: true)
        XCTAssertNil(f.model.fallbackReference)
        let value = floor(); f.model.apply(.floor(value.id, value))
        await f.model.calibrateFallback(scopes: [(1,0,3)], confirmedFlat: false)
        XCTAssertNil(f.model.fallbackReference)
        await f.model.stopTracking()
    }
    func testFallbackHeightConflictLeavesDetectedArrowsVisible() async {
        let f = Fixture(); await f.record(); await f.calibrate()
        let source = f.model.fallbackReference!.source.id
        f.model.apply(.floor(source, floor(height: 0.2, id: source)))
        XCTAssertNotNil(f.model.fallbackReference!.invalidReason)
        XCTAssertEqual(f.model.navigationBlockReason, .none)
        XCTAssertGreaterThan(f.model.layout.statistics.visible, 0)
        XCTAssertEqual(f.model.layout.statistics.fallback, 0)
        await f.model.stopTracking()
    }
    func testFallbackGeometryAndCoordinateInvalidation() async {
        let f = Fixture(); await f.record(); await f.calibrate()
        let id = f.model.waypoints[1].id
        f.source.emit(id, pose(3.2))
        XCTAssertNotNil(f.model.fallbackReference?.invalidReason)
        f.model.markAnomaly()
        XCTAssertNil(f.model.fallbackReference)
        XCTAssertEqual(f.model.floorPlaneCount, 0)
        await f.model.stopTracking()
    }
    func testNextSegmentUnavailableDoesNotHideCurrentOrSkipTarget() async {
        let f = Fixture(); await f.record(); let value = floor(); f.model.apply(.floor(value.id, value)); await f.model.startNavigation()
        f.source.emit(f.model.waypoints[2].id, nil, event: .removed)
        XCTAssertGreaterThan(f.model.layout.statistics.visible, 0)
        XCTAssertTrue(f.model.layout.previewUnavailable)
        f.move(3)
        XCTAssertEqual(f.model.targetIndex, 1)
        XCTAssertEqual(f.model.navigationBlockReason, .localSegmentUnavailable)
        f.source.emit(f.model.waypoints[2].id, pose(6)); f.model.samplePosition()
        XCTAssertEqual(f.model.targetIndex, 2)
        await f.model.stopTracking()
    }

    private func scope(_ index: Int = 1, a: SIMD3<Float> = [0,1.6,0], b: SIMD3<Float> = [8,1.6,0]) -> SegmentScope {
        SegmentScope(index: index, startID: UUID(), endID: UUID(), a: a, b: b, from: 0, to: horizontalDistance(a,b))
    }
    func testPartialFloorShowsTenOfTwelveCandidates() async {
        let s = scope()
        let layout = RouteLayout.make(current: s, next: nil, device: s.a, floors: [floor(3.25, width: 6.5)], fallback: nil, clearance: 0.01, navigating: true, configuration: .init())
        XCTAssertEqual(layout.statistics.candidate, 12)
        XCTAssertEqual(layout.statistics.visible, 10)
        XCTAssertEqual(layout.statistics.missing, 2)
        XCTAssertEqual(layout.statistics.coverage, "partial")
    }
    func testFallbackOnlyCoversSelectedSegmentRange() async {
        let s = scope()
        let allowed = SegmentScope(index: 1, startID: s.startID, endID: s.endID, a: s.a, b: s.b, from: 0, to: 4)
        let fallback = FallbackFloorReference(id: UUID(), source: floor(), routeID: UUID(), generation: 1, epoch: 1, calibratedAt: Date(), scopes: [allowed], halfWidth: 0.75)
        let layout = RouteLayout.make(current: s, next: nil, device: s.a, floors: [], fallback: fallback, clearance: 0.01, navigating: true, configuration: .init())
        XCTAssertEqual(layout.statistics.fallback, 6)
        XCTAssertEqual(layout.statistics.coverage, "partial")
        XCTAssertFalse(fallback.covers([2,1.6,1], segment: 1))
        XCTAssertFalse(fallback.covers([2,1.6,0], segment: 2))
    }
    func testCornerPreviewAndFixedSampling() async {
        let current = scope(b: [10,1.6,0]), next = scope(2, a: [10,1.6,0], b: [10,1.6,20])
        let one = RouteLayout.make(current: current, next: next, device: [9.8,1.6,0], floors: [floor()], fallback: nil, clearance: 0.01, navigating: true, configuration: .init())
        XCTAssertFalse(one.placements.isEmpty)
        XCTAssertTrue(one.placements.allSatisfy { $0.segment == 2 && !$0.isActive })
        XCTAssertTrue(one.placements.allSatisfy { $0.position.z <= 9.8 })
        let two = RouteLayout.make(current: current, next: next, device: [9.9,1.6,0], floors: [floor()], fallback: nil, clearance: 0.01, navigating: true, configuration: .init())
        let lookup = Dictionary(uniqueKeysWithValues: one.placements.map { ($0.id, $0.position) })
        for item in two.placements { if let previous = lookup[item.id] { XCTAssertEqual(item.position, previous) } }
    }
    func testLongSegmentWindowFollowsMovementWithoutAnchorChanges() async {
        let current = scope(b: [100,1.6,0])
        let ground = floor(50, width: 110)
        let first = RouteLayout.make(current: current, next: nil, device: [0,1.6,0], floors: [ground], fallback: nil, clearance: 0.01, navigating: true, configuration: .init())
        let last = RouteLayout.make(current: current, next: nil, device: [60,1.6,0], floors: [ground], fallback: nil, clearance: 0.01, navigating: true, configuration: .init())
        XCTAssertLessThanOrEqual(first.statistics.candidate, 16)
        XCTAssertTrue(last.placements.allSatisfy { $0.position.x >= 60 && $0.position.x <= 70 })
        XCTAssertTrue(Set(first.placements.map(\.id)).isDisjoint(with: last.placements.map(\.id)))
    }
    func testNoCandidatesDistinctFromMissingFloorAndNotEvaluated() async {
        let s = scope(b: [1,1.6,0])
        let empty = RouteLayout.make(current: s, next: nil, device: s.b, floors: [], fallback: nil, clearance: 0.01, navigating: true, configuration: .init())
        XCTAssertEqual(empty.statistics.coverage, "noCandidates")
        XCTAssertEqual(NavigationLayout().statistics.coverage, "notEvaluated")
        let missing = RouteLayout.make(current: s, next: nil, device: s.a, floors: [], fallback: nil, clearance: 0.01, navigating: true, configuration: .init())
        XCTAssertEqual(missing.statistics.coverage, "unavailable")
    }
    func testRendererEnabledCountMatchesLayoutAndClearsOnLoss() async {
        let f = Fixture(); await f.record(); let value = floor(); f.model.apply(.floor(value.id, value))
        let renderer = RouteRenderer(); renderer.sync(with: f.model)
        XCTAssertEqual(renderer.enabledArrowCount, f.model.layout.statistics.visible)
        XCTAssertGreaterThan(renderer.enabledArrowCount, 0)
        f.source.device = nil; f.model.samplePosition(); renderer.sync(with: f.model)
        XCTAssertEqual(renderer.enabledArrowCount, 0)
        await f.model.stopTracking()
    }
}
