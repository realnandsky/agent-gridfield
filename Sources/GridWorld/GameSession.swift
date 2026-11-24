import Foundation
import Observation

struct PlanSummary: Encodable, Sendable {
    let planID: UUID
    let createdTick: UInt64
    let summary: String
    let placementCount: Int
    let bounds: [[Int]]
}

struct ModelContext: Encodable, Sendable {
    let worldTick: UInt64
    let wakeReason: GameSession.WakeReason
    let planInProgress: Bool
    let pendingPlan: PlanSummary?
    let planFailure: String?
    let planningSuggested: Bool?
}

struct CharacterMessage: Identifiable, Encodable {
    let id = UUID()
    let sender: String
    let text: String
}

struct ToolActivity: Identifiable {
    let id: Int
    let function: ToolCall.Function
    let tool: CharacterTool?
    var summary = "Running"
    var needsAttention = false
    var planFailure: PlanFailure?

    mutating func finish(_ receipt: ToolReceipt) {
        if let failure = receipt.results.first(where: { !$0.success }) {
            summary = failure.rawValue.replacingOccurrences(of: "_", with: " ").capitalized
            needsAttention = true
            planFailure = receipt.plans?.compactMap(\.failure).first
        } else {
            switch tool {
            case .act: summary = receipt.results.count == 1 ? "1 action" : "\(receipt.results.count) actions"
            case .vision: summary = "Frame captured"
            case .memory: summary = receipt.memory?.update == .applied ? "Memory updated" : "Unchanged"
            case .requestPlan: summary = "Plan requested"
            case nil: summary = "Unknown tool"
            }
        }
        if receipt.skipped > 0 { summary += " · \(receipt.skipped) skipped" }
    }
}

@MainActor
@Observable
final class GameSession {
    private final class ActiveIntent {
        let id = UUID()
        let call: ToolCall
        let activityIndex: Int
        let continuation: CheckedContinuation<ToolReply, any Error>
        var execution: IntentExecution
        var history: [HistoryEvent] = []
        var planning: Task<Void, Never>?
        var applyingPlan: PlanSummary?
        var appliedPlan: PlanSummary?

        init(call: ToolCall, activityIndex: Int, continuation: CheckedContinuation<ToolReply, any Error>) {
            self.call = call
            self.activityIndex = activityIndex
            self.continuation = continuation
            execution = IntentExecution(actions: (try? call.decodeBatch().actions) ?? [])
        }
    }

    private struct PlannerWork {
        let id: UUID
        let task: Task<Void, Never>
        let vision: VisionCall?
    }

    private struct FastDecision {
        let task: Task<Void, Never>
        let replies: AsyncStream<Result<[ToolCall], any Error>>.Continuation
    }

    private struct SavedPlan {
        let summary: PlanSummary
        let placements: [BlueprintPlacement]
    }

    struct DebugInputs: Encodable, Equatable {
        let goal: String
        var instructions: String
        let address: String
        let model: String
        let reasoningEffort: String
        let streaming: Bool
        var visionEnabled = false
    }

    private enum RunPhase: String, Encodable {
        case idle
        case awaitingModel = "awaiting_model"
        case executingIntent = "executing_intent"
        case waitingForPlan = "waiting_for_plan"
    }

    enum WakeReason: String, Encodable, Sendable {
        case start, toolResults = "tool_results"
        case intentFailed = "intent_failed", intentInterrupted = "intent_interrupted"
        case planReady = "plan_ready", planFailed = "plan_failed", playerInput = "player_input"
    }

    private struct ModelWake: Encodable {
        let runID: UUID
        let tick: UInt64
        let reason: WakeReason
    }

    private struct BatchProgress: Encodable {
        let toolCallID: String
        let exchangeID: UUID?
        let attempted: Int
        var skipped = 0
        var processed = 0
    }

    private struct IntentEvent: Encodable {
        let runID: UUID
        let tick: UInt64
        let batch: BatchProgress
        var call: ToolCall? = nil
        var reason: String? = nil
    }

    private struct ToolEvent: Encodable {
        let runID: UUID
        let call: ToolCall
        let exchangeID: UUID?
        let receipt: ToolReceipt
    }

    private struct ActionEvent: Encodable {
        let runID: UUID
        let toolCallID: String
        let index: Int
        let result: ActionOutcome
        let tick: UInt64
    }

    private struct WalkStepEvent: Encodable {
        let runID: UUID
        let toolCallID: String
        let index: Int
        let step: Int
        let avatar: [Int]
        let tick: UInt64
    }

    private struct PlanStepEvent: Encodable {
        let runID: UUID
        let toolCallID: String
        let index: Int
        let step: Int
        let action: HistoryEvent
        let tick: UInt64
    }

    private struct RunEnd: Encodable {
        let runID: UUID
        let reason: String
        let batch: BatchProgress?
    }

    private struct DebugSnapshot: Encodable {
        struct TileItems: Encodable {
            let position: [Int]
            let loose: [String: Int]
            let attached: [String: Int]
        }

        let schemaVersion = 5
        let timestamp = Date()
        let processID = ProcessInfo.processInfo.processIdentifier
        let runID: UUID?
        let phase: RunPhase
        let isRunning: Bool
        let worldTick: UInt64
        let planInProgress: Bool
        let pendingPlan: PlanSummary?
        let planFailure: String?
        let inputs: DebugInputs?
        let batch: BatchProgress?
        let observation: WorldObservation
        let tileItems: [TileItems]
        let messages: [CharacterMessage]
        let visionCallCount: Int
        let issue: String?
        let memoryEntries: [String: String]
        let recentHistory: [[HistoryEvent]]
    }

    private(set) var world = World()
    private(set) var messages: [CharacterMessage] = []
    private(set) var toolActivity: [ToolActivity] = []
    private(set) var visionCalls: [VisionCall] = []
    private(set) var notebook = ""
    private(set) var memoryEntries: [String: String] = [:]
    @ObservationIgnored private var recentHistory = RecentHistory()
    private(set) var isRunning = false
    private(set) var hasActiveIntent = false
    private(set) var isPlanning = false
    var canInterruptIntent: Bool { hasActiveIntent || isPlanning || pendingPlan != nil }
    @ObservationIgnored private(set) var worldTick: UInt64 = 0
    var issue: String? {
        didSet {
            guard issue != oldValue else { return }
            if let issue {
                debugExport?.event("game_error", ["message": issue])
            }
            exportState()
        }
    }

    private static let ticksPerSecond = 8
    private let tickInterval: Duration
    private let debugExport: DebugExport?
    @ObservationIgnored private var debugInputs: DebugInputs?
    @ObservationIgnored private var phase: RunPhase = .idle
    @ObservationIgnored private var batchProgress: BatchProgress?
    @ObservationIgnored private var activeIntent: ActiveIntent?
    @ObservationIgnored private var runID: UUID?
    @ObservationIgnored private(set) var task: Task<Void, Never>?
    @ObservationIgnored private var clockTask: Task<Void, Never>?
    @ObservationIgnored private var fastDecision: FastDecision?
    @ObservationIgnored private var planner: PlannerWork?
    private var pendingPlan: SavedPlan?
    @ObservationIgnored private var planFailure: String?
    @ObservationIgnored private var plannerWake: WakeReason?
    @ObservationIgnored private var controlWake: WakeReason?
    @ObservationIgnored private var plannerWaiter: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var consecutiveIntentFailures = 0

    init(tickInterval: Duration? = nil, debugExport: DebugExport? = nil) {
        self.tickInterval = max(.milliseconds(1), tickInterval ?? .seconds(1) / Self.ticksPerSecond)
        self.debugExport = debugExport
    }

    func updateDebugInputs(_ inputs: DebugInputs) {
        guard let debugExport else { return }
        var current = isRunning ? debugInputs ?? inputs : inputs
        current.instructions = inputs.instructions
        guard current != debugInputs else { return }
        debugInputs = current
        debugExport.event("inputs_changed", current)
        exportState()
    }

    func start(model: any CharacterModel, inputs: DebugInputs? = nil) {
        guard !isRunning else { return }
        if let inputs = inputs ?? debugInputs {
            if debugExport?.beginRun(model: inputs.model, effort: inputs.reasoningEffort) == true {
                debugInputs = nil
            }
            updateDebugInputs(inputs)
        }
        let id = UUID()
        runID = id
        isRunning = true
        phase = .awaitingModel
        issue = nil
        debugExport?.event("run_started", ["runID": id])
        exportState()
        startClock(for: id)
        task = Task { [weak self] in
            await self?.run(model: model, id: id)
        }
    }

    func stop() {
        endRun(reason: "stopped")
    }

    func interruptIntent() {
        guard canInterruptIntent else { return }
        steer(reason: .intentInterrupted, eventReason: "player_interrupted")
    }

    func playerInstructionsChanged() {
        steer(reason: .playerInput, eventReason: "player_input")
    }

    private func steer(reason: WakeReason, eventReason: String) {
        guard let runID else { return }
        controlWake = reason
        clearPlanning(run: runID, reason: eventReason)
        interruptActiveIntent(run: runID, reason: eventReason)
        cancelDecision()
        exportState()
    }

    func reset() {
        endRun(reason: "reset")
        world = World()
        worldTick = 0
        messages.removeAll()
        toolActivity.removeAll()
        visionCalls.removeAll()
        notebook = ""
        memoryEntries.removeAll()
        recentHistory = RecentHistory()
        issue = nil
        debugExport?.event("world_reset", [String: String]())
        exportState()
    }

    private func endRun(reason: String) {
        guard let runID else { return }
        let endingBatch = batchProgress
        clearPlanning(run: runID, reason: reason)
        interruptActiveIntent(run: runID, reason: reason)
        debugExport?.event("run_ended", RunEnd(runID: runID, reason: reason, batch: endingBatch))
        self.runID = nil
        isRunning = false
        task?.cancel()
        task = nil
        cancelDecision()
        clockTask?.cancel()
        clockTask = nil
        batchProgress = nil
        controlWake = nil
        consecutiveIntentFailures = 0
        phase = .idle
        exportState()
        debugExport?.closeRun()
    }

    private func startClock(for id: UUID) {
        let clock = ContinuousClock()
        let interval = tickInterval
        clockTask = Task { [weak self] in
            var deadline = clock.now.advanced(by: interval)
            while !Task.isCancelled {
                do {
                    try await clock.sleep(until: deadline, tolerance: .zero)
                } catch {
                    return
                }
                guard let self, self.runID == id, !Task.isCancelled else { return }
                self.advanceTick(run: id)
                deadline = deadline.advanced(by: interval)
                if deadline <= clock.now {
                    // Resume at the next clock time without playing missed steps in a burst.
                    deadline = clock.now.advanced(by: interval)
                }
            }
        }
    }

    private func run(model: any CharacterModel, id: UUID) async {
        var completion = "finished"
        var pendingVision: [VisionCall] = []
        defer {
            for vision in pendingVision { vision.update(.cancelled) }
            if runID == id { endRun(reason: completion) }
        }

        do {
            try checkRun(id)
            if model.visionEnabled {
                let frame = WorldMap(world: world).visionFrame()
                pendingVision.append(recordVision(frame: frame, status: frame == nil ? .renderFailed : .pending))
                exportState()
            }
            var previousReplies: [ToolReply]?
            var wake = WakeReason.start
            while true {
                try checkRun(id)
                wake = controlWake ?? plannerWake ?? wake
                controlWake = nil
                plannerWake = nil
                phase = .awaitingModel
                let context = ModelContext(
                    worldTick: worldTick, wakeReason: wake, planInProgress: isPlanning,
                    pendingPlan: pendingPlan?.summary, planFailure: planFailure,
                    planningSuggested: planningSuggested
                )
                let turn = previousReplies.map { ModelTurn.result($0, context: context) }
                    ?? .initial(world.observation(notebook: notebook), vision: pendingVision.first, context: context)
                debugExport?.event("model_woken", ModelWake(runID: id, tick: worldTick, reason: wake))
                exportState()
                let response = await nextDecision(turn, using: model)
                try checkRun(id)
                fastDecision = nil
                if controlWake != nil {
                    for vision in pendingVision { vision.update(.cancelled) }
                    pendingVision.removeAll()
                    previousReplies = previousReplies?.map { reply in
                        ToolReply(call: reply.call, receipt: reply.receipt)
                    }
                    continue
                }
                guard let response else { throw CancellationError() }
                let calls = try response.get()
                pendingVision.removeAll()

                var replies: [ToolReply] = []
                wake = .toolResults
                for call in calls {
                    try checkRun(id)
                    let activityIndex = toolActivity.count
                    toolActivity.append(ToolActivity(id: activityIndex + 1, function: call.function, tool: call.tool))
                    let reply: ToolReply
                    if wake == .intentInterrupted {
                        reply = skipInterruptedCall(call, run: id)
                        toolActivity[activityIndex].finish(reply.receipt)
                    } else if call.tool == .act {
                        reply = try await executeIntent(call, activityIndex: activityIndex, run: id)
                        try checkRun(id)
                        if reply.receipt.finished { return }
                        if controlWake != nil || reply.receipt.results.contains(.interrupted) {
                            wake = .intentInterrupted
                        } else if reply.receipt.results.contains(where: { !$0.success }) {
                            wake = .intentFailed
                        }
                    } else {
                        reply = handleTool(call, model: model, run: id)
                        toolActivity[activityIndex].finish(reply.receipt)
                        if let vision = reply.vision { pendingVision.append(vision) }
                        exportState()
                    }
                    replies.append(reply)
                }
                previousReplies = replies
                if controlWake == nil, wake == .toolResults,
                   replies.contains(where: { $0.receipt.results.contains(.waitingForPlan) }) {
                    await waitForPlanner()
                }
            }
        } catch {
            for vision in pendingVision { vision.update(Task.isCancelled ? .cancelled : .failed) }
            if runID == id, !Task.isCancelled {
                completion = "failed"
                issue = error.localizedDescription
            }
        }
    }

    private var planningSuggested: Bool? {
        consecutiveIntentFailures >= 3 ? true : nil
    }

    private func nextDecision(_ turn: ModelTurn, using model: any CharacterModel) async -> Result<[ToolCall], any Error>? {
        let (stream, replies) = AsyncStream<Result<[ToolCall], any Error>>.makeStream()
        let task = Task {
            do {
                replies.yield(.success(try await Self.chooseTools(turn, using: model)))
            } catch {
                replies.yield(.failure(error))
            }
            replies.finish()
        }
        fastDecision = FastDecision(task: task, replies: replies)
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()
    }

    private func cancelDecision() {
        fastDecision?.task.cancel()
        fastDecision?.replies.finish()
        fastDecision = nil
    }

    private func waitForPlanner() async {
        await withCheckedContinuation { continuation in
            guard isPlanning, controlWake == nil, !Task.isCancelled else {
                continuation.resume()
                return
            }
            plannerWaiter = continuation
            phase = .waitingForPlan
            exportState()
        }
    }

    private func signalPlanner() {
        let waiter = plannerWaiter
        plannerWaiter = nil
        waiter?.resume()
    }

    private nonisolated static func chooseTools(
        _ turn: ModelTurn, using model: any CharacterModel
    ) async throws -> [ToolCall] {
        try Task.checkCancellation()
        let calls = try await model.chooseTools(turn)
        guard !calls.isEmpty else { throw ModelAPIError.noToolCall(nil) }
        return calls
    }

    private func skipInterruptedCall(_ call: ToolCall, run id: UUID) -> ToolReply {
        let actionCount = call.tool == .act ? (try? call.decodeBatch().actions.count) ?? 0 : 0
        let receipt = ToolReceipt(
            results: [.interrupted], skipped: actionCount, observation: world.observation(notebook: notebook),
            memory: MemoryReceipt(entries: memoryEntries, update: nil),
            recentHistory: recentHistory.batches.isEmpty ? nil : recentHistory.batches
        )
        recordTool(call, receipt: receipt, run: id)
        return ToolReply(call: call, receipt: receipt)
    }

    private func applyMemory(_ call: ToolCall) -> MemoryReceipt.Update {
        guard let patch = try? call.decode(MemoryPatch.self) else { return .invalid }
        let removed = Set(patch.remove)
        let updated = Set(patch.set.keys)
        guard removed.isDisjoint(with: updated),
              removed.union(updated).allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return .invalid
        }

        var entries = memoryEntries
        for key in removed { entries.removeValue(forKey: key) }
        for (key, value) in patch.set { entries[key] = value }
        let size = entries.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
        let text = patch.text ?? notebook
        guard size <= MemoryReceipt.byteLimit, text.utf8.count <= MemoryReceipt.notebookByteLimit else { return .tooLarge }
        guard entries != memoryEntries || text != notebook else { return .unchanged }
        memoryEntries = entries
        notebook = text
        return .applied
    }

    private func handleTool(_ call: ToolCall, model: any CharacterModel, run id: UUID) -> ToolReply {
        let history = recentHistory.batches.isEmpty ? nil : recentHistory.batches
        var results: [ActionOutcome] = []
        var update: MemoryReceipt.Update?
        var vision: VisionCall?
        var requestedPlanID: UUID?
        switch call.tool {
        case .memory:
            let status = applyMemory(call)
            update = status
            switch status {
            case .applied: results = [.memoryUpdated]
            case .unchanged: results = [.inspected]
            case .invalid, .tooLarge: results = [.invalidArguments]
            }
        case .vision:
            let frame: VisionFrame?
            let status: VisionCall.Status
            if (try? call.decode([String: Bool].self).isEmpty) != true {
                frame = nil
                status = .invalid
                results = [.invalidArguments]
            } else if !model.visionEnabled {
                frame = nil
                status = .disabled
                results = [.visionUnavailable]
            } else {
                frame = WorldMap(world: world).visionFrame()
                status = frame == nil ? .renderFailed : .pending
                results = frame == nil ? [.visionUnavailable] : [.inspected]
            }
            vision = recordVision(frame: frame, status: status, call: call)
        case .requestPlan:
            if let request = try? call.decode(PlanRequest.self) {
                requestedPlanID = startPlanner(request, call: call, using: model, run: id)
                results = [.planRequested]
            } else {
                results = [.invalidArguments]
            }
        case .act, nil:
            results = [.unknownTool]
        }
        let receipt = ToolReceipt(
            results: results, skipped: 0, observation: world.observation(notebook: notebook),
            memory: MemoryReceipt(entries: memoryEntries, update: update),
            recentHistory: history, requestedPlanID: requestedPlanID
        )
        recordTool(call, receipt: receipt, run: id)
        return ToolReply(call: call, receipt: receipt, vision: vision)
    }

    private func startPlanner(_ request: PlanRequest, call: ToolCall, using model: any CharacterModel,
                              run id: UUID) -> UUID {
        clearPlanning(run: id, reason: "superseded")
        consecutiveIntentFailures = 0
        let planID = UUID()
        let snapshot = world
        let observation = snapshot.observation(notebook: notebook)
        let vision: VisionCall?
        if request.includeVision == true, model.visionEnabled {
            let frame = WorldMap(world: snapshot).visionFrame()
            vision = recordVision(frame: frame, status: frame == nil ? .renderFailed : .pending, call: call)
        } else {
            vision = nil
        }
        debugExport?.planner(.started, runID: id, planID: planID, tick: worldTick, sourceCall: call)
        let task = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let proposal = try await model.plan(brief: request.brief, observation: observation,
                                                    vision: vision, planID: planID)
                try Task.checkCancellation()
                self?.completePlanner(.success(proposal), planID: planID, run: id)
            } catch {
                if !Task.isCancelled {
                    vision?.update(.failed)
                    self?.completePlanner(.failure(error), planID: planID, run: id)
                }
            }
        }
        planner = PlannerWork(id: planID, task: task, vision: vision)
        isPlanning = true
        return planID
    }

    private func completePlanner(_ result: Result<PlanProposal, any Error>, planID: UUID, run id: UUID) {
        guard runID == id, planner?.id == planID else { return }
        planner = nil
        isPlanning = false
        switch result {
        case .success(let proposal):
            if let failure = BlueprintPlanner.layoutFailure(proposal.placements, in: world) {
                let position = failure.position.map { " [\($0[0]),\($0[1])]" } ?? ""
                failPlanner(failure.reason + position, planID: planID, run: id)
            } else if let bounds = BlueprintPlacement.bounds(of: proposal.placements) {
                let summary = PlanSummary(planID: planID, createdTick: worldTick, summary: proposal.summary,
                                          placementCount: proposal.placements.count, bounds: bounds)
                pendingPlan = SavedPlan(summary: summary, placements: proposal.placements)
                plannerWake = .planReady
                debugExport?.planner(.completed, runID: id, planID: planID, tick: worldTick,
                                     outcome: "ready", placementCount: summary.placementCount)
            }
        case .failure(let error):
            failPlanner(error.localizedDescription, planID: planID, run: id)
        }
        signalPlanner()
        exportState()
    }

    private func failPlanner(_ reason: String, planID: UUID, run id: UUID) {
        planFailure = reason
        plannerWake = .planFailed
        debugExport?.planner(.completed, runID: id, planID: planID, tick: worldTick,
                             outcome: "failed", reason: reason)
    }

    private func clearPlanning(run id: UUID, reason: String) {
        if let planner {
            planner.task.cancel()
            planner.vision?.update(.cancelled)
            debugExport?.planner(.cancelled, runID: id, planID: planner.id, tick: worldTick, reason: reason)
        }
        planner = nil
        isPlanning = false
        pendingPlan = nil
        planFailure = nil
        plannerWake = nil
        signalPlanner()
    }

    private func recordTool(_ call: ToolCall, receipt: ToolReceipt, run id: UUID) {
        debugExport?.event("tool_processed", ToolEvent(runID: id, call: call,
                            exchangeID: call.debugExchangeID, receipt: receipt))
    }

    private func recordVision(frame: VisionFrame?, status: VisionCall.Status, call: ToolCall? = nil) -> VisionCall {
        let record = VisionCall(number: visionCalls.count + 1, avatar: world.avatar, frame: frame,
                                status: status, openingScan: call == nil)
        visionCalls.append(record)
        debugExport?.event("vision_called", record.trace(for: call))
        return record
    }

    private func executeIntent(_ call: ToolCall, activityIndex: Int, run id: UUID) async throws -> ToolReply {
        try await withCheckedThrowingContinuation { continuation in
            guard runID == id, !Task.isCancelled else {
                continuation.resume(throwing: CancellationError())
                return
            }
            let intent = ActiveIntent(call: call, activityIndex: activityIndex, continuation: continuation)
            activeIntent = intent
            hasActiveIntent = true
            phase = .executingIntent
            let progress = BatchProgress(toolCallID: call.id, exchangeID: call.debugExchangeID,
                                         attempted: intent.execution.actionCount)
            batchProgress = progress
            debugExport?.event("intent_started", IntentEvent(runID: id, tick: worldTick, batch: progress, call: call))
            exportState()
        }
    }

    private func advanceTick(run id: UUID) {
        worldTick += 1
        guard let intent = activeIntent, intent.planning == nil else {
            if worldTick.isMultiple(of: UInt64(Self.ticksPerSecond)) { exportState() }
            return
        }

        if let planID = intent.execution.requestedPlanID, let pendingPlan, pendingPlan.summary.planID == planID {
            intent.execution.useProposal(pendingPlan.placements)
            intent.applyingPlan = pendingPlan.summary
            self.pendingPlan = nil
            plannerWake = nil
        }
        if let preparation = intent.execution.preparation(in: world) {
            if preparation.isExpensive {
                let intentID = intent.id
                intent.planning = Task.detached(priority: .userInitiated) { [weak self] in
                    guard !Task.isCancelled else { return }
                    let prepared = preparation.prepare()
                    guard !Task.isCancelled else { return }
                    await self?.acceptPreparation(prepared, for: intentID)
                }
                return
            }
            intent.execution.accept(preparation.prepare())
        }

        var liveWorld = world
        let canWait = isPlanning || plannerWake != nil
        guard let update = intent.execution.advance(world: &liveWorld, canWaitForPlan: canWait) else { return }
        if world != liveWorld { world = liveWorld }
        recordProgress(update, for: intent, run: id)
        if intent.execution.isComplete {
            finishIntent(intent, run: id, reason: update.outcome?.success == true ? "completed" : "failed")
        } else {
            exportState()
        }
    }

    private func acceptPreparation(_ preparation: IntentExecution.PreparedAction, for intentID: UUID) {
        guard let intent = activeIntent, intent.id == intentID else { return }
        intent.execution.accept(preparation)
        intent.planning = nil
    }

    private func interruptActiveIntent(run id: UUID, reason: String) {
        guard let intent = activeIntent, let update = intent.execution.interrupt(in: world) else { return }
        recordProgress(update, for: intent, run: id)
        finishIntent(intent, run: id, reason: reason)
    }

    private func recordProgress(_ update: IntentExecution.Update, for intent: ActiveIntent, run id: UUID) {
        switch update.step {
        case .walk(let step):
            debugExport?.event("walk_step", WalkStepEvent(runID: id, toolCallID: intent.call.id, index: update.index,
                               step: step, avatar: [world.avatar.x, world.avatar.y], tick: worldTick))
        case .plan(let step, let action):
            debugExport?.event("plan_step", PlanStepEvent(runID: id, toolCallID: intent.call.id, index: update.index,
                               step: step, action: action, tick: worldTick))
        case .message(let text):
            messages.append(CharacterMessage(sender: "Character", text: text))
        case .world, nil:
            break
        }
        if var history = update.history {
            if let plan = intent.applyingPlan, update.outcome == .built {
                history.planSummary = plan.summary
                intent.appliedPlan = plan
            }
            intent.history.append(history)
        }
        if let outcome = update.outcome {
            intent.applyingPlan = nil
            batchProgress?.processed = intent.execution.results.count
            debugExport?.event("action_processed", ActionEvent(runID: id, toolCallID: intent.call.id, index: update.index,
                               result: outcome, tick: worldTick))
        }
    }

    private func finishIntent(_ intent: ActiveIntent, run id: UUID, reason: String) {
        intent.planning?.cancel()
        var receipt = intent.execution.receipt(
            observation: world.observation(notebook: notebook),
            memory: MemoryReceipt(entries: memoryEntries, update: nil),
            recentHistory: recentHistory.batches.isEmpty ? nil : recentHistory.batches
        )
        receipt.appliedPlan = intent.appliedPlan
        if !receipt.results.contains(.interrupted) {
            if receipt.results.contains(where: { !$0.success }) {
                consecutiveIntentFailures = min(3, consecutiveIntentFailures + 1)
            } else if !receipt.results.contains(.waitingForPlan) {
                consecutiveIntentFailures = 0
            }
        }
        receipt.planningSuggested = planningSuggested
        recentHistory.append(intent.history)
        toolActivity[intent.activityIndex].finish(receipt)
        if var progress = batchProgress {
            progress.skipped = receipt.skipped
            debugExport?.event("intent_ended", IntentEvent(runID: id, tick: worldTick, batch: progress, reason: reason))
        }
        recordTool(intent.call, receipt: receipt, run: id)
        activeIntent = nil
        hasActiveIntent = false
        batchProgress = nil
        phase = .awaitingModel
        exportState()
        intent.continuation.resume(returning: ToolReply(call: intent.call, receipt: receipt))
    }

    private func exportState() {
        guard let debugExport else { return }
        let observation = world.observation(notebook: notebook)
        var tileItems: [DebugSnapshot.TileItems] = []
        for (y, row) in observation.view.enumerated() {
            for (x, tile) in row.enumerated() where !tile.items.isEmpty || !tile.resources.isEmpty {
                tileItems.append(.init(position: [x, y], loose: tile.items.namedCounts,
                                       attached: tile.resources.namedCounts))
            }
        }
        debugExport.snapshot(DebugSnapshot(runID: runID, phase: phase, isRunning: isRunning,
                            worldTick: worldTick, planInProgress: isPlanning, pendingPlan: pendingPlan?.summary,
                            planFailure: planFailure, inputs: debugInputs, batch: batchProgress, observation: observation,
                            tileItems: tileItems, messages: messages, visionCallCount: visionCalls.count, issue: issue,
                            memoryEntries: memoryEntries, recentHistory: recentHistory.batches))
    }

    private func checkRun(_ id: UUID) throws {
        guard runID == id, !Task.isCancelled else { throw CancellationError() }
    }
}
