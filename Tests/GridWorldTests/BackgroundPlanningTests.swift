import Foundation
import Testing
@testable import GridWorld

@MainActor
@Test(.timeLimit(.minutes(1)))
func fastBrainActsWhilePlanningThenBuildsTheSavedProposal() async throws {
    let model = GatedPlanner { index, turn in
        switch index {
        case 0:
            [requestPlan("Two floor tiles"), act("speak", #"[{"action":"say","text":"I'll plan the layout."}]"#)]
        case 1:
            [waitForPlan]
        case 2:
            [try applyPlan(turn)]
        default:
            [finish]
        }
    }
    let game = GameSession(tickInterval: .milliseconds(3))
    defer { cleanUp(game, model) }
    game.start(model: model)

    try await waitUntilParked(game, model, activities: 3)
    #expect(game.messages.map(\.text) == ["I'll plan the layout."])
    #expect(game.world.tile(at: Position(x: 9, y: 5))?.hasFloor == false)
    let beforeProposal = await model.turns
    try #require(beforeProposal.count == 2)
    #expect(beforeProposal[0].context?.wakeReason == .start)
    #expect(beforeProposal[0].context?.activePlan == nil)
    #expect(beforeProposal[1].context?.wakeReason == .toolResults)
    #expect(beforeProposal[1].context?.planInProgress == true)
    #expect(beforeProposal[1].replies.map(\.results) == [[.planRequested], [.messageSent]])
    let id = try #require(beforeProposal[1].replies.first?.requestedPlanID)
    #expect(beforeProposal[1].context?.activePlan?.planID == id)
    #expect(beforeProposal[1].context?.activePlan?.brief == "Two floor tiles")
    #expect(beforeProposal[1].context?.recentMessages.map(\.text) == ["I'll plan the layout."])
    #expect(await model.requests.first?.id == id)
    #expect(await model.requests.first?.brief == "Two floor tiles")
    await model.deliver("Two floor tiles", proposal: PlanProposal(summary: "Two floors east of spawn", placements: [
        BlueprintPlacement(x: 9, y: 5, structure: .floor),
        BlueprintPlacement(x: 10, y: 5, structure: .floor),
    ]))

    try await eventually { !game.isRunning }
    let turns = await model.turns
    try #require(turns.count == 4)
    let ready = try #require(turns[2].context)
    let summary = try #require(ready.pendingPlan)
    #expect(ready.wakeReason == .planReady)
    #expect(!ready.planInProgress)
    #expect(ready.activePlan == nil)
    #expect(summary.planID == id)
    #expect(summary.summary == "Two floors east of spawn")
    #expect(summary.placementCount == 2)
    #expect(summary.bounds == [[9, 5], [10, 5]])
    #expect(summary.createdTick <= ready.worldTick)
    #expect(summary.createdTick >= (beforeProposal[1].context?.worldTick ?? 0))
    #expect(turns[2].replies.first?.results == [.waitingForPlan])
    #expect(ready.recentMessages.map(\.text) == ["I'll plan the layout."])
    #expect(turns[3].replies.first?.results == [.built])
    #expect(turns[3].replies.first?.appliedPlan?.planID == id)
    #expect(turns[3].replies.first?.appliedPlan?.summary == summary.summary)
    #expect((turns[3].replies.first?.plans?.first?.steps ?? 0) >= 2)
    #expect(turns[3].context?.pendingPlan == nil)
    #expect(game.world.tile(at: Position(x: 9, y: 5))?.hasFloor == true)
    #expect(game.world.tile(at: Position(x: 10, y: 5))?.hasFloor == true)
    #expect(game.issue == nil)
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func unusablePlannerLayoutWakesFastBrainWithFailure() async throws {
    let model = GatedPlanner { index, _ in
        index == 0 ? [requestPlan("One floor"), waitForPlan] : [finish]
    }
    let game = GameSession(tickInterval: .milliseconds(3))
    defer { cleanUp(game, model) }
    let original = game.world
    game.start(model: model)

    try await waitUntilParked(game, model, activities: 2)
    await model.deliver("One floor", proposal: PlanProposal(summary: "Bad floor", placements: [
        BlueprintPlacement(x: -1, y: 0, structure: .floor),
    ]))

    try await eventually { !game.isRunning }
    let failed = try #require(await model.turns.last?.context)
    #expect(failed.wakeReason == .planFailed)
    #expect(failed.planFailure?.contains("outside the map") == true)
    #expect(failed.pendingPlan == nil)
    #expect(!failed.planInProgress)
    #expect(failed.activePlan == nil)
    #expect(game.world == original)
    #expect(game.issue == nil)
}

@MainActor
@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func steeringCancelsTheOldPlannerAndOnlyTheReplacementCanBuild(playerInput: Bool) async throws {
    let model = GatedPlanner { index, turn in
        switch index {
        case 0: [requestPlan("Old layout"), waitForPlan]
        case 1: [requestPlan("New layout"), waitForPlan]
        case 2: [try applyPlan(turn)]
        default: [finish]
        }
    }
    let game = GameSession(tickInterval: .milliseconds(3))
    defer { cleanUp(game, model) }
    game.start(model: model)

    try await waitUntilParked(game, model, activities: 2)
    let steering = "Build farther east."
    if playerInput { game.playerInstructionsChanged(to: steering) } else { game.interruptIntent() }
    try await waitUntilParked(game, model, activities: 4, requests: 2)
    let requests = await model.requests
    let afterSteering = try #require(await model.turns.last?.context)
    #expect(afterSteering.wakeReason == (playerInput ? .playerInput : .intentInterrupted))
    #expect(!afterSteering.planInProgress)
    #expect(afterSteering.activePlan == nil)
    #expect(afterSteering.pendingPlan == nil)
    #expect(afterSteering.recentMessages.map(\.text) == (playerInput ? [steering] : []))
    #expect(requests[0].id != requests[1].id)

    await model.deliver("Old layout", proposal: floorProposal(x: 9))
    try await eventually { await model.returnedAfterCancellation("Old layout") }
    #expect(game.isPlanning)
    await model.deliver("New layout", proposal: floorProposal(x: 10))

    try await eventually { !game.isRunning }
    let turns = await model.turns
    try #require(turns.count == 4)
    #expect(turns[2].context?.wakeReason == .planReady)
    #expect(turns[2].context?.pendingPlan?.planID == requests[1].id)
    #expect(game.world.tile(at: Position(x: 9, y: 5))?.hasFloor == false)
    #expect(game.world.tile(at: Position(x: 10, y: 5))?.hasFloor == true)
    #expect(game.issue == nil)
}

@MainActor
@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func endingARunCancelsPlanningAndDiscardsLateResults(reset: Bool) async throws {
    let model = GatedPlanner { index, _ in
        index == 0 ? [requestPlan("A discarded floor"), waitForPlan] : [finish]
    }
    let game = GameSession(tickInterval: .milliseconds(3))
    defer { cleanUp(game, model) }
    game.start(model: model)
    let stoppedTask = try #require(game.task)

    try await waitUntilParked(game, model, activities: 2)
    if reset { game.reset() } else { game.stop() }
    await stoppedTask.value
    #expect(!game.isRunning)
    #expect(!game.isPlanning)
    if reset { #expect(game.worldTick == 0) }

    await model.deliver("A discarded floor", proposal: floorProposal(x: 9))
    try await eventually { await model.returnedAfterCancellation("A discarded floor") }
    game.start(model: model)
    try await eventually { !game.isRunning }

    let turns = await model.turns
    try #require(turns.count == 2)
    #expect(turns[1].context?.wakeReason == .start)
    #expect(turns[1].context?.pendingPlan == nil)
    #expect(turns[1].context?.planFailure == nil)
    #expect(game.world.tile(at: Position(x: 9, y: 5))?.hasFloor == false)
    #expect(game.issue == nil)
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func playerInputWakesFastBrainBeforeTheSupersededRequestReturns() async throws {
    let game = GameSession(tickInterval: .milliseconds(3))
    let model = SuspendedFastDecision()
    defer {
        game.stop()
        Task { await model.release() }
    }
    game.start(model: model)
    try await eventually { await model.isSuspended }
    game.playerInstructionsChanged(to: "Move the entrance.")
    try await eventually { !game.isRunning }
    #expect(game.messages.map(\.text) == ["Move the entrance.", "I heard you."])
    await model.release()
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func fastBrainSeesTheLastThreeDeliveredMessagesUntilWorldReset() async throws {
    let model = GatedPlanner { index, _ in
        if index == 0 {
            return [act("speak", #"""
                [{"action":"say","text":"I'll look around."},
                 {"action":"say","text":"The east side is clear."},
                 {"action":"finish"},{"action":"say","text":"Skipped."}]
                """#)]
        }
        return [finish]
    }
    let game = GameSession(tickInterval: .milliseconds(3))
    defer { cleanUp(game, model) }

    game.playerInstructionsChanged(to: "Build near the lake.")
    game.start(model: model)
    try await eventually { !game.isRunning }
    game.playerInstructionsChanged(to: "Use an east entrance.")
    game.playerInstructionsChanged(to: "")
    game.start(model: model)
    try await eventually { !game.isRunning }
    game.reset()
    game.start(model: model)
    try await eventually { !game.isRunning }

    let turns = await model.turns
    try #require(turns.count == 3)
    #expect(turns[0].context?.recentMessages.map(\.text) == ["Build near the lake."])
    #expect(turns[1].context?.recentMessages.map(\.sender) == ["Character", "Character", "Player"])
    #expect(turns[1].context?.recentMessages.map(\.text) == [
        "I'll look around.", "The east side is clear.", "Use an east entrance.",
    ])
    #expect(turns[2].context?.recentMessages.isEmpty == true)
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func threeFailedIntentsSuggestPlanningInContextAndReceipt() async throws {
    let model = GatedPlanner { index, _ in
        if index == 5 { return [finish] }
        if index == 3 { return [act("success", #"[{"action":"say","text":"I'll change my approach."}]"#)] }
        return [act("failed-\(index)", #"[{"action":"walk_to","x":-1,"y":0}]"#)]
    }
    let game = GameSession(tickInterval: .milliseconds(3))
    defer { cleanUp(game, model) }
    game.start(model: model)
    try await eventually { !game.isRunning }

    let turns = await model.turns
    try #require(turns.count == 6)
    #expect(turns[1...3].allSatisfy { $0.context?.wakeReason == .intentFailed })
    #expect(turns[1...3].flatMap(\.replies).map(\.results) == Array(repeating: [.boundary], count: 3))
    #expect(turns[1..<3].allSatisfy { $0.context?.planningSuggested == nil })
    #expect(turns[3].context?.planningSuggested == true)
    #expect(turns[3].replies.first?.planningSuggested == true)
    #expect(turns[4].context?.planningSuggested == nil)
    #expect(turns[5].context?.planningSuggested == nil)
    #expect(turns[5].replies.first?.planningSuggested == nil)
    #expect(game.issue == nil)
}

private actor SuspendedFastDecision: CharacterModel {
    private var continuation: CheckedContinuation<[ToolCall], Never>?

    var isSuspended: Bool { continuation != nil }

    func chooseTools(_ turn: ModelTurn) async throws -> [ToolCall] {
        switch turn {
        case .initial(_, _, let context) where context?.wakeReason == .start:
            return await withCheckedContinuation { continuation = $0 }
        case .initial(_, _, let context) where context?.wakeReason == .playerInput:
            return [act("updated", #"[{"action":"say","text":"I heard you."},{"action":"finish"}]"#)]
        default:
            return [finish]
        }
    }

    func release() {
        continuation?.resume(returning: [act("stale", #"[{"action":"say","text":"Stale response"}]"#)])
        continuation = nil
    }
}

private enum PlanningTestError: Error { case timedOut, proposalMissing }

private func requestPlan(_ brief: String) -> ToolCall {
    ToolCall(id: brief, type: "function", function: .init(name: "request_plan", arguments: #"{"brief":"\#(brief)"}"#))
}

private func act(_ id: String, _ actions: String) -> ToolCall {
    ToolCall(id: id, type: "function", function: .init(name: "act", arguments: #"{"actions":\#(actions)}"#))
}

private let waitForPlan = act("wait", #"[{"action":"wait_for_plan"}]"#)
private let finish = act("finish", #"[{"action":"finish"}]"#)

private func applyPlan(_ turn: GatedPlanner.Turn) throws -> ToolCall {
    guard let id = turn.context?.pendingPlan?.planID else { throw PlanningTestError.proposalMissing }
    return act("apply", #"[{"action":"apply_plan","planID":"\#(id)"}]"#)
}

private func floorProposal(x: Int) -> PlanProposal {
    PlanProposal(summary: "One floor", placements: [BlueprintPlacement(x: x, y: 5, structure: .floor)])
}

@MainActor
private func waitUntilParked(_ game: GameSession, _ model: GatedPlanner, activities: Int, requests: Int = 1) async throws {
    try await eventually {
        let count = await model.requests.count
        return count == requests && game.isPlanning && game.toolActivity.count == activities && !game.hasActiveIntent
    }
}

@MainActor
private func eventually(_ condition: @MainActor () async -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(3))
    while !(await condition()) {
        guard clock.now < deadline else { throw PlanningTestError.timedOut }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
private func cleanUp(_ game: GameSession, _ model: GatedPlanner) {
    game.stop()
    Task { await model.close() }
}

private actor GatedPlanner: CharacterModel {
    struct Turn: Sendable {
        let context: ModelContext?
        let replies: [ToolReceipt]
    }

    struct Request: Sendable {
        let id: UUID
        let brief: String
    }

    private let decision: @Sendable (Int, Turn) throws -> [ToolCall]
    private var awaiting: [String: CheckedContinuation<PlanProposal, any Error>] = [:]
    private var lateResults: Set<String> = []
    private var closed = false
    private(set) var turns: [Turn] = []
    private(set) var requests: [Request] = []

    init(decision: @escaping @Sendable (Int, Turn) throws -> [ToolCall]) {
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
        return try decision(index, captured)
    }

    func plan(brief: String, observation: WorldObservation, vision: VisionCall?, planID: UUID) async throws -> PlanProposal {
        guard !closed else { throw CancellationError() }
        requests.append(Request(id: planID, brief: brief))
        let result: PlanProposal = try await withCheckedThrowingContinuation { awaiting[brief] = $0 }
        if Task.isCancelled { lateResults.insert(brief) }
        return result
    }

    func deliver(_ brief: String, proposal: PlanProposal) {
        awaiting.removeValue(forKey: brief)?.resume(returning: proposal)
    }

    func returnedAfterCancellation(_ brief: String) -> Bool { lateResults.contains(brief) }

    func close() {
        closed = true
        for continuation in awaiting.values { continuation.resume(throwing: CancellationError()) }
        awaiting.removeAll()
    }
}
