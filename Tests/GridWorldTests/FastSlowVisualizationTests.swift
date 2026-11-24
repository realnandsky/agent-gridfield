import Foundation
import Observation
import Testing
@testable import GridWorld

@MainActor
@Test(.timeLimit(.minutes(1)))
func apiExchangeTracksDurationSummaryAndWakeReason() async throws {
    let debugger = APIDebugger()
    let exchange = APIExchange(
        method: "POST",
        address: "https://viz.model.example/v1/chat/completions",
        requestHeaders: "",
        requestBody: "{}",
        brain: .fast,
        wakeReason: "plan_ready"
    )
    try debugger.record(exchange)
    #expect(debugger.exchanges.first?.finishedAt == nil)
    #expect(debugger.exchanges.first?.isLive == true)
    #expect(debugger.exchanges.first?.displaySummary == "plan ready")

    debugger.finish(exchange.id, with: .receiving(
        status: 200,
        phase: "Planning",
        preview: "First line\nChecking doorway orientation and east wall clearance"
    ))
    #expect(debugger.exchanges.first?.finishedAt == nil)
    #expect(debugger.exchanges.first?.isLive == true)
    #expect(debugger.exchanges.first?.displaySummary == "Planning")
    #expect(debugger.exchanges.first?.livePreviewLine == "Checking doorway orientation and east wall clearance")

    let fastBody = """
    {"choices":[{"message":{"tool_calls":[
      {"id":"c1","type":"function","function":{"name":"request_plan","arguments":"{\\"brief\\":\\"House\\"}"}},
      {"id":"c2","type":"function","function":{"name":"act","arguments":"{\\"actions\\":[{\\"action\\":\\"say\\",\\"text\\":\\"On it\\"}]}"}}
    ]}}]}
    """
    debugger.finish(exchange.id, with: .response(status: 200, headers: "", body: fastBody))
    let completed = try #require(debugger.exchanges.first)
    #expect(completed.finishedAt != nil)
    #expect(!completed.isLive)
    #expect(completed.summary == "request_plan + say")
    #expect(completed.displaySummary == "request_plan + say")

    let applyBody = """
    {"choices":[{"message":{"tool_calls":[
      {"id":"c3","type":"function","function":{"name":"act","arguments":"{\\"actions\\":[{\\"action\\":\\"apply_plan\\",\\"planID\\":\\"00000000-0000-0000-0000-000000000001\\"}]}"}}
    ]}}]}
    """
    #expect(APIExchange.summarize(brain: .fast, outcome: .response(status: 200, headers: "", body: applyBody)) == "apply_plan")

    let waitBody = """
    {"choices":[{"message":{"tool_calls":[
      {"id":"c4","type":"function","function":{"name":"act","arguments":"{\\"actions\\":[{\\"action\\":\\"acquire\\",\\"item\\":\\"plank\\",\\"count\\":12},{\\"action\\":\\"wait_for_plan\\"}]}"}}
    ]}}]}
    """
    #expect(APIExchange.summarize(brain: .fast, outcome: .response(status: 200, headers: "", body: waitBody)) == "acquire + wait_for_plan")

    let multiMoveBody = """
    {"choices":[{"message":{"tool_calls":[
      {"id":"c5","type":"function","function":{"name":"act","arguments":"{\\"actions\\":[{\\"action\\":\\"move\\",\\"direction\\":\\"east\\"},{\\"action\\":\\"move\\",\\"direction\\":\\"east\\"},{\\"action\\":\\"move\\",\\"direction\\":\\"north\\"}]}"}}
    ]}}]}
    """
    #expect(APIExchange.summarize(brain: .fast, outcome: .response(status: 200, headers: "", body: multiMoveBody)) == "move ×3")

    let slowPlacements = Array(repeating: #"{"x":9,"y":5,"structure":"floor"}"#, count: 67).joined(separator: ",")
    let slowPlanJSON = #"{"summary":"House","placements":[\#(slowPlacements)]}"#
    let escapedSlowContent = String(decoding: try JSONEncoder().encode(slowPlanJSON), as: UTF8.self)
    let slowBody = #"{"choices":[{"message":{"content":\#(escapedSlowContent)},"finish_reason":"stop"}]}"#
    #expect(APIExchange.summarize(brain: .slow, outcome: .response(status: 200, headers: "", body: slowBody)) == "67 placements")
    #expect(APIExchange.summarize(brain: .fast, outcome: .response(status: 400, headers: "", body: "{}")) == "HTTP 400")
    #expect(APIExchange.summarize(brain: .slow, outcome: .cancelled) == "Canceled")
    #expect(APIExchange.summarize(brain: .slow, outcome: .failed(message: "timeout")) == "Failed")

    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [VizStubProtocol.self]
    let urlSession = URLSession(configuration: config)
    defer { urlSession.invalidateAndCancel() }
    let endpoint = try #require(URL(string: "https://viz.model.example/v1/chat/completions"))
    let liveDebugger = APIDebugger()
    let game = GameSession(tickInterval: .zero)
    let client = ChatCompletionsModel(
        endpoint: endpoint, model: "test-viz", apiKey: nil, taskGoal: "Test wake reasons",
        streaming: false, session: urlSession, debugger: liveDebugger
    )
    game.start(model: client)
    await (try #require(game.task)).value

    try #require(liveDebugger.exchanges.count == 2)
    #expect(liveDebugger.exchanges[0].wakeReason == "start")
    #expect(liveDebugger.exchanges[0].summary == "say")
    #expect(liveDebugger.exchanges[0].finishedAt != nil)
    #expect(liveDebugger.exchanges[1].wakeReason == "tool_results")
    #expect(liveDebugger.exchanges[1].summary == "finish")
    #expect(liveDebugger.exchanges[1].finishedAt != nil)
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func sessionRecordsTimelineSegmentsHandoffsPlanStatusAndGhostLifecycle() async throws {
    let model = VisualizationGatedPlanner { index, turn, planner in
        switch index {
        case 0:
            return [
                vizRequestPlan("Two floor tiles"),
                vizAct("speak", #"[{"action":"say","text":"Planning layout."}]"#),
            ]
        case 1:
            return [vizWaitForPlan]
        case 2:
            await planner.waitForApplyGate()
            return [try vizApplyPlan(turn)]
        default:
            return [vizFinish]
        }
    }
    let game = GameSession(tickInterval: .milliseconds(5))
    defer {
        game.stop()
        Task { await model.close() }
    }

    game.start(model: model)

    try await waitUntil {
        await model.requests.count == 1 && game.phase == .waitingForPlan && game.isPlanning
    }
    #expect(game.runStartedAt != nil)
    #expect(game.runEndedAt == nil)
    #expect(game.latestPlan?.status == .planning)
    #expect(game.latestPlan?.brief == "Two floor tiles")
    #expect(game.blueprintOverlay.isEmpty)
    #expect(game.engineSegments.contains { $0.kind == .waitingForPlan && $0.endedAt == nil })
    #expect(game.engineSegments.filter { $0.kind == .intent }.map(\.label) == ["say"])

    let placements = [
        BlueprintPlacement(x: 9, y: 5, structure: .floor),
        BlueprintPlacement(x: 10, y: 5, structure: .floor),
    ]
    await model.deliver("Two floor tiles", proposal: PlanProposal(summary: "Two floors east of spawn", placements: placements))

    try await waitUntil {
        game.pendingPlanSummary != nil && game.planHandoffs.count == 1 && !game.isPlanning
    }
    #expect(game.planHandoffs.first?.outcome == .ready)
    #expect(game.planHandoffs.first?.placementCount == 2)
    #expect(game.latestPlan?.status == .ready)
    #expect(game.latestPlan?.placementCount == 2)
    #expect(game.latestPlan?.bounds == [[9, 5], [10, 5]])
    #expect(game.latestPlan?.summary == "Two floors east of spawn")
    #expect(game.latestPlan?.createdTick != nil)
    #expect(game.blueprintOverlay == placements)

    await model.openApplyGate()

    try await waitUntil { !game.isRunning }
    #expect(game.phase == .idle)
    #expect(game.runEndedAt != nil)
    #expect(game.latestPlan?.status == .applied)
    #expect(game.blueprintOverlay.isEmpty)
    #expect(game.engineSegments.allSatisfy { $0.endedAt != nil })
    #expect(game.engineSegments.contains { $0.kind == .waitingForPlan && $0.status == .completed })
    #expect(game.engineSegments.contains { $0.kind == .intent && $0.label == "apply_plan" && $0.status == .completed })
    #expect(game.world.tile(at: Position(x: 9, y: 5))?.hasFloor == true)
    #expect(game.world.tile(at: Position(x: 10, y: 5))?.hasFloor == true)
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func directBuildBlueprintExposesAndClearsGhostOverlay() async throws {
    let placements = [
        BlueprintPlacement(x: 9, y: 5, structure: .floor),
        BlueprintPlacement(x: 10, y: 5, structure: .floor),
    ]
    let encoded = #"[{"x":9,"y":5,"structure":"floor"},{"x":10,"y":5,"structure":"floor"}]"#
    let model = VisualizationGatedPlanner { index, _, _ in
        index == 0
            ? [vizAct("build", #"[{"action":"build_blueprint","placements":\#(encoded)}]"#)]
            : [vizFinish]
    }
    let game = GameSession(tickInterval: .milliseconds(25))
    defer {
        game.stop()
        Task { await model.close() }
    }

    game.start(model: model)
    var observedOverlay: [BlueprintPlacement] = []
    while game.isRunning {
        if !game.blueprintOverlay.isEmpty {
            observedOverlay = game.blueprintOverlay
            break
        }
        await withCheckedContinuation { continuation in
            withObservationTracking {
                _ = game.blueprintOverlay
                _ = game.isRunning
            } onChange: {
                continuation.resume()
            }
        }
    }
    try await waitUntil { !game.isRunning }

    #expect(observedOverlay == placements)
    #expect(game.blueprintOverlay.isEmpty)
    #expect(game.engineSegments.contains { $0.kind == .intent && $0.label == "build_blueprint (2)" && $0.status == .completed })
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func stopResetAndInterruptCleanlyClearGhostOverlayAndStatus() async throws {
    let placements = [
        BlueprintPlacement(x: 9, y: 5, structure: .floor),
        BlueprintPlacement(x: 10, y: 5, structure: .floor),
    ]
    let model = VisualizationGatedPlanner { index, turn, planner in
        switch index {
        case 0:
            return [vizRequestPlan("Initial plan"), vizWaitForPlan]
        case 1:
            if turn.context?.wakeReason == .planReady {
                await planner.waitForApplyGate()
            }
            return [vizRequestPlan("Stale plan"), vizWaitForPlan]
        case 2:
            return [vizRequestPlan("Second plan"), vizWaitForPlan]
        case 3:
            return [vizRequestPlan("Third plan"), vizWaitForPlan]
        default:
            return [vizFinish]
        }
    }
    let game = GameSession(tickInterval: .milliseconds(5))
    defer {
        game.stop()
        Task { await model.close() }
    }

    // 1) Deliver plan -> verify ghost overlay is active -> interruptIntent clears pending ghost & plan
    game.start(model: model)
    try await waitUntil {
        await model.requests.count == 1 && game.phase == .waitingForPlan && game.isPlanning
    }
    await model.deliver("Initial plan", proposal: PlanProposal(summary: "Initial", placements: placements))
    try await waitUntil { !game.blueprintOverlay.isEmpty && game.pendingPlanSummary != nil }

    game.interruptIntent()
    #expect(game.blueprintOverlay.isEmpty)
    #expect(game.pendingPlanSummary == nil)
    #expect(!game.isPlanning)
    #expect(game.planHistory.first?.status == .cancelled)

    // 2) While planning in background, interruptIntent closes wait segment and records cancelled handoff
    await model.openApplyGate()
    try await waitUntil {
        await model.requests.count == 2 && game.phase == .waitingForPlan && game.isPlanning
    }
    game.interruptIntent()
    #expect(!game.isPlanning)
    #expect(game.planHandoffs.contains { $0.outcome == .cancelled })
    #expect(game.latestPlan?.status == .cancelled)
    #expect(game.engineSegments.contains { $0.kind == .waitingForPlan && $0.status == .interrupted && $0.endedAt != nil })

    // 3) While planning again, stop() resets phase to idle and closes timeline cleanly
    try await waitUntil {
        await model.requests.count == 3 && game.phase == .waitingForPlan && game.isPlanning
    }
    game.stop()
    #expect(!game.isRunning)
    #expect(game.phase == .idle)
    #expect(game.runEndedAt != nil)
    #expect(game.blueprintOverlay.isEmpty)
    #expect(game.engineSegments.allSatisfy { $0.endedAt != nil })

    // 4) reset() wipes run timeline, plan history, and ghost overlay
    game.reset()
    #expect(game.runStartedAt == nil)
    #expect(game.runEndedAt == nil)
    #expect(game.engineSegments.isEmpty)
    #expect(game.planHandoffs.isEmpty)
    #expect(game.planHistory.isEmpty)
    #expect(game.blueprintOverlay.isEmpty)
}

@MainActor
@Test func visionFrameNeverDrawsGhostBlueprintAndSatisfiedTilesClearProgressively() throws {
    var world = World(bushCount: 0, inventory: [.plank: 10, .grassBed: 2])
    let placements = [
        BlueprintPlacement(x: 9, y: 5, structure: .floor),
        BlueprintPlacement(x: 9, y: 5, structure: .grassBed),
        BlueprintPlacement(x: 8, y: 6, structure: .wall),
    ]

    let cleanPNG = try #require(WorldMap(world: world).visionFrame()?.png)
    let ghostedPNG = try #require(WorldMap(world: world, ghostPlacements: placements).visionFrame()?.png)
    #expect(cleanPNG == ghostedPNG)
    #expect(placements.map { WorldMap.isPlacementSatisfied($0, in: world) } == [false, false, false])

    #expect(world.apply(.place(.east, .floor)) == .placed)
    #expect(placements.map { WorldMap.isPlacementSatisfied($0, in: world) } == [true, false, false])

    #expect(world.apply(.place(.east, .grassBed)) == .placed)
    #expect(placements.map { WorldMap.isPlacementSatisfied($0, in: world) } == [true, true, false])

    #expect(world.apply(.place(.south, .wall)) == .placed)
    #expect(placements.map { WorldMap.isPlacementSatisfied($0, in: world) } == [true, true, true])

    let afterBuildClean = try #require(WorldMap(world: world).visionFrame()?.png)
    let afterBuildGhosted = try #require(WorldMap(world: world, ghostPlacements: placements).visionFrame()?.png)
    #expect(afterBuildClean == afterBuildGhosted)
}

private enum VizTestError: Error { case timedOut, proposalMissing }

private func vizRequestPlan(_ brief: String) -> ToolCall {
    ToolCall(id: brief, type: "function", function: .init(name: "request_plan", arguments: #"{"brief":"\#(brief)"}"#))
}

private func vizAct(_ id: String, _ actions: String) -> ToolCall {
    ToolCall(id: id, type: "function", function: .init(name: "act", arguments: #"{"actions":\#(actions)}"#))
}

private let vizWaitForPlan = vizAct("wait", #"[{"action":"wait_for_plan"}]"#)
private let vizFinish = vizAct("finish", #"[{"action":"finish"}]"#)

private func vizApplyPlan(_ turn: VisualizationGatedPlanner.Turn) throws -> ToolCall {
    guard let id = turn.context?.pendingPlan?.planID else { throw VizTestError.proposalMissing }
    return vizAct("apply", #"[{"action":"apply_plan","planID":"\#(id)"}]"#)
}

@MainActor
private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(4))
    while !(await condition()) {
        guard clock.now < deadline else { throw VizTestError.timedOut }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private actor VisualizationGatedPlanner: CharacterModel {
    struct Turn: Sendable {
        let context: ModelContext?
        let replies: [ToolReceipt]
    }

    struct Request: Sendable {
        let id: UUID
        let brief: String
    }

    private let decision: @Sendable (Int, Turn, VisualizationGatedPlanner) async throws -> [ToolCall]
    private var awaiting: [String: CheckedContinuation<PlanProposal, any Error>] = [:]
    private var applyGateOpen = false
    private var applyWaiters: [CheckedContinuation<Void, Never>] = []
    private var closed = false
    private(set) var turns: [Turn] = []
    private(set) var requests: [Request] = []

    init(decision: @escaping @Sendable (Int, Turn, VisualizationGatedPlanner) async throws -> [ToolCall]) {
        self.decision = decision
    }

    func chooseTools(_ turn: ModelTurn) async throws -> [ToolCall] {
        let captured: Turn
        switch turn {
        case .initial(_, _, let context):
            captured = Turn(context: context, replies: [])
        case .result(let replies, let context):
            captured = Turn(context: context, replies: replies.map(\.receipt))
        }
        let index = turns.count
        turns.append(captured)
        return try await decision(index, captured, self)
    }

    func plan(brief: String, observation: WorldObservation, vision: VisionCall?, planID: UUID) async throws -> PlanProposal {
        guard !closed else { throw CancellationError() }
        requests.append(Request(id: planID, brief: brief))
        return try await withCheckedThrowingContinuation { awaiting[brief] = $0 }
    }

    func deliver(_ brief: String, proposal: PlanProposal) {
        awaiting.removeValue(forKey: brief)?.resume(returning: proposal)
    }

    func waitForApplyGate() async {
        if applyGateOpen { return }
        await withCheckedContinuation { applyWaiters.append($0) }
    }

    func openApplyGate() {
        applyGateOpen = true
        let waiters = applyWaiters
        applyWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func close() {
        closed = true
        for continuation in awaiting.values { continuation.resume(throwing: CancellationError()) }
        awaiting.removeAll()
        openApplyGate()
    }
}

private final class VizStubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "viz.model.example"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let bodyData = request.httpBody ?? readStream()
        let body = bodyData.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let isFollowUp = body.contains(#""tool_call_id":"viz-say""#)
        let call = isFollowUp
            ? vizFinish
            : vizAct("viz-say", #"[{"action":"say","text":"Hi"}]"#)
        let encoded = String(decoding: try! JSONEncoder().encode(call), as: UTF8.self)
        let data = Data(#"{"choices":[{"message":{"tool_calls":[\#(encoded)]},"finish_reason":"tool_calls"}]}"#.utf8)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func readStream() -> Data? {
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { return count == 0 ? data : nil }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
}
