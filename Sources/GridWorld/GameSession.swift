import Foundation
import Observation

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

    mutating func finish(_ receipt: ToolReceipt) {
        if let failure = receipt.results.first(where: { !$0.success }) {
            summary = failure.rawValue.replacingOccurrences(of: "_", with: " ").capitalized
            needsAttention = true
        } else {
            switch tool {
            case .act: summary = receipt.results.count == 1 ? "1 action" : "\(receipt.results.count) actions"
            case .query: summary = receipt.results.count == 1 ? "1 query" : "\(receipt.results.count) queries"
            case .vision: summary = "Frame captured"
            case .memory: summary = receipt.memory?.update == .applied ? "Memory updated" : "Unchanged"
            case nil: summary = "Unknown tool"
            }
        }
        if receipt.skipped > 0 { summary += " · \(receipt.skipped) skipped" }
    }
}

@MainActor
@Observable
final class GameSession {
    private enum PlaybackStep {
        case world(World)
        case walk(World)
        case message(String)
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
        case playingBatch = "playing_batch"
    }

    private struct BatchProgress: Encodable {
        let toolCallID: String
        let exchangeID: UUID?
        let attempted: Int
        let skipped: Int
        var processed = 0
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
    }

    private struct WalkStepEvent: Encodable {
        let runID: UUID
        let toolCallID: String
        let index: Int
        let step: Int
        let avatar: [Int]
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

        let schemaVersion = 3
        let timestamp = Date()
        let processID = ProcessInfo.processInfo.processIdentifier
        let runID: UUID?
        let phase: RunPhase
        let isRunning: Bool
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
    @ObservationIgnored private var activeHistory: [HistoryEvent] = []
    private(set) var isRunning = false
    var issue: String? {
        didSet {
            guard issue != oldValue else { return }
            if let issue {
                debugExport?.event("game_error", ["message": issue])
            }
            exportState()
        }
    }

    private let actionDelay: Duration?
    private let debugExport: DebugExport?
    @ObservationIgnored private var debugInputs: DebugInputs?
    @ObservationIgnored private var phase: RunPhase = .idle
    @ObservationIgnored private var batchProgress: BatchProgress?
    @ObservationIgnored private var runID: UUID?
    @ObservationIgnored private(set) var task: Task<Void, Never>?

    init(actionDelay: Duration? = nil, debugExport: DebugExport? = nil) {
        self.actionDelay = actionDelay
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
        task = Task { [weak self] in
            await self?.run(model: model, id: id)
        }
    }

    func stop() {
        endRun(reason: "stopped")
    }

    func reset() {
        endRun(reason: "reset")
        world = World()
        messages.removeAll()
        toolActivity.removeAll()
        visionCalls.removeAll()
        notebook = ""
        memoryEntries.removeAll()
        recentHistory = RecentHistory()
        activeHistory.removeAll()
        issue = nil
        debugExport?.event("world_reset", [String: String]())
        exportState()
    }

    private func endRun(reason: String) {
        guard let runID else { return }
        debugExport?.event("run_ended", RunEnd(runID: runID, reason: reason, batch: batchProgress))
        if let last = toolActivity.indices.last, toolActivity[last].summary == "Running" {
            toolActivity[last].summary = "Interrupted"
            toolActivity[last].needsAttention = true
        }
        commitHistory()
        self.runID = nil
        isRunning = false
        task?.cancel()
        task = nil
        batchProgress = nil
        phase = .idle
        exportState()
        debugExport?.closeRun()
    }

    private func run(model: any CharacterModel, id: UUID) async {
        var completion = "finished"
        var pendingVision: [VisionCall] = []
        defer {
            for vision in pendingVision { vision.update(.cancelled) }
            if runID == id {
                endRun(reason: completion)
            }
        }

        let clock = ContinuousClock()
        var nextActionAt = clock.now
        do {
            try checkRun(id)
            if model.visionEnabled {
                let frame = WorldMap(world: world).visionFrame()
                pendingVision.append(recordVision(frame: frame, status: frame == nil ? .renderFailed : .pending))
                exportState()
            }
            let firstTurn = ModelTurn.initial(world.observation(notebook: notebook), vision: pendingVision.first)
            var decision = try await Self.chooseTools(firstTurn, using: model)
            pendingVision.removeAll()
            turns: while runID == id, !Task.isCancelled {
                var replies: [ToolReply] = []
                let actionCount = decision.calls.count { $0.tool == .act }
                for (index, call) in decision.calls.enumerated() {
                    try checkRun(id)
                    let activityIndex = toolActivity.count
                    toolActivity.append(ToolActivity(id: activityIndex + 1, function: call.function, tool: call.tool))
                    if call.tool != .act {
                        phase = .awaitingModel
                        batchProgress = nil
                        let reply = handleTool(call, visionEnabled: model.visionEnabled, run: id)
                        toolActivity[activityIndex].finish(reply.receipt)
                        replies.append(reply)
                        if let vision = reply.vision { pendingVision.append(vision) }
                        exportState()
                        continue
                    }

                    let (steps, receipt, historyEvents) = prepareBatch(call)
                    let reply = ToolReply(call: call, receipt: receipt)
                    replies.append(reply)
                    phase = .playingBatch
                    batchProgress = BatchProgress(toolCallID: call.id, exchangeID: call.debugExchangeID,
                                                  attempted: receipt.results.count, skipped: receipt.skipped)
                    debugExport?.event("batch_projected", ToolEvent(runID: id, call: call,
                                       exchangeID: call.debugExchangeID, receipt: receipt))
                    exportState()
                    let stepCount = steps.reduce(0) { $0 + $1.count }
                    let timePerStep = decision.elapsed / actionCount / max(1, stepCount)
                    let interval = actionDelay ?? min(.milliseconds(400), max(.milliseconds(180), timePerStep))

                    if index == decision.calls.count - 1, !receipt.finished {
                        // Only the last batch can overlap with planning. Later calls in this turn
                        // need the actual world and history produced by playback.
                        let nextTurn = ModelTurn.result(replies)
                        async let next = Self.chooseTools(nextTurn, using: model)
                        try await play(steps, reply: reply, historyEvents: historyEvents,
                                       every: interval, nextActionAt: &nextActionAt, run: id)
                        try checkRun(id)
                        toolActivity[activityIndex].finish(receipt)
                        phase = .awaitingModel
                        exportState()
                        decision = try await next
                        pendingVision.removeAll()
                        continue turns
                    }

                    try await play(steps, reply: reply, historyEvents: historyEvents,
                                   every: interval, nextActionAt: &nextActionAt, run: id)
                    try checkRun(id)
                    toolActivity[activityIndex].finish(receipt)
                    if receipt.finished { return }
                }
                decision = try await Self.chooseTools(.result(replies), using: model)
                pendingVision.removeAll()
            }
        } catch {
            for vision in pendingVision { vision.update(Task.isCancelled ? .cancelled : .failed) }
            if runID == id, !Task.isCancelled {
                completion = "failed"
                issue = error.localizedDescription
            }
        }
    }

    private nonisolated static func chooseTools(
        _ turn: ModelTurn, using model: any CharacterModel
    ) async throws -> (calls: [ToolCall], elapsed: Duration) {
        try Task.checkCancellation()
        let clock = ContinuousClock()
        let start = clock.now
        let calls = try await model.chooseTools(turn)
        guard !calls.isEmpty else { throw ModelAPIError.noToolCall(nil) }
        return (calls, start.duration(to: clock.now))
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

    private func handleTool(_ call: ToolCall, visionEnabled: Bool, run id: UUID) -> ToolReply {
        let history = recentHistory.batches.isEmpty ? nil : recentHistory.batches
        var results: [ActionOutcome] = []
        var skipped = 0
        var queries: [ToolReceipt.Query] = []
        var update: MemoryReceipt.Update?
        var vision: VisionCall?
        switch call.tool {
        case .memory:
            let status = applyMemory(call)
            update = status
            switch status {
            case .applied: results = [.memoryUpdated]
            case .unchanged: results = [.inspected]
            case .invalid, .tooLarge: results = [.invalidArguments]
            }
        case .query:
            if let batch = try? call.decode(QueryBatch.self), !batch.queries.isEmpty {
                var events: [HistoryEvent] = []
                for (index, query) in batch.queries.enumerated() {
                    let result = query.result(in: world, at: index)
                    events.append(HistoryEvent(query: query, result: result, from: world.avatar))
                    guard let result else {
                        results.append(.invalidArguments)
                        break
                    }
                    queries.append(result)
                    results.append(.inspected)
                }
                skipped = batch.queries.count - results.count
                recentHistory.append(events)
            } else {
                results = [.invalidArguments]
            }
        case .vision:
            let frame: VisionFrame?
            let status: VisionCall.Status
            if (try? call.decode([String: Bool].self).isEmpty) != true {
                frame = nil
                status = .invalid
                results = [.invalidArguments]
            } else if !visionEnabled {
                frame = nil
                status = .disabled
                results = [.visionUnavailable]
            } else {
                frame = WorldMap(world: world).visionFrame()
                status = frame == nil ? .renderFailed : .pending
                results = frame == nil ? [.visionUnavailable] : [.inspected]
            }
            vision = recordVision(frame: frame, status: status, call: call)
        case .act, nil:
            results = [.unknownTool]
        }
        let receipt = ToolReceipt(
            results: results, skipped: skipped, observation: world.observation(notebook: notebook),
            queries: queries.isEmpty ? nil : queries, memory: MemoryReceipt(entries: memoryEntries, update: update),
            recentHistory: history
        )
        debugExport?.event("tool_processed", ToolEvent(runID: id, call: call,
                            exchangeID: call.debugExchangeID, receipt: receipt))
        return ToolReply(call: call, receipt: receipt, vision: vision)
    }

    private func recordVision(frame: VisionFrame?, status: VisionCall.Status, call: ToolCall? = nil) -> VisionCall {
        let record = VisionCall(number: visionCalls.count + 1, avatar: world.avatar, frame: frame,
                                status: status, openingScan: call == nil)
        visionCalls.append(record)
        debugExport?.event("vision_called", record.trace(for: call))
        return record
    }

    private func prepareBatch(_ call: ToolCall)
        -> (steps: [[PlaybackStep]], receipt: ToolReceipt, historyEvents: [HistoryEvent?]) {
        let history = recentHistory.batches.isEmpty ? nil : recentHistory.batches
        let memory = MemoryReceipt(entries: memoryEntries, update: nil)
        guard let batch = try? call.decodeBatch(), !batch.actions.isEmpty else {
            let receipt = ToolReceipt(results: [.invalidArguments], skipped: 0,
                                      observation: world.observation(notebook: notebook),
                                      memory: memory, recentHistory: history)
            return ([[]], receipt, [nil])
        }

        var projectedWorld = world
        var steps: [[PlaybackStep]] = []
        var results: [ActionOutcome] = []
        var walks: [ToolReceipt.Walk] = []
        var historyEvents: [HistoryEvent?] = []
        for (index, action) in batch.actions.enumerated() {
            let avatarBefore = projectedWorld.avatar
            var actionSteps: [PlaybackStep] = []
            let outcome: ActionOutcome
            switch action {
            case .world(let action):
                outcome = projectedWorld.apply(action)
                if outcome.success, outcome != .finished { actionSteps.append(.world(projectedWorld)) }
            case .walkTo(let destination):
                if let route = projectedWorld.shortestRoute(to: destination) {
                    // Movement leaves the map unchanged, so each staged step uses the same rules as the route.
                    for direction in route {
                        _ = projectedWorld.apply(.move(direction))
                        actionSteps.append(.walk(projectedWorld))
                    }
                    walks.append(.init(index: index, destination: [destination.x, destination.y], steps: route.count))
                    outcome = .arrived
                } else {
                    outcome = projectedWorld.tile(at: destination) == nil ? .boundary : .unreachable
                }
            case .collectAt(let position, let target, let count):
                let interaction = projectedWorld.interact(at: position) { .collect($0, target, count: count) }
                outcome = interaction.outcome
                actionSteps = interaction.walked.map(PlaybackStep.walk)
                if outcome.success { actionSteps.append(.world(projectedWorld)) }
            case .placeAt(let position, let structure, let stand):
                let interaction = projectedWorld.interact(at: position, standingAt: stand) { .place($0, structure) }
                outcome = interaction.outcome
                actionSteps = interaction.walked.map(PlaybackStep.walk)
                if outcome.success { actionSteps.append(.world(projectedWorld)) }
            case .say(let text):
                actionSteps.append(.message(text))
                outcome = .messageSent
            case .invalid:
                outcome = .invalidArguments
            }
            historyEvents.append(HistoryEvent(action: action, result: outcome, from: avatarBefore))
            steps.append(actionSteps)
            results.append(outcome)
            if !outcome.success || outcome == .finished { break }
        }
        let receipt = ToolReceipt(
            results: results, skipped: batch.actions.count - results.count,
            observation: projectedWorld.observation(notebook: notebook),
            walks: walks.isEmpty ? nil : walks,
            memory: memory, recentHistory: history
        )
        return (steps, receipt, historyEvents)
    }

    private func play(
        _ steps: [[PlaybackStep]], reply: ToolReply, historyEvents: [HistoryEvent?], every interval: Duration,
        nextActionAt: inout ContinuousClock.Instant, run id: UUID
    ) async throws {
        let clock = ContinuousClock()
        for (index, outcome) in reply.receipt.results.enumerated() {
            try checkRun(id)
            for (stepIndex, step) in steps[index].enumerated() {
                if clock.now < nextActionAt { try await clock.sleep(until: nextActionAt) }
                try checkRun(id)
                switch step {
                case .world(let world):
                    self.world = world
                case .walk(let world):
                    self.world = world
                    debugExport?.event("walk_step", WalkStepEvent(runID: id, toolCallID: reply.call.id,
                                       index: index, step: stepIndex + 1, avatar: [world.avatar.x, world.avatar.y]))
                    if stepIndex + 1 < steps[index].count { exportState() }
                case .message(let text):
                    messages.append(CharacterMessage(sender: "Character", text: text))
                }
                nextActionAt = clock.now.advanced(by: interval)
            }
            if let event = historyEvents[index] { activeHistory.append(event) }
            batchProgress?.processed = index + 1
            debugExport?.event("action_processed", ActionEvent(runID: id, toolCallID: reply.call.id,
                                                              index: index, result: outcome))
            exportState()
        }
        commitHistory()
    }

    private func commitHistory() {
        recentHistory.append(activeHistory)
        activeHistory.removeAll()
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
                            inputs: debugInputs, batch: batchProgress, observation: observation,
                            tileItems: tileItems, messages: messages, visionCallCount: visionCalls.count, issue: issue,
                            memoryEntries: memoryEntries, recentHistory: recentHistory.batches))
    }

    private func checkRun(_ id: UUID) throws {
        guard runID == id, !Task.isCancelled else { throw CancellationError() }
    }
}
