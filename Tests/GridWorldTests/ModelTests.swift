import Foundation
import Observation
import Testing
@testable import GridWorld

private let zhipuTestEndpoint = "https://open.bigmodel.cn/api/paas/v4/chat/completions"

@Test func savedConfigurationsRememberModelsAndImportTheExistingSettings() throws {
    let suite = "GridWorldTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    #expect(ModelSettings.savedConfigurations(in: defaults).isEmpty)
    defaults.set("http://localhost:8080/v1", forKey: "ModelAPIAddress")
    defaults.set("local-model", forKey: "ModelAPIModel")
    defaults.set("none", forKey: "ModelThinkingEffort")
    defaults.set(false, forKey: "ModelStreaming")
    let legacy = try #require(ModelSettings.savedConfigurations(in: defaults).first)
    #expect(legacy.model == "local-model")
    #expect(legacy.effort == .none)
    #expect(legacy.streaming == false)
    #expect(!legacy.allowsVision)

    let glmPreset = try #require(ModelSettings.presets.first { $0.model == "glm-5.3-flash" })
    let glm = try glmPreset.resolve()
    #expect(glm.configuration.allowsVision)
    #expect(glm.endpoint.absoluteString == zhipuTestEndpoint)
    try glm.save(newKey: "", in: defaults)
    let flashX = try ModelSettings(address: glm.configuration.address, model: "glm-5.3-flashx")
    try flashX.save(newKey: "", in: defaults)

    let updated = try ModelSettings(address: zhipuTestEndpoint, model: glm.model, effort: .high,
                                    streaming: false, visionEnabled: false)
    try updated.save(newKey: "", in: defaults)
    let reopened = try #require(UserDefaults(suiteName: suite))
    let saved = ModelSettings.savedConfigurations(in: reopened)
    #expect(saved == [updated.configuration, flashX.configuration, legacy])
    #expect(saved.first?.allowsVision == false)
    #expect(throws: (any Error).self) { try glm.save(newKey: "invalid key", in: reopened) }
    #expect(ModelSettings.savedConfigurations(in: reopened) == saved)

    try legacy.resolve().save(newKey: "", in: reopened)
    #expect(ModelSettings.savedConfigurations(in: defaults) == [legacy, updated.configuration, flashX.configuration])
}

@Test func resolvesStandardBaseURLAndPreservesFullEndpoints() throws {
    for address in ["https://api.openai.com", "https://api.openai.com/v1/", "https://api.openai.com/v1/chat/completions"] {
        let settings = try ModelSettings(address: address, model: "test")
        #expect(settings.endpoint.absoluteString == "https://api.openai.com/v1/chat/completions")
    }
    let proxy = try ModelSettings(address: "https://model.example/tenant/v1", model: "test")
    #expect(proxy.endpoint.absoluteString == "https://model.example/tenant/v1/chat/completions")
    let custom = try ModelSettings(address: "https://model.example/custom", model: "test")
    #expect(custom.endpoint.absoluteString == "https://model.example/custom")
    let glm = try ModelSettings(address: "https://open.bigmodel.cn/api/paas/v4/", model: "glm-5.3-flash", effort: .none)
    #expect(glm.endpoint.absoluteString == zhipuTestEndpoint)
    #expect(glm.effort == .low)
    let proxyGLM = try ModelSettings(address: "https://model.example/api/paas/v4", model: glm.model, effort: .none)
    #expect(proxyGLM.endpoint.absoluteString == "https://model.example/api/paas/v4")
    #expect(proxyGLM.effort == .none)
}

@MainActor
@Test(.timeLimit(.minutes(1)), arguments: [true, false])
func glmFlashContinuesAfterToolReceipt(streaming: Bool) async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubChatEndpoint.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let settings = try ModelSettings(address: "https://open.bigmodel.cn/api/paas/v4", model: "glm-5.3-flash",
                                     effort: .none, streaming: streaming)
    let debugger = APIDebugger()
    let game = GameSession(actionDelay: .zero)
    game.start(model: ChatCompletionsModel(
        endpoint: settings.endpoint, model: settings.model, apiKey: "test-only", taskGoal: "Note the doorway",
        reasoningEffort: settings.effort.requestValue, streaming: settings.streaming, session: session, debugger: debugger
    ))
    await (try #require(game.task)).value

    #expect(game.issue == nil)
    #expect(game.notebook == "The doorway faces east")
    #expect(game.messages.map(\.text) == ["Noted"])
    try #require(debugger.exchanges.count == 2)
    let requests = try debugger.exchanges.map { exchange in
        try #require(JSONSerialization.jsonObject(with: Data(exchange.requestBody.utf8)) as? [String: Any])
    }
    for request in requests {
        #expect(request["reasoning_effort"] as? String == "low")
        #expect(request["stream"] as? Bool == (streaming ? true : nil))
        #expect(request["tool_stream"] as? Bool == (streaming ? true : nil))
        #expect(request["parallel_tool_calls"] == nil)
        #expect(request["store"] == nil)
        #expect(request["thinking"] == nil)
    }
    let messages = try #require(requests[1]["messages"] as? [[String: Any]])
    #expect(messages.compactMap { $0["role"] as? String } == ["system", "user", "assistant", "tool"])
    try #require(messages.count == 4)
    #expect(messages[2]["reasoning_content"] as? String == "Note the doorway")
    #expect(messages[3]["tool_call_id"] as? String == "glm-note")
    let receipt = try decode(WireReceipt.self, messages[3]["content"] as? String)
    #expect(receipt.observation.notebook == "The doorway faces east")
}

@MainActor
@Test func debugExportStartsByDefaultAndKeepsRecentSessions() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let manager = FileManager.default
    defer { try? manager.removeItem(at: root) }
    let automatic = root.appendingPathComponent("automatic")
    try manager.createDirectory(at: automatic, withIntermediateDirectories: true)

    let currentPID = ProcessInfo.processInfo.processIdentifier
    let active = automatic.appendingPathComponent("session-\(currentPID)-\(UUID())")
    _ = try DebugExport(directory: active)
    let inactivePID = Int32.max
    for _ in 0..<5 {
        let old = automatic.appendingPathComponent("session-\(inactivePID)-\(UUID())")
        _ = try DebugExport(directory: old)
    }

    #expect(try DebugExport.launch(arguments: ["GridWorld", "--no-debug-export"], automaticRoot: automatic) == nil)
    let launched = try DebugExport.launch(arguments: ["GridWorld"], automaticRoot: automatic)
    let export = try #require(launched)
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    export.beginRun(model: "provider/glm-5.3-flash", effort: "max", at: start)
    export.snapshot(["state": "ready"])
    let debugger = APIDebugger(debugExport: export)
    let exchange = APIExchange(method: "POST", address: "https://model.example", requestHeaders: "", requestBody: "{}")
    try debugger.record(exchange)
    export.closeRun()
    export.beginRun(model: "provider/glm-5.3-flash", effort: "max", at: start)
    export.snapshot(["state": "new"])
    debugger.finish(exchange.id, with: .cancelled)
    let sessions = try manager.contentsOfDirectory(atPath: automatic.path)
    #expect(sessions.filter { $0.hasPrefix("session-\(inactivePID)-") }.count == 3)
    #expect(sessions.contains(active.lastPathComponent))
    let namedRuns = sessions.filter { $0.hasPrefix("provider-glm-5.3-flash_max_") }
    try #require(namedRuns.count == 2)
    for name in namedRuns {
        #expect(name.hasSuffix("_p\(currentPID)"))
        let run = automatic.appendingPathComponent(name)
        let state = try Data(contentsOf: run.appendingPathComponent("state.json"))
        let record = try JSONDecoder().decode([String: String].self, from: state)
        let journal = try String(contentsOf: run.appendingPathComponent("events.jsonl"), encoding: .utf8)
        #expect(journal.contains(exchange.id.uuidString) == (record["state"] == "ready"))
        #expect(journal.contains("api_update") == (record["state"] == "ready"))
    }

    let override = root.appendingPathComponent("explicit")
    let custom = try DebugExport.launch(arguments: ["GridWorld", "--debug-dir", override.path],
                                        automaticRoot: automatic)
    #expect(custom != nil)
    #expect(manager.fileExists(atPath: override.appendingPathComponent("events.jsonl").path))
}

@MainActor
@Test func rotatingDebugJournalKeepsPreviousSegmentAndEventOrder() throws {
    let trace = DebugTraceFiles()
    let export = try DebugExport(directory: trace.directory, segmentLimit: 200)
    defer { try? FileManager.default.removeItem(at: trace.directory) }
    for index in 1...3 {
        export.event("test", ["padding": String(repeating: String(index), count: 120)])
    }
    #expect(try trace.events().map(\.sequence) == [3])
    let previous = trace.directory.appendingPathComponent("events.previous.jsonl")
    let record = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: previous)) as? [String: Any])
    #expect(record["sequence"] as? Int == 2)
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func stoppedRunCannotApplyLateReplyOrStopNewRun() async throws {
    let game = GameSession()
    let world = game.world
    let oldModel = SuspendedModel()
    let newModel = SuspendedModel()

    game.start(model: oldModel)
    let oldTask = try #require(game.task)
    await oldModel.waitUntilRequested()
    game.stop()
    #expect(!game.isRunning)
    #expect(oldTask.isCancelled)

    game.start(model: newModel)
    let newTask = try #require(game.task)
    await newModel.waitUntilRequested()
    await oldModel.respond(with: batchCall("late", #"[{"action":"say","text":"late"},{"action":"move","direction":"east"}]"#))
    await oldTask.value
    #expect(game.world == world)
    #expect(game.messages.isEmpty)
    #expect(game.isRunning)
    #expect(game.issue == nil)

    await newModel.respond(with: batchCall("current", #"[{"action":"finish"}]"#))
    await newTask.value
    #expect(!game.isRunning)
    #expect(game.world == world)
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func resetClearsTheWorldAndHistoryWhileCancelingTheRun() async throws {
    let trace = DebugTraceFiles()
    let export = try DebugExport(directory: trace.directory)
    defer { try? FileManager.default.removeItem(at: trace.directory) }
    let game = GameSession(actionDelay: .zero, debugExport: export)
    let model = ScriptedTools([
        toolCall("note", .memory, #"{"text":"Keep the east door","set":{"door":"east"}}"#),
        batchCall("build", """
        [{"action":"collect","direction":"north","target":"above"},
         {"action":"collect","direction":"north","target":"item","item":"log"},
         {"action":"craft","item":"plank"},{"action":"place","direction":"east","structure":"floor"},
         {"action":"move","direction":"east"},{"action":"say","text":"Built a floor."},{"action":"finish"}]
        """),
    ])
    game.start(model: model)
    await (try #require(game.task)).value
    #expect(game.world.avatar == Position(x: 9, y: 5))
    #expect(game.world.inventory == [.plank: 3])
    #expect(game.notebook == "Keep the east door")
    #expect(game.messages.count == 1)

    let pending = SuspendedModel()
    game.start(model: pending)
    let task = try #require(game.task)
    await pending.waitUntilRequested()
    game.reset()
    await pending.respond(with: batchCall("late", #"[{"action":"move","direction":"east"}]"#))
    await task.value

    #expect(task.isCancelled)
    #expect(!game.isRunning)
    #expect(game.world.avatar == Position(x: 8, y: 5))
    #expect(game.world.tile(at: Position(x: 9, y: 5))?.hasFloor == false)
    #expect(game.world.tile(at: Position(x: 8, y: 4))?.terrain == .tree)
    #expect(game.world.inventory.isEmpty)
    #expect(game.notebook.isEmpty)
    #expect(game.memoryEntries.isEmpty)
    #expect(game.messages.isEmpty)
    #expect(game.visionCalls.isEmpty)
    #expect(game.issue == nil)
    let events = try trace.events()
    #expect(events.last { $0.kind == "run_ended" }?.data["reason"] as? String == "reset")
    #expect(events.last?.kind == "world_reset")
    #expect(try trace.state().observation.avatar == [8, 5])
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func modelPlansDuringPlaybackAndStopPreservesOnlyAppliedActions() async throws {
    let trace = DebugTraceFiles()
    let export = try DebugExport(directory: trace.directory)
    defer { try? FileManager.default.removeItem(at: trace.directory) }
    let game = GameSession(actionDelay: .seconds(10), debugExport: export)
    let model = SuspendedModel()
    let start = game.world.avatar
    let worldChanged = AsyncStream<Void> { continuation in
        withObservationTracking {
            _ = game.world
        } onChange: {
            continuation.yield(())
            continuation.finish()
        }
    }

    game.start(model: model)
    let task = try #require(game.task)
    await model.waitUntilRequested()
    await model.respond(with: batchCall("in-progress", """
        [{"action":"move","direction":"east"},{"action":"say","text":"Too late."},
         {"action":"move","direction":"east"}]
        """))
    for await _ in worldChanged { break }
    var nextReply: ToolReply?
    for await reply in model.followUp.stream {
        nextReply = reply
        break
    }
    let reply = try #require(nextReply)
    var projectedWorld = game.world
    #expect(projectedWorld.apply(.move(.east)) == .moved)
    #expect(reply.receipt.observation == projectedWorld.observation())
    #expect(reply.receipt.results == [.moved, .messageSent, .moved])
    let live = try trace.state()
    #expect(live.phase == "playing_batch")
    #expect(live.batch?.processed == 1)
    #expect(live.observation.avatar == [start.x + 1, start.y])
    #expect(live.observation.notebook.isEmpty)
    #expect(live.messages.isEmpty)
    game.stop()
    await task.value

    #expect(game.world.avatar == start.neighbor(.east))
    #expect(game.notebook.isEmpty)
    #expect(game.messages.isEmpty)
    #expect(!game.isRunning)
    #expect(game.issue == nil)
    #expect(try trace.state().phase == "idle")
    let events = try trace.events()
    let plan = try #require(events.first { $0.kind == "batch_projected" })
    let receipt = try #require(plan.data["receipt"] as? [String: Any])
    let projected = try #require(receipt["observation"] as? [String: Any])
    #expect(projected["avatar"] as? [Int] == [start.x + 2, start.y])
    #expect(events.filter { $0.kind == "action_processed" }.count == 1)
    let end = try #require(events.last)
    #expect(end.kind == "run_ended")
    #expect(end.data["reason"] as? String == "stopped")
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func stoppingWalkPreservesOnlyThePlayedSteps() async throws {
    let trace = DebugTraceFiles()
    let export = try DebugExport(directory: trace.directory)
    defer { try? FileManager.default.removeItem(at: trace.directory) }
    let game = GameSession(actionDelay: .seconds(10), debugExport: export)
    let model = SuspendedModel()
    let firstStep = AsyncStream<Void> { continuation in
        withObservationTracking {
            _ = game.world
        } onChange: {
            continuation.yield(())
            continuation.finish()
        }
    }

    game.start(model: model)
    let task = try #require(game.task)
    await model.waitUntilRequested()
    await model.respond(with: batchCall("walk", """
        [{"action":"walk_to","x":8,"y":3},{"action":"say","text":"Arrived."}]
        """))
    for await _ in firstStep { break }
    #expect(try trace.state().observation.avatar == [9, 5])
    #expect(try trace.state().batch?.processed == 0)
    game.stop()
    await task.value

    #expect(game.world.avatar == Position(x: 9, y: 5))
    #expect(game.messages.isEmpty)
    let events = try trace.events()
    let steps = events.filter { $0.kind == "walk_step" }
    #expect(steps.count == 1)
    #expect(steps.first?.data["step"] as? Int == 1)
    #expect(steps.first?.data["index"] as? Int == 0)
    #expect(steps.first?.data["avatar"] as? [Int] == [9, 5])
    #expect(!events.contains { $0.kind == "action_processed" })
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func coordinateActionsAndQueriesSeeTheCurrentWorld() async throws {
    let game = GameSession(actionDelay: .zero)
    let model = ScriptedTools([
        toolCall("plans", .query, """
        {"queries":[{"query":"estimate_materials","counts":{"wall_ns":7,"floor":1,"grass_bed":1}},
         {"query":"find_build_sites","width":3,"height":3,"limit":2},
         {"query":"preview_build","placements":[{"x":9,"y":5,"structure":"floor"},{"x":7,"y":5,"structure":"wall_ns"}]}]}
        """),
        batchCall("build", """
        [
         {"action":"collect_at","x":8,"y":4,"target":"above"},
         {"action":"collect_at","x":8,"y":4,"target":"item","item":"log"},
         {"action":"craft","item":"plank"},
         {"action":"place_at","x":9,"y":5,"structure":"floor"},
         {"action":"collect_at","x":11,"y":5,"target":"above"}]
        """),
        toolCall("resources", .query, #"{"queries":[{"query":"find_resources","resource":"log","limit":1}]}"#),
        batchCall("blocked", """
        [{"action":"place_at","x":8,"y":2,"structure":"wall_ns"},
         {"action":"say","text":"Skipped"}]
        """),
        batchCall("finish", #"[{"action":"finish"}]"#),
    ])
    game.start(model: model)
    await (try #require(game.task)).value
    let replies = await model.replies
    try #require(replies.count == 4)
    #expect(replies[0].receipt.results == [.inspected, .inspected, .inspected])
    #expect(replies[1].receipt.results == [.collected, .collected, .crafted, .placed, .collected])
    #expect(replies[2].receipt.results == [.inspected])
    #expect(replies[3].receipt.results == [.buildBlocked])
    #expect(replies[3].receipt.skipped == 1)
    let queries = try #require(replies[0].receipt.queries)
    try #require(queries.map(\.index) == [0, 1, 2])
    #expect(queries[0].materials?.missing == ["log": 3, "grass": 2])
    #expect(queries[0].materials?.crafts == ["plank": 3, "grass_bed": 1])
    #expect(queries[1].sites?.count == 2)
    #expect(queries[2].preview?.validLayout == false)
    #expect(queries[2].preview?.failure?.index == 1)
    #expect(queries[2].preview?.failure?.position == [7, 5])
    let resource = replies[2].receipt.queries?.first?.resources?.first
    #expect(resource?.position == [11, 5])
    #expect(resource?.stand == [10, 5])
    #expect(resource?.steps == 0)
    #expect(game.world.avatar == Position(x: 10, y: 5))
    #expect(game.world.tile(at: Position(x: 9, y: 5))?.hasFloor == true)
    #expect(game.world.inventory == [.plank: 3])
    #expect(game.messages.isEmpty)
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func visionSendsEachPNGOnceAndKeepsTheSameImageInHistory() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubChatEndpoint.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }

    let endpoint = try #require(URL(string: "https://model.example/vision-test"))
    let trace = DebugTraceFiles()
    let export = try DebugExport(directory: trace.directory)
    defer { try? FileManager.default.removeItem(at: trace.directory) }
    let debugger = APIDebugger(debugExport: export)
    let game = GameSession(actionDelay: .zero, debugExport: export)
    game.start(model: ChatCompletionsModel(
        endpoint: endpoint, model: "test-vision", apiKey: nil, taskGoal: "Inspect the map",
        streaming: false, visionEnabled: true, session: session, debugger: debugger
    ))
    await (try #require(game.task)).value
    #expect(game.issue == nil)
    let calls = game.visionCalls
    #expect(game.messages.isEmpty)
    #expect(calls.map(\.number) == [1, 2, 3, 4])
    #expect(calls.map(\.status) == [.sent, .sent, .sent, .invalid])
    #expect(calls.map(\.openingScan) == [true, false, false, false])
    try #require(calls.count == 4)
    #expect(calls[3].frame == nil)
    let records = await StubChatEndpoint.visionService.records
    try #require(records.count == 6)
    let bodies: [[[String: Any]]] = try records.map { record in
        let body = try #require(record.body)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect(tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
                == ["act", "memory", "query", "vision"])
        return try #require(json["messages"] as? [[String: Any]])
    }
    #expect(bodies.map(\.count) == [2, 5, 4, 4, 5, 4])
    for (call, requestIndex) in zip(calls, [0, 1, 4]) {
        let messages = bodies[requestIndex]
        let roles = call.openingScan ? ["system", "user"] : ["system", "user", "assistant", "tool", "user"]
        #expect(messages.compactMap { $0["role"] as? String } == roles)
        let parts = try #require(messages.last?["content"] as? [[String: Any]])
        #expect(parts.compactMap { $0["type"] as? String } == ["text", "image_url"])
        let url = try #require((parts.last?["image_url"] as? [String: Any])?["url"] as? String)
        let prefix = "data:image/png;base64,"
        try #require(url.hasPrefix(prefix))
        let frame = try #require(call.frame)
        #expect(Data(base64Encoded: String(url.dropFirst(prefix.count))) == frame.png)
        #expect(frame.png.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]))
        #expect(frame.width == 736 && frame.height == 536)
        if call.openingScan {
            let turn = try decode(WirePlayerTurn.self, parts.first?["text"] as? String)
            #expect(turn.observation?.avatar == [call.avatar.x, call.avatar.y])
        } else {
            let receipt = try decode(WireReceipt.self, messages[3]["content"] as? String)
            #expect(receipt.observation.avatar == [call.avatar.x, call.avatar.y])
        }
        #expect(debugger.exchanges[requestIndex].visionID == call.id)
    }
    #expect(calls.map { [$0.avatar.x, $0.avatar.y] } == [[8, 5], [8, 5], [9, 5], [9, 5]])
    #expect(calls[1].frame?.png != calls[2].frame?.png)
    #expect(debugger.exchanges.compactMap(\.visionID) == Array(calls.prefix(3).map(\.id)))
    #expect(debugger.exchanges.allSatisfy { !$0.requestBody.contains("iVBORw0KGgo") })
    let events = try trace.events().filter { $0.kind == "vision_called" }
    #expect(events.first?.data["openingScan"] as? Bool == true)
    #expect(events.compactMap { $0.data["toolCallID"] as? String } == ["vision-1", "vision-2", "vision-3"])
    game.reset()
    #expect(game.visionCalls.isEmpty)
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func chatCompletionsReceivesFeedbackOncePerBatch() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubChatEndpoint.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }

    let endpoint = try #require(URL(string: "https://model.example/v1/chat/completions"))
    let trace = DebugTraceFiles()
    let export = try DebugExport(directory: trace.directory)
    defer { try? FileManager.default.removeItem(at: trace.directory) }
    let debugger = APIDebugger(debugExport: export)
    let goal = "Use the first plank to lay one floor tile."
    let client = ChatCompletionsModel(
        endpoint: endpoint, model: "test-model", apiKey: "test-only", taskGoal: goal,
        session: session, debugger: debugger
    )
    let game = GameSession(actionDelay: .zero, debugExport: export)
    game.updateDebugInputs(.init(goal: goal, instructions: "", address: endpoint.absoluteString,
                                 model: "test-model", reasoningEffort: "automatic", streaming: true))
    let initial = game.world.observation()
    game.start(model: client)
    let task = try #require(game.task)
    await task.value

    #expect(game.issue == nil)
    #expect(!game.isRunning)
    #expect(game.world.inventory == [.log: 1, .plank: 3])
    #expect(game.world.tile(at: Position(x: 9, y: 5))?.hasFloor == true)
    #expect(game.world.avatar == Position(x: 8, y: 4))
    #expect(game.messages.map(\.text) == ["I'll cut down a tree first.", "I picked up the log.", "All done."])
    #expect(game.messages.map(\.sender) == ["Character", "Character", "Character"])

    let records = await StubChatEndpoint.service.records
    try #require(records.count == 9)
    try #require(debugger.exchanges.count == records.count)
    for (exchange, record) in zip(debugger.exchanges, records) {
        #expect(exchange.requestBody == record.body.map { String(decoding: $0, as: UTF8.self) })
        #expect(!exchange.requestHeaders.localizedCaseInsensitiveContains("authorization"))
        #expect(exchange.outcome.label == "HTTP 200")
    }
    var requests: [RecordedBody] = []
    for record in records {
        let data = try #require(record.body)
        #expect(record.method == "POST")
        #expect(record.authorization == "Bearer test-only")
        #expect(!String(decoding: data, as: UTF8.self).contains("test-only"))
        requests.append(try JSONDecoder().decode(RecordedBody.self, from: data))
    }
    #expect(requests.allSatisfy { !$0.parallelToolCalls && !$0.store && $0.model == "test-model" })
    #expect(requests.allSatisfy { $0.tools.map(\.function.name) == ["act", "memory", "query"] })
    #expect(requests[0].messages.map(\.role) == ["system", "user"])
    let firstTurn = try decode(WirePlayerTurn.self, requests[0].messages[1].content)
    let firstView = try #require(firstTurn.observation)
    #expect(firstTurn.goal == goal)
    #expect(firstView.ground.count == 12)
    #expect(firstView.above.count == 12)
    #expect((firstView.ground + firstView.above).allSatisfy { expandMapRow($0).count == 17 })
    #expect(expandMapRow(firstView.above[8])[9] == "tr")
    #expect(firstView.avatar == [8, 5])
    #expect(firstView.inventory == initial.inventory)
    #expect(firstView.notebook.isEmpty)
    #expect(requests[0].messages[0].content?.contains(goal) == false)
    #expect(requests[0].messages[0].content?.contains("take loose items before attached items") == true)
    #expect(requests[0].messages[0].content?.contains("The player is watching") == false)
    let schemas = requests[0].tools.map(\.function.parameters)
    let properties = try #require(schemas[0].properties?["actions"]?.items?.properties)
    #expect(properties["action"]?.choices == CharacterActionName.allCases.map(\.rawValue))
    #expect(properties["target"]?.choices == ["item", "above", "ground"])
    #expect(properties["x"]?.type == "integer")
    #expect(properties["y"]?.type == "integer")
    #expect(schemas[0].properties?.keys.sorted() == ["actions"])
    #expect(schemas[1].properties?.keys.sorted() == ["remove", "set", "text"])
    let queryProperties = try #require(schemas[2].properties?["queries"]?.items?.properties)
    #expect(queryProperties["resource"]?.choices == ResourceKind.allCases.map(\.rawValue))
    #expect(queryProperties["counts"]?.type == "object")
    #expect(queryProperties["placements"]?.type == "array")
    #expect(requests.allSatisfy { $0.toolChoice == "auto" })
    #expect(requests[8].messages[0].content?.contains("previous response used plain text") == true)
    #expect(Array(requests[8].messages.dropFirst().map(\.content)) ==
            Array(requests[7].messages.dropFirst().map(\.content)))
    #expect(debugger.exchanges[7].outcome.label == "HTTP 200")

    let results: [[ActionOutcome]] = [
        [.memoryUpdated],
        [.messageSent, .collected, .collected, .collected, .crafted, .placed, .collected,
         .placed, .arrived, .arrived, .unreachable],
        [.memoryUpdated],
        [.invalidArguments],
        [.invalidArguments],
        [.memoryUpdated],
        [.messageSent],
    ]
    let skipped = [0, 2, 0, 1, 0, 0, 0]
    let updates: [String?] = ["applied", nil, "applied", nil, "invalid", "applied", nil]
    for (index, request) in requests.dropFirst().dropLast().enumerated() {
        #expect(request.messages.map(\.role) == ["system", "user", "assistant", "tool"])
        let playerTurn = try decode(WirePlayerTurn.self, request.messages[1].content)
        #expect(playerTurn.goal == goal)
        #expect(playerTurn.observation == nil)
        let action = try #require(request.messages[2].toolCalls?.first)
        #expect(action.id == "call-\(index)")
        #expect(request.messages[3].toolCallID == action.id)
        #expect(request.messages[2].content == nil)
        #expect(request.messages[2].reasoningContent == "reasoning for \(action.id)")
        let receipt = try decode(WireReceipt.self, request.messages[3].content)
        #expect(receipt.results == results[index])
        #expect(receipt.memory?.entries == (index < 2 ? ["idea": "Build a path by the lake"] : ["decision": "Keep the logs for now"]))
        #expect(receipt.memory?.update == updates[index])
        if index < 2 {
            #expect(receipt.recentHistory == nil)
        } else {
            #expect(receipt.recentHistory?.first?.last?.result == .unreachable)
            #expect(receipt.recentHistory?.first?.last?.avatar == [8, 4])
        }
        #expect(receipt.skipped == skipped[index])
        if index == 1 {
            #expect(receipt.walks == [
                .init(index: 8, destination: [8, 4], steps: 1),
                .init(index: 9, destination: [8, 4], steps: 0),
            ])
        } else {
            #expect(receipt.walks == nil)
        }
        #expect(receipt.observation.notebook == (index < 5 ? "Gather materials first" : "Floor installed"))
        #expect(expandMapRow(receipt.observation.above[8])[9] == "tr")
        if index > 0 {
            #expect(receipt.observation.avatar == [8, 4])
            #expect(expandMapRow(receipt.observation.above[4])[8] == "air")
            #expect(expandMapRow(receipt.observation.ground[5])[9] == "fl")
            #expect(receipt.observation.inventory == game.world.observation().inventory)
        }
    }
    #expect(game.notebook == "Floor installed")
    let live = try trace.state()
    #expect(live.phase == "idle")
    #expect(live.inputs?.goal == goal)
    #expect(live.inputs?.model == "test-model")
    #expect(live.observation.avatar == [8, 4])
    #expect(expandMapRow(live.observation.ground[5])[9] == "fl")
    #expect(live.observation.inventory == ["log": 1, "plank": 3])
    #expect(live.observation.notebook == "Floor installed")
    #expect(live.messages.map(\.text) == game.messages.map(\.text))
    #expect(live.tileItems.contains { $0.position == [9, 8] && $0.attached == ["branch": 3] })
    let events = try trace.events()
    #expect(events.map(\.sequence) == Array(1...events.count))
    let apiRequests = events.filter { $0.kind == "api_request" }
    #expect(apiRequests.count == records.count)
    #expect(apiRequests.compactMap { $0.data["requestBody"] as? String } == debugger.exchanges.map(\.requestBody))
    let responses = events.filter { $0.kind == "api_update" }.compactMap {
        ($0.data["outcome"] as? [String: Any])?["response"] as? [String: Any]
    }
    #expect(responses.count == records.count)
    #expect(responses.first?["status"] as? Int == 200)
    #expect((responses.first?["body"] as? String)?.contains("call-0") == true)
    let projected = events.filter { $0.kind == "batch_projected" }
    #expect(projected.count == 4)
    #expect(projected.first?.data["exchangeID"] as? String == apiRequests[1].data["id"] as? String)
    #expect(events.filter { $0.kind == "tool_processed" }.count == 4)
    let processed = results[1] + results[3] + results[6] + [.messageSent, .finished]
    #expect(events.filter { $0.kind == "action_processed" }.compactMap { $0.data["result"] as? String }
        == processed.map(\.rawValue))
    #expect(events.last?.data["reason"] as? String == "finished")
    let resumed = SuspendedModel()
    game.start(model: resumed)
    let resumedTask = try #require(game.task)
    await resumed.waitUntilRequested()
    #expect(await resumed.initialObservation?.notebook == "Floor installed")
    await resumed.respond(with: toolCall("clear", .memory, #"{"text":""}"#))
    await resumedTask.value
    #expect(game.notebook.isEmpty)
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func debugPromptAndFailedResponsesAreCapturedWithoutCredentials() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubChatEndpoint.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }

    let endpoint = try #require(URL(string: "https://model.example/debug-error"))
    let trace = DebugTraceFiles()
    let export = try DebugExport(directory: trace.directory)
    defer { try? FileManager.default.removeItem(at: trace.directory) }
    let debugger = APIDebugger(debugExport: export)
    for (goal, prompt) in [("Lay the floor", "Inspect a neighboring cell."), ("Find grass", "Choose another action.")] {
        debugger.prompt = prompt
        let client = ChatCompletionsModel(
            endpoint: endpoint, model: "test-model", apiKey: "test-only", taskGoal: goal,
            session: session, debugger: debugger
        )
        do {
            _ = try await client.chooseTool(.initial(World().observation()))
            Issue.record("Expected HTTP 400")
        } catch {
            #expect(error.localizedDescription.contains("HTTP 400"))
        }
        let exchange = try #require(debugger.exchanges.last)
        let request = try JSONDecoder().decode(RecordedBody.self, from: Data(exchange.requestBody.utf8))
        let playerTurn = try decode(WirePlayerTurn.self, request.messages[1].content)
        #expect(playerTurn.goal == goal)
        #expect(playerTurn.instructions == prompt)
        #expect(request.messages[0].content?.contains(goal) == false)
        if case .response(400, let headers, let body) = exchange.outcome {
            #expect(headers.contains("test-request"))
            #expect(!headers.localizedCaseInsensitiveContains("set-cookie"))
            #expect(body.contains("bad request [redacted]"))
            #expect(!body.contains("test-only"))
        } else {
            Issue.record("Expected the HTTP error response in the debug trace")
        }
    }
    #expect(debugger.exchanges.count == 2)
    debugger.clear()
    #expect(debugger.exchanges.isEmpty)
    #expect(try trace.events().last?.kind == "api_history_cleared")
    let game = GameSession(debugExport: export)
    game.start(model: ChatCompletionsModel(endpoint: endpoint, model: "test-model", apiKey: "test-only",
                                           taskGoal: "Find grass", session: session, debugger: debugger))
    await (try #require(game.task)).value
    #expect(try trace.state().issue?.contains("HTTP 400") == true)
    #expect(try trace.events().contains { $0.kind == "game_error" })
    export.snapshot(["note": "Echo test-only"])
    let journal = try String(contentsOf: trace.directory.appendingPathComponent("events.jsonl"), encoding: .utf8)
    #expect(journal.contains("\"status\":400"))
    #expect(journal.contains("bad request [redacted]"))
    #expect(!journal.contains("test-only"))
    #expect(!journal.localizedCaseInsensitiveContains("set-cookie"))
    #expect(!journal.localizedCaseInsensitiveContains("authorization"))
    let stateData = try Data(contentsOf: trace.directory.appendingPathComponent("state.json"))
    #expect(try JSONDecoder().decode([String: String].self, from: stateData) == ["note": "Echo [redacted]"])
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func streamedReasoningAndActionsAreAssembledAndIncompleteStreamIsRejected() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubChatEndpoint.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let trace = DebugTraceFiles()
    let export = try DebugExport(directory: trace.directory)
    defer { try? FileManager.default.removeItem(at: trace.directory) }
    let debugger = APIDebugger(debugExport: export)
    let endpoint = try #require(URL(string: "https://model.example/stream-test"))
    let model = ChatCompletionsModel(endpoint: endpoint, model: "deepseek-flash", apiKey: nil, taskGoal: "Take one step",
                                     reasoningEffort: "low", session: session, debugger: debugger)
    let turn = ModelTurn.initial(World().observation())
    let requestTask = Task { try await model.chooseTool(turn) }
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    var sawPlanningBeforeCompletion = false
    while ContinuousClock.now < deadline {
        if case .receiving(_, "Planning", let preview) = debugger.exchanges.last?.outcome {
            sawPlanningBeforeCompletion = preview == "One step"
            break
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(sawPlanningBeforeCompletion)
    let call = try await requestTask.value
    #expect(call.id == "stream-call")
    #expect(call.reasoningContent == "One step east — clear.")
    #expect(call.function.arguments == #"{"actions":[{"action":"move","direction":"east"}]}"#)
    #expect(try call.decodeBatch().actions.count == 1)
    let completed = try #require(debugger.exchanges.last)
    let request = try #require(JSONSerialization.jsonObject(with: Data(completed.requestBody.utf8)) as? [String: Any])
    #expect(request["stream"] as? Bool == true)
    #expect(request["reasoning_effort"] as? String == "low")
    if case let .response(status, _, body) = completed.outcome {
        #expect(status == 200)
        #expect(body.contains("reasoning_tokens"))
    } else {
        Issue.record("Expected assembled response in the debug trace")
    }

    let incomplete = ChatCompletionsModel(endpoint: endpoint.appendingPathComponent("short"), model: "deepseek-flash",
                                          apiKey: nil, taskGoal: "Take one step", session: session, debugger: debugger)
    do {
        _ = try await incomplete.chooseTool(turn)
        Issue.record("Expected to reject a truncated stream")
    } catch ModelAPIError.incompleteStream {
        // A complete-looking action is still unusable before the stream finishes.
    }
    let updates = try trace.events().filter { $0.kind == "api_update" }
        .compactMap { $0.data["outcome"] as? [String: Any] }
    #expect(updates.contains {
        ($0["receiving"] as? [String: Any])?["preview"] as? String == "One step"
    })
    #expect(updates.contains {
        (($0["response"] as? [String: Any])?["body"] as? String)?.contains("reasoning_tokens") == true
    })
    #expect(updates.last?["failed"] != nil)
}

private struct DebugTraceFiles {
    struct State: Decodable {
        struct Inputs: Decodable {
            let goal: String
            let model: String
        }

        struct Batch: Decodable {
            let processed: Int
        }

        struct Message: Decodable {
            let text: String
        }

        struct TileItems: Decodable {
            let position: [Int]
            let attached: [String: Int]
        }

        let phase: String
        let inputs: Inputs?
        let batch: Batch?
        let observation: WireObservation
        let messages: [Message]
        let tileItems: [TileItems]
        let issue: String?
    }

    struct Event {
        let kind: String
        let sequence: Int
        let data: [String: Any]
    }

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    func state() throws -> State {
        try JSONDecoder().decode(State.self, from: Data(contentsOf: directory.appendingPathComponent("state.json")))
    }

    func events() throws -> [Event] {
        let journal = try String(contentsOf: directory.appendingPathComponent("events.jsonl"), encoding: .utf8)
        return try journal.split(separator: "\n").map { line in
            let object = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            return try Event(kind: #require(object["kind"] as? String),
                             sequence: #require(object["sequence"] as? Int),
                             data: #require(object["data"] as? [String: Any]))
        }
    }
}

private func decode<T: Decodable>(_ type: T.Type, _ text: String?) throws -> T {
    try JSONDecoder().decode(type, from: Data(try #require(text).utf8))
}

private func toolCall(_ id: String, _ tool: CharacterTool, _ arguments: String) -> ToolCall {
    ToolCall(id: id, type: "function", function: .init(name: tool.rawValue, arguments: arguments))
}

private func batchCall(_ id: String, _ actions: String) -> ToolCall {
    toolCall(id, .act, "{\"actions\":\(actions)}")
}

private actor ScriptedTools: CharacterModel {
    private let calls: [ToolCall]
    private var index = 0
    private(set) var replies: [ToolReply] = []

    init(_ calls: [ToolCall]) {
        self.calls = calls
    }

    func chooseTool(_ turn: ModelTurn) async throws -> ToolCall {
        if case .result(let reply) = turn { replies.append(reply) }
        guard calls.indices.contains(index) else { throw ModelAPIError.noToolCall(nil) }
        defer { index += 1 }
        return calls[index]
    }
}

private actor SuspendedModel: CharacterModel {
    let followUp = AsyncStream<ToolReply>.makeStream()
    private var action: CheckedContinuation<ToolCall, Never>?
    private var requested: CheckedContinuation<Void, Never>?
    private var previousRequest = false
    private(set) var initialObservation: WorldObservation?

    func chooseTool(_ turn: ModelTurn) async throws -> ToolCall {
        if previousRequest {
            if case .result(let reply) = turn { followUp.continuation.yield(reply) }
            followUp.continuation.finish()
            return batchCall("fallback", #"[{"action":"finish"}]"#)
        }
        previousRequest = true
        if case .initial(let observation, _) = turn { initialObservation = observation }
        return await withCheckedContinuation { continuation in
            action = continuation
            requested?.resume()
            requested = nil
        }
    }

    func waitUntilRequested() async {
        if action != nil { return }
        await withCheckedContinuation { requested = $0 }
    }

    func respond(with call: ToolCall) {
        action?.resume(returning: call)
        action = nil
    }
}

private struct WirePlayerTurn: Decodable {
    let goal: String
    let observation: WireObservation?
    let instructions: String?
}

private struct WireObservation: Decodable, Equatable {
    let ground: [String]
    let above: [String]
    let avatar: [Int]
    let inventory: [String: Int]
    let notebook: String
}

private struct WireReceipt: Decodable {
    struct Walk: Decodable, Equatable {
        let index: Int
        let destination: [Int]
        let steps: Int
    }

    let results: [ActionOutcome]
    let skipped: Int
    let observation: WireObservation
    struct Memory: Decodable {
        let entries: [String: String]
        let update: String?
    }

    struct HistoryEvent: Decodable {
        let result: ActionOutcome
        let avatar: [Int]?
    }

    let walks: [Walk]?
    let memory: Memory?
    let recentHistory: [[HistoryEvent]]?
}

private struct RecordedBody: Decodable {
    struct Tool: Decodable {
        struct Function: Decodable {
            let name: String
            let parameters: Parameter
        }
        let function: Function
    }

    final class Parameter: Decodable {
        let type: String
        let choices: [String]?
        let properties: [String: Parameter]?
        let items: Parameter?

        enum CodingKeys: String, CodingKey {
            case type, properties, items
            case choices = "enum"
        }
    }

    struct Message: Decodable {
        let role: String
        let content: String?
        let toolCalls: [ToolCall]?
        let toolCallID: String?
        let reasoningContent: String?

        enum CodingKeys: String, CodingKey {
            case role, content
            case toolCalls = "tool_calls"
            case toolCallID = "tool_call_id"
            case reasoningContent = "reasoning_content"
        }
    }

    let model: String
    let messages: [Message]
    let tools: [Tool]
    let toolChoice: String
    let parallelToolCalls: Bool
    let store: Bool

    enum CodingKeys: String, CodingKey {
        case model, messages, store, tools
        case toolChoice = "tool_choice"
        case parallelToolCalls = "parallel_tool_calls"
    }
}

private struct HTTPRecord: Sendable {
    let method: String?
    let authorization: String?
    let body: Data?
}

private actor StubChatService {
    private(set) var records: [HTTPRecord] = []

    func reply(to request: HTTPRecord) -> Data {
        records.append(request)
        if records.count == 8 {
            return Data(#"{"choices":[{"message":{"role":"assistant","content":"Plain-text completion"},"finish_reason":"stop"}]}"#.utf8)
        }
        let calls = [
            toolCall("call-0", .memory, #"{"text":"Gather materials first","set":{"idea":"Build a path by the lake"}}"#),
            batchCall("call-1", """
                [{"action":"say","text":"I'll cut down a tree first."},{"action":"collect","direction":"north","target":"above"},
                 {"action":"collect","direction":"north","target":"item","item":"log"},
                 {"action":"collect","direction":"north","target":"item","item":"log"},
                 {"action":"craft","item":"plank"},{"action":"place","direction":"east","structure":"floor"},
                 {"action":"collect","direction":"east","target":"ground"},
                 {"action":"place","direction":"east","structure":"floor"},
                 {"action":"walk_to","x":8,"y":4},{"action":"walk_to","x":8,"y":4},{"action":"walk_to","x":7,"y":4},
                 {"action":"say","text":"Skipped after blocked move."},{"action":"move","direction":"east"}]
                """),
            toolCall("call-2", .memory, #"{"set":{"decision":"Keep the logs for now"},"remove":["idea"]}"#),
            batchCall("call-3", #"[{"action":"walk_to","x":"8","y":4},{"action":"say","text":"Skipped."}]"#),
            toolCall("call-4", .memory, #"{"text":"invalid patch","set":{"invalid":42}}"#),
            toolCall("call-5", .memory, #"{"text":"Floor installed"}"#),
            batchCall("call-6", #"[{"action":"say","text":"I picked up the log."}]"#),
            batchCall("call-7", #"[{"action":"say","text":"All done."},{"action":"finish"},{"action":"say","text":"Skipped after finish."}]"#),
        ]
        let index = records.count < 8 ? records.count - 1 : records.count - 2
        guard calls.indices.contains(index) else { return Data("{}".utf8) }
        let action = calls[index]
        let encoded = try! JSONEncoder().encode(action)
        return Data("""
            {"choices":[{"message":{"role":"assistant","content":"API text",
              "reasoning_content":"reasoning for \(action.id)","tool_calls":[\(String(decoding: encoded, as: UTF8.self))]}}]}
            """.utf8)
    }
}

private actor StubVisionService {
    private(set) var records: [HTTPRecord] = []

    func reply(to request: HTTPRecord) -> Data {
        let calls: [ToolCall?] = [
            toolCall("vision-1", .vision, "{}"),
            nil,
            batchCall("step", #"[{"action":"move","direction":"east"}]"#),
            toolCall("vision-2", .vision, "{}"),
            toolCall("vision-3", .vision, #"{"x":4}"#),
            batchCall("done", #"[{"action":"finish"}]"#),
        ]
        let index = records.count
        records.append(request)
        guard calls.indices.contains(index) else { return Data("{}".utf8) }
        guard let call = calls[index] else {
            return Data(#"{"choices":[{"message":{"content":"I can see the map."},"finish_reason":"stop"}]}"#.utf8)
        }
        let encoded = String(decoding: try! JSONEncoder().encode(call), as: UTF8.self)
        return Data(#"{"choices":[{"message":{"tool_calls":[\#(encoded)]},"finish_reason":"tool_calls"}]}"#.utf8)
    }
}

private final class StubChatEndpoint: URLProtocol, @unchecked Sendable {
    static let service = StubChatService()
    static let visionService = StubVisionService()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let record = HTTPRecord(
            method: request.httpMethod,
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            body: request.httpBody ?? readBodyStream()
        )
        Task {
            let url = request.url!
            let status: Int
            let data: Data
            let headers: [String: String]
            if url.absoluteString == zhipuTestEndpoint {
                status = 200
                let body = record.body.map { String(decoding: $0, as: UTF8.self) } ?? ""
                let followUp = body.contains(#""tool_call_id":"glm-note""#)
                let call = followUp
                    ? batchCall("glm-finish", #"[{"action":"say","text":"Noted"},{"action":"finish"}]"#)
                    : toolCall("glm-note", .memory, #"{"text":"The doorway faces east"}"#)
                let reasoning = followUp ? "Task complete" : "Note the doorway"
                if body.contains(#""stream":true"#) {
                    headers = ["Content-Type": "text/event-stream"]
                    let arguments = call.function.arguments
                    let start = String(decoding: try! JSONEncoder().encode(String(arguments.prefix(4))), as: UTF8.self)
                    let rest = String(decoding: try! JSONEncoder().encode(String(arguments.dropFirst(4))), as: UTF8.self)
                    data = Data(#"""
                        data: {"choices":[{"index":0,"delta":{"reasoning_content":"\#(reasoning)"}}]}

                        data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"\#(call.id)","type":"function","function":{"name":"\#(call.function.name)","arguments":\#(start)}}]}}]}

                        data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":\#(rest)}}]}}]}

                        data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}

                        data: [DONE]

                        """#.utf8)
                } else {
                    headers = ["Content-Type": "application/json"]
                    let encodedCall = try! JSONEncoder().encode(call)
                    data = Data(#"""
                        {"choices":[{"message":{"role":"assistant","content":null,"reasoning_content":"\#(reasoning)","tool_calls":[\#(String(decoding: encodedCall, as: UTF8.self))]},"finish_reason":"tool_calls"}]}
                        """#.utf8)
                }
            } else if url.path.hasPrefix("/stream-test") {
                status = 200
                headers = ["Content-Type": "text/event-stream"]
                let frames = #"""
                    : keep-alive

                    data: {"choices":[{"index":0,"delta":{"reasoning_content":" east"}}]}

                    data: {"choices":[{"index":0,"delta":{"reasoning_content":" — clear."}}]}

                    data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"stream-call","type":"function","function":{"name":"act","arguments":"{\"actions\":["}}]}}]}

                    data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"action\":\"move\",\"direction\":\"east\"}]}"}}]}}]}

                    """#
                let end = #"""

                    data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":{"completion_tokens_details":{"reasoning_tokens":2}}}

                    data: [DONE]

                    """#
                data = Data((frames + (url.path == "/stream-test" ? end : "")).utf8)
            } else if url.path == "/debug-error" {
                status = 400
                data = Data(#"{"error":{"message":"bad request test-only"}}"#.utf8)
                headers = ["X-Request-Id": "test-request", "Set-Cookie": "private"]
            } else if url.path == "/vision-test" {
                status = 200
                data = await Self.visionService.reply(to: record)
                headers = [:]
            } else {
                status = 200
                data = await Self.service.reply(to: record)
                headers = [:]
            }
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if url.path.hasPrefix("/stream-test") {
                let firstFrame = #"data: {"choices":[{"index":0,"delta":{"reasoning_content":"One step"}}]}"# + "\n\n"
                client?.urlProtocol(self, didLoad: Data(firstFrame.utf8))
                if url.path == "/stream-test" { try? await Task.sleep(for: .milliseconds(600)) }
            }
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    private func readBodyStream() -> Data? {
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { return read == 0 ? data : nil }
            data.append(contentsOf: buffer.prefix(read))
        }
    }
}
