import Foundation

enum CharacterTool: String, Sendable {
    case act, memory, vision
    case requestPlan = "request_plan"
}

struct PlanRequest: Decodable, Sendable {
    let brief: String
    let includeVision: Bool?

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: ToolField.self)
        let names = Set(fields.allKeys.map(\.stringValue))
        let brief = try fields.decode(String.self, forKey: ToolField("brief"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard names.isSubset(of: ["brief", "include_vision"]), !brief.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Expected a nonempty brief and optional include_vision"))
        }
        self.brief = brief
        self.includeVision = try fields.decodeIfPresent(Bool.self, forKey: ToolField("include_vision"))
    }
}

struct PlanProposal: Decodable, Sendable {
    let summary: String
    let placements: [BlueprintPlacement]

    init(summary: String, placements: [BlueprintPlacement]) {
        self.summary = summary
        self.placements = placements
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: ToolField.self)
        guard Set(fields.allKeys.map(\.stringValue)) == ["summary", "placements"] else {
            throw ModelAPIError.invalidPlanResponse
        }
        let summary = try fields.decode(String.self, forKey: ToolField("summary"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let placements = try fields.decode([BlueprintPlacement].self, forKey: ToolField("placements"))
        guard !summary.isEmpty, !placements.isEmpty else { throw ModelAPIError.invalidPlanResponse }
        self.init(summary: summary, placements: placements)
    }
}

struct ToolCall: Codable, Equatable, Sendable {
    struct Function: Codable, Equatable, Sendable {
        let name: String
        let arguments: String
    }

    let id: String
    let type: String
    let function: Function
    var reasoningContent: String?
    var debugExchangeID: UUID?

    enum CodingKeys: String, CodingKey {
        case id, type, function
    }

    var tool: CharacterTool? { type == "function" ? CharacterTool(rawValue: function.name) : nil }

    func decodeBatch() throws -> ActionBatch {
        try decode(ActionBatch.self)
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: Data(function.arguments.utf8))
    }
}

struct ToolReply: Sendable {
    let call: ToolCall
    let receipt: ToolReceipt
    var vision: VisionCall? = nil
}

enum ModelTurn: Sendable {
    case initial(WorldObservation, vision: VisionCall? = nil, context: ModelContext? = nil)
    case result([ToolReply], context: ModelContext? = nil)
}

protocol CharacterModel: Sendable {
    var visionEnabled: Bool { get }
    func chooseTools(_ turn: ModelTurn) async throws -> [ToolCall]
    func plan(brief: String, observation: WorldObservation, vision: VisionCall?, planID: UUID) async throws -> PlanProposal
}

extension CharacterModel {
    var visionEnabled: Bool { false }

    func plan(brief: String, observation: WorldObservation, vision: VisionCall?, planID: UUID) async throws -> PlanProposal {
        throw ModelAPIError.plannerUnavailable
    }
}

struct ChatCompletionsModel: CharacterModel {
    private struct ImageAttachment {
        let messageIndex: Int
        let vision: VisionCall
        let frame: VisionFrame
    }

    private let endpoint: URL
    private let model: String
    private let apiKey: String?
    private let redaction: APIKeyRedaction
    private let taskGoal: String
    private let reasoningEffort: String?
    private let streaming: Bool
    private let session: URLSession
    private let debugger: APIDebugger?
    let visionEnabled: Bool

    init(
        endpoint: URL, model: String, apiKey: String?, taskGoal: String,
        reasoningEffort: String? = nil, streaming: Bool = true, visionEnabled: Bool = false,
        session: URLSession? = nil, debugger: APIDebugger? = nil
    ) {
        self.endpoint = endpoint
        self.model = model
        self.apiKey = apiKey
        self.redaction = APIKeyRedaction(apiKey)
        self.taskGoal = taskGoal
        self.reasoningEffort = reasoningEffort
        self.streaming = streaming
        self.visionEnabled = visionEnabled
        self.session = session ?? (streaming ? Self.streamingSession : Self.nonStreamingSession)
        self.debugger = debugger
    }

    func chooseTools(_ turn: ModelTurn) async throws -> [ToolCall] {
        var correction: String?
        for attempt in 0...2 {
            let (data, exchangeID) = try await request(turn, correction: correction)
            do {
                return try decodeCalls(data, exchangeID: exchangeID)
            } catch ModelAPIError.textInsteadOfTool(let draft) {
                guard attempt < 2 else { throw ModelAPIError.noToolCall("stop") }
                let feedback = attempt == 0
                    ? "The engine received only a draft. No action ran and the player did not receive it."
                    : "The retry also returned only text. This is the last attempt. Send a function tool call now."
                correction = """
                    \(feedback)
                    Check the goal against the latest observation and receipts. If complete, call act once with these arguments:
                    {"actions":[{"action":"say","text":"<your completion message to the player>"},{"action":"finish"}]}
                    Use your draft for the say text if accurate. If work remains, call the appropriate next tool instead.
                    Leave assistant content empty. Printing the arguments as chat text does not execute them.
                    Previous unsent draft:
                    \(draft.prefix(2000))
                    """
            }
        }
        throw ModelAPIError.noToolCall("stop")
    }

    func plan(brief: String, observation: WorldObservation, vision: VisionCall?, planID: UUID) async throws -> PlanProposal {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let prompt = await debugger?.prompt ?? ""
        let input = try encoder.jsonString(PlanningTurn(
            goal: taskGoal, brief: brief, observation: observation, instructions: prompt.isEmpty ? nil : prompt
        ))
        var messages = [
            ChatMessage(role: instructionRole, content: Self.planningRules),
            ChatMessage(role: "user", content: input),
        ]
        var attachments: [ImageAttachment] = []
        if visionEnabled, let vision, let frame = vision.frame {
            messages[1].imageURL = "data:image/png;base64," + frame.png.base64EncodedString()
            attachments.append(ImageAttachment(messageIndex: 1, vision: vision, frame: frame))
        }
        let body = ChatRequest(
            model: model, messages: messages, tools: nil, toolChoice: nil,
            reasoningEffort: reasoningEffort == "none" ? fastReasoningEffort : reasoningEffort,
            stream: streaming ? true : nil,
            toolStream: nil, parallelToolCalls: nil, store: isZhipu ? nil : false,
            responseFormat: supportsJSONMode ? .jsonObject : nil
        )
        let (data, _) = try await send(body, attachments: attachments, brain: .slow, planID: planID)
        let decoder = JSONDecoder()
        guard let response = try? decoder.decode(ChatResponse.self, from: data),
              let choice = response.choices.first,
              choice.finishReason == "stop", choice.message.toolCalls?.isEmpty != false,
              let content = choice.message.content,
              let proposal = try? decoder.decode(PlanProposal.self, from: Data(content.utf8)) else {
            throw ModelAPIError.invalidPlanResponse
        }
        return proposal
    }

    private func decodeCalls(_ data: Data, exchangeID: UUID?) throws -> [ToolCall] {
        guard let response = try? JSONDecoder().decode(ChatResponse.self, from: data),
              let choice = response.choices.first else {
            throw ModelAPIError.invalidResponse
        }
        let message = choice.message
        let calls = message.toolCalls ?? []
        guard !calls.isEmpty else {
            if choice.finishReason == "stop", let content = message.content,
               !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ModelAPIError.textInsteadOfTool(content)
            }
            throw ModelAPIError.noToolCall(choice.finishReason.map(redacted))
        }
        guard calls.allSatisfy({ !$0.id.isEmpty }) else { throw ModelAPIError.missingToolCallID }
        guard Set(calls.map(\.id)).count == calls.count else { throw ModelAPIError.duplicateToolCallID }
        return calls.map { call in
            var call = call
            call.reasoningContent = message.reasoningContent
            call.debugExchangeID = exchangeID
            return call
        }
    }

    private func request(_ turn: ModelTurn, correction: String?) async throws -> (Data, UUID?) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let prompt = await debugger?.prompt ?? ""
        let observation: WorldObservation?
        let context: ModelContext?
        var images: [(vision: VisionCall, callID: String?)] = []
        var history: [ChatMessage] = []
        switch turn {
        case .initial(let initialObservation, let openingScan, let modelContext):
            observation = initialObservation
            context = modelContext
            if let openingScan { images.append((openingScan, nil)) }
        case .result(let replies, let modelContext):
            observation = nil
            context = modelContext
            history.append(ChatMessage(
                role: "assistant",
                toolCalls: replies.map(\.call), reasoningContent: replies.first?.call.reasoningContent
            ))
            for (index, reply) in replies.enumerated() {
                var receipt = reply.receipt
                if index == replies.count - 1 { receipt.context = modelContext }
                history.append(ChatMessage(
                    role: "tool", content: try encoder.jsonString(receipt), toolCallID: reply.call.id
                ))
                if let vision = reply.vision { images.append((vision, reply.call.id)) }
            }
        }
        let frames = images.compactMap { image -> (vision: VisionCall, callID: String?, frame: VisionFrame)? in
            guard visionEnabled, correction == nil, let frame = image.vision.frame else { return nil }
            return (image.vision, image.callID, frame)
        }
        let userContent = try encoder.jsonString(PlayerTurn(
            goal: taskGoal, observation: observation, instructions: prompt.isEmpty ? nil : prompt,
            context: history.isEmpty ? context : nil
        ))
        let visionRules = visionEnabled ? Self.visionRules : ""
        var messages = [
            ChatMessage(role: instructionRole, content: Self.rules + visionRules),
            ChatMessage(role: "user", content: userContent),
        ] + history
        var attachments: [ImageAttachment] = []
        for image in frames {
            let imageURL = "data:image/png;base64," + image.frame.png.base64EncodedString()
            if let callID = image.callID {
                // Keep all tool receipts together, then identify each attached map by its call ID.
                attachments.append(ImageAttachment(messageIndex: messages.count, vision: image.vision, frame: image.frame))
                messages.append(ChatMessage(
                    role: "user", content: "Agent Gridfield map for vision tool call \(callID).",
                    imageURL: imageURL
                ))
            } else {
                attachments.append(ImageAttachment(messageIndex: 1, vision: image.vision, frame: image.frame))
                messages[1].imageURL = imageURL
            }
        }

        if let correction { messages.append(ChatMessage(role: "user", content: correction)) }

        let toolStream = streaming && ModelSettings.isGLMFlash(host: endpoint.host, model: model)
        let tools = visionEnabled ? Self.tools + [.vision] : Self.tools
        let body = ChatRequest(model: model, messages: messages, tools: tools, toolChoice: "auto",
                               reasoningEffort: fastReasoningEffort, stream: streaming ? true : nil,
                               toolStream: toolStream ? true : nil,
                               parallelToolCalls: isZhipu ? nil : true, store: isZhipu ? nil : false,
                               responseFormat: nil)
        return try await send(body, attachments: attachments, brain: .fast, wakeReason: context?.wakeReason.rawValue)
    }

    private func send(_ body: ChatRequest, attachments: [ImageAttachment], brain: APIExchange.Brain,
                      planID: UUID? = nil, wakeReason: String? = nil) async throws -> (Data, UUID?) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if streaming { request.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept") }
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let payload = try encoder.encode(body)
        request.httpBody = payload

        let exchangeID: UUID?
        if let debugger {
            var debugBody = body
            for attachment in attachments {
                let frame = attachment.frame
                debugBody.messages[attachment.messageIndex].imageURL = "[PNG \(frame.width)×\(frame.height), \(frame.png.count) bytes]"
            }
            let loggedPayload = attachments.isEmpty ? payload : try encoder.encode(debugBody)
            let exchange = APIExchange(
                method: "POST",
                address: redacted(endpoint.absoluteString),
                requestHeaders: debugHeaders(request.allHTTPHeaderFields ?? [:]),
                requestBody: redacted(String(decoding: loggedPayload, as: UTF8.self)), brain: brain, planID: planID,
                visionID: attachments.first?.vision.id,
                additionalVisionIDs: attachments.count > 1 ? attachments.dropFirst().map(\.vision.id) : nil,
                wakeReason: wakeReason
            )
            try await debugger.record(exchange, apiKey: apiKey)
            exchangeID = exchange.id
        } else {
            exchangeID = nil
        }

        let data: Data
        let response: HTTPURLResponse
        do {
            try Task.checkCancellation()
            for attachment in attachments { await attachment.vision.update(.sending) }
            try Task.checkCancellation()
            (data, response) = try await receive(request, exchangeID: exchangeID)
        } catch {
            let cancelled = Task.isCancelled || (error as? URLError)?.code == .cancelled
            for attachment in attachments { await attachment.vision.update(cancelled ? .cancelled : .failed) }
            if let debugger, let exchangeID {
                await debugger.finish(exchangeID, with: cancelled ? .cancelled : .failed(message: redacted(error.localizedDescription)))
            }
            throw error
        }
        let succeeded = (200..<300).contains(response.statusCode)
        for attachment in attachments { await attachment.vision.update(succeeded ? .sent : .rejected(response.statusCode)) }
        if let debugger, let exchangeID {
            await debugger.finish(exchangeID, with: .response(
                status: response.statusCode,
                headers: debugHeaders(response.allHeaderFields),
                body: redacted(String(decoding: data, as: UTF8.self))
            ))
        }
        guard succeeded else {
            let detail = (try? JSONDecoder().decode(APIErrorResponse.self, from: data))?.error.message
            let summary = detail.map {
                String(redacted($0).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(420))
            }
            throw ModelAPIError.httpStatus(response.statusCode, summary)
        }
        return (data, exchangeID)
    }

    private func receive(_ request: URLRequest, exchangeID: UUID?) async throws -> (Data, HTTPURLResponse) {
        if !streaming {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ModelAPIError.invalidResponse }
            return (data, http)
        }

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ModelAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode), http.mimeType == "text/event-stream" else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            return (data, http)
        }

        var stream = ChatStream()
        let clock = ContinuousClock()
        var lastUpdate = clock.now
        var lastPhase: String?
        if let debugger, let exchangeID {
            await debugger.finish(exchangeID, with: .receiving(
                status: http.statusCode, phase: "Waiting for content", preview: ""
            ))
        }
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let event = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if event == "[DONE]" { break }
            guard !event.isEmpty else { continue }
            try stream.append(Data(event.utf8))
            let phase = stream.phase
            if let debugger, let exchangeID, phase != lastPhase || lastUpdate.duration(to: clock.now) >= .milliseconds(200) {
                await debugger.finish(exchangeID, with: .receiving(
                    status: http.statusCode, phase: phase, preview: redacted(stream.preview)
                ))
                lastPhase = phase
                lastUpdate = clock.now
            }
        }
        try Task.checkCancellation()
        return (try stream.responseData(), http)
    }

    private func debugHeaders<Key: Hashable>(_ headers: [Key: Any]) -> String {
        headers.compactMap { key, value -> String? in
            let name = String(describing: key)
            let lower = name.lowercased()
            guard !["authorization", "proxy-authorization", "cookie", "set-cookie"].contains(lower),
                  !lower.contains("api-key"), lower != "token", !lower.hasSuffix("-token") else { return nil }
            return "\(name): \(redacted(String(describing: value)))"
        }
        .sorted()
        .joined(separator: "\n")
    }

    private func redacted(_ text: String) -> String {
        redaction.redact(text)
    }

    private var instructionRole: String { endpoint.host == "api.openai.com" ? "developer" : "system" }
    private var isZhipu: Bool { ModelSettings.isZhipuHost(endpoint.host) }
    private var supportsJSONMode: Bool { endpoint.host == "api.openai.com" || endpoint.host == "api.deepseek.com" }

    private var fastReasoningEffort: String? {
        if ModelSettings.isGLMFlash(host: endpoint.host, model: model) { return "low" }
        if endpoint.host == "api.openai.com" {
            let originalGPT5 = ["gpt-5", "gpt-5-mini", "gpt-5-nano"]
            if originalGPT5.contains(model) || originalGPT5.contains(where: { model == "\($0)-2025-08-07" }) {
                return "minimal"
            }
            if model.hasPrefix("gpt-4") || model.hasPrefix("gpt-3.5") || model.hasPrefix("chatgpt-4o") { return nil }
            if model.hasPrefix("o3") || model.hasPrefix("o4-mini") { return "low" }
        }
        return "none"
    }

    private static let streamingSession = networkSession(resourceTimeout: 30 * 60)
    private static let nonStreamingSession = networkSession(resourceTimeout: 180)

    private static func networkSession(resourceTimeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = resourceTimeout
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    private static let rules = """
        You are the fast brain and control the avatar in Agent Gridfield. The player supplies goal and optional instructions.

        [Observation]
        source = user.observation initially, latest tool receipt.observation thereafter
        ground, above = full map layers; array index is y; each row uses space-separated x=ID or start..end=ID
        ranges include both ends and cover every x exactly once, including grass and air
        e.g. y=4 ground "0=gr 1..7=wa 8..16=gr": at [12,4] the ground is grass
        legend = {ID: block_type}; air = empty upper cell
        use absolute x within row y; origin = northwest [0,0]; +x east; +y south
        avatar = [x,y]
        inventory = {item: count}; missing item = 0
        items[] = [x,y,item,count]; loose and attached items are counted together; omitted = []
        block_state = additional block conditions when present
        Live context is in the opening user message or the last tool receipt. context.worldTick is the current engine tick at 8 Hz and context.wakeReason explains why this decision is requested.
        context.activePlan gives {planID, brief} while the planner is running.
        context.recentMessages lists up to three chat messages as {sender, text}, oldest first. Check them before acknowledging the player.

        [Memory]
        Each request includes the goal and current world observation. Subsequent requests include the immediately preceding calls, their receipts in call order, and the preceding reasoning when available.
        The notebook and memory entries persist across stop and restart in the same world. The notebook text is in every observation; saved entries are in tool receipts at memory.entries.
        memory accepts optional text (replace the notebook, empty string clears it), set (entry ID to text), and remove (entry IDs).
        Entry IDs are nonblank strings. An ID can appear in either set or remove per call. All changes apply together.
        Notebook text is limited to \(MemoryReceipt.notebookByteLimit) UTF-8 bytes; saved IDs and entry text share a separate \(MemoryReceipt.byteLimit)-byte limit.
        memory({}) returns saved entries and the current observation. recentHistory contains up to four earlier batches of processed actions. History count groups identical adjacent actions.
        Historical blueprint events include placementCount and inclusive bounds [[minX,minY],[maxX,maxY]]. A successful applied proposal also includes planSummary.

        [Actions]
        act accepts a nonempty ordered actions array.
        action          | fields besides action
        build_blueprint | placements (nonempty array of {x,y,structure})
        apply_plan      | planID (from context.pendingPlan)
        wait_for_plan   | none
        acquire         | item, count (desired inventory total)
        walk_to         | x, y (integers)
        move            | direction
        collect_at      | x, y, target (target=item requires item and allows count)
        collect         | direction, target (same item and count rules as collect_at)
        place_at        | x, y, structure, optional stand
        place           | direction, structure
        craft           | item (recipe name), optional count
        drop            | direction, item
        say             | text
        finish          | none

        [Background planning]
        request_plan accepts a concise brief and optional include_vision (default false, available when vision is enabled).
        The planner already receives the goal, player instructions, and observation. Write only design intent and style in brief. Leave site selection and all coordinates to the planner.
        Request a plan for complex layouts and multi-room designs. If context.planningSuggested is true after repeated failures, prioritize requesting a plan instead of retrying the same intent.
        When requesting a plan at the start or after player_input, pair request_plan with a short act say in the same response so the player hears from you right away. Save longer notes for later if useful.
        plan_requested means the planner has started in the background. A new request replaces the previous one.
        The engine automatically gathers and crafts blueprint materials. While context.activePlan covers the goal, call wait_for_plan unless another short action has a clear benefit for the player’s goal. Skip speculative gathering. Use wait_for_plan as the last action in its batch only while a plan is in progress.
        A planner result wakes you if you are waiting. On plan_ready, inspect context.pendingPlan for planID, createdTick, summary, placementCount and bounds. Choose apply_plan if the proposal fits the goal. context.planFailure describes a failed request.
        Use apply_plan with the supplied planID to build the proposal. The engine consumes the proposal when the action starts and validates every saved placement against the current world. plan_unavailable means the ID is unavailable. You can ignore a proposal or replace it with a new request.
        A built receipt with appliedPlan confirms that every placement in the saved design is present. Use appliedPlan.summary and the latest observation to check the player's requirements, then close the run when they are met.

        [Blueprints and inventory targets]
        build_blueprint accepts final placement positions in any order. Specify each desired wall cell as structure=wall. Walls join at orthogonally adjacent walls and form corners automatically. Other structure values are floor and grass_bed.
        The engine clears trees and bushes on the footprint, opens access through trees when necessary, gathers or crafts missing materials, and chooses placement order and reachable stands to avoid trapping the avatar. Multiple buildings can share one blueprint. Choose their layout using the observation.
        A floor and a grass bed can share a tile. Walls require bare ground. Existing matching structures count as placed. Water and conflicting structures block a placement.
        acquire takes a positive count and counts items already carried toward that total. The engine finds reachable resources and uses recipes as needed. Recipe yields can leave extra items.
        build_blueprint, apply_plan and acquire plan against the current world. The engine executes individual steps on world ticks. Success yields built or acquired. An infeasible plan leaves the world as it was before that action.
        receipt.plans lists {index, steps, failure?} for plan actions. steps counts executed steps. index is the zero-based action index. failure contains reason and may include position [x,y], item, needed and available.

        [Direct actions]
        direction = north | south | east | west
        direction target = one cell from the current avatar; out-of-bounds targets fail
        move = step into target; water, trees, walls and corners block movement
        walk_to = follow the shortest four-direction route to the exact [x,y] cell using the same movement rules
        collect_at and place_at walk to the nearest reachable neighboring cell and perform the action. place_at can specify an exact stand as [x,y], orthogonally adjacent to the target.
        a coordinate action that fails validation before moving leaves the avatar in place
        walk_to results: arrived (including zero steps), boundary (outside the map), unreachable (no route)
        drop = transfer 1 item from inventory to target
        For collect, collect_at and craft, count is a positive integer and defaults to 1. If there are too few items or ingredients, the action fails without transferring or crafting any.

        [Collect]
        target | selection    | effect
        item   | item name    | take loose items before attached items and add count to inventory
        above  | tree         | clear tree and its attached branches; drop \(World.logsPerTree) logs in place
        above  | bush         | clear bush; add 1 grass to inventory
        above  | grass_bed    | clear bed; add 1 grass_bed to inventory
        above  | wall, corner | clear structure; add 1 plank to inventory
        ground | floor        | restore grass under the upper cell; add 1 plank to inventory
        collect requires a matching item or collectible block

        [Craft]
        count is the number of times to run the recipe. The table gives ingredient and output quantities per recipe run.
        recipe | consume from inventory -> add to inventory
        \(recipeRules)

        [Placement]
        structure     | required ground  | required above | consume
        floor         | grass            | air or grass_bed | 1 plank
        grass_bed     | grass or floor   | air            | 1 grass_bed
        walls/corners | grass            | air            | 1 plank

        [Turn]
        return one or more available tool calls and leave assistant content empty
        calls execute in the order returned, against the state left by earlier calls
        the next request arrives after the calls settle and includes one receipt per call unless finish ends the run first
        action batches stop at the first failure or finish; earlier effects persist
        a player interruption returns interrupted, preserves executed steps, and skips pending actions and calls from that decision
        receipt = results (outcomes in order), skipped (count), observation (actual state when the call settled)
        receipt.walks, when present, gives {index, destination: [x,y], steps}; index is zero-based and steps counts cells actually traversed
        say = display nonempty text in game chat
        Once the goal is met, call act once with say (your completion message) followed by finish in the same actions array. A plain-text reply reaches neither the player nor the engine.
        finish = end the current run
        """

    private static let planningRules = """
        Design a construction blueprint for Agent Gridfield using the current observation, player goal and planning brief. An optional map image shows the same observation.

        ground and above are full map layers. The zero-based array index is y. Each row uses space-separated x=ID or start..end=ID ranges with inclusive endpoints. legend maps IDs to block types. [0,0] is the northwest tile, +x is east, and +y is south. avatar is [x,y]. Use absolute coordinates.

        Select final tiles within the map. Water and conflicting existing structures block placement. The engine can clear trees and bushes and gather or craft materials. A wall needs bare ground. A floor and a grass bed can share a tile. Matching existing structures already count as placed. Orthogonally adjacent wall tiles join and form corners automatically. Leave entrances and accessible approaches when the design calls for usable rooms. Use each intended placement once.

        Return exactly one JSON object with two fields. summary is a short descriptive string. placements is a nonempty array of objects containing exactly integer x, integer y and structure, one of wall, floor or grass_bed. Return JSON without Markdown or surrounding text.
        """

    private static let visionRules = """


        [Vision]
        The first request includes an opening map when available. It depicts the initial text observation.
        vision({}) supplies one coordinate-labeled image of receipt.observation in the next model request.
        Each image is available only in the request that contains it. Each successful vision tool call supplies one image input identified by its tool call ID.
        The x labels are columns and the y labels are rows. [0,0] is the upper-left cell.
        """

    private static var recipeRules: String {
        Recipe.allCases.map { recipe in
            let ingredients = recipe.ingredients.sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.value) \($0.key.rawValue)" }.joined(separator: " + ")
            let output = recipe.output
            return "\(recipe.rawValue) | \(ingredients) -> \(output.count) \(output.item.rawValue)"
        }.joined(separator: "\n")
    }

    private static let tools: [ToolDefinition] = [.act, .memory, .requestPlan]
}

private struct PlayerTurn: Encodable {
    let goal: String
    let observation: WorldObservation?
    let instructions: String?
    let context: ModelContext?
}

private struct PlanningTurn: Encodable {
    let goal: String
    let brief: String
    let observation: WorldObservation
    let instructions: String?
}

private struct ChatRequest: Encodable {
    struct ResponseFormat: Encodable {
        let type: String

        static let jsonObject = Self(type: "json_object")
    }

    let model: String
    var messages: [ChatMessage]
    let tools: [ToolDefinition]?
    let toolChoice: String?
    let reasoningEffort: String?
    let stream: Bool?
    let toolStream: Bool?
    let parallelToolCalls: Bool?
    let store: Bool?
    let responseFormat: ResponseFormat?

    enum CodingKeys: String, CodingKey {
        case model, messages, tools, store, stream
        case reasoningEffort = "reasoning_effort"
        case toolChoice = "tool_choice"
        case toolStream = "tool_stream"
        case parallelToolCalls = "parallel_tool_calls"
        case responseFormat = "response_format"
    }
}

private struct ChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
            let toolCalls: [ToolCall]?
            let reasoningContent: String?

            enum CodingKeys: String, CodingKey {
                case content
                case toolCalls = "tool_calls"
                case reasoningContent = "reasoning_content"
            }
        }

        let message: Message
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }

    let choices: [Choice]
}

private struct ChatMessage: Encodable {
    private struct ContentPart: Encodable {
        struct ImageURL: Encodable {
            let url: String
        }

        let type: String
        var text: String?
        var imageURL: ImageURL?

        enum CodingKeys: String, CodingKey {
            case type, text
            case imageURL = "image_url"
        }
    }

    let role: String
    var content: String?
    var toolCalls: [ToolCall]?
    var toolCallID: String?
    var reasoningContent: String?
    var imageURL: String?

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
        case reasoningContent = "reasoning_content"
    }

    func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(role, forKey: .role)
        if let imageURL {
            let parts = [
                ContentPart(type: "text", text: content),
                ContentPart(type: "image_url", imageURL: .init(url: imageURL)),
            ]
            try fields.encode(parts, forKey: .content)
        } else {
            try fields.encodeIfPresent(content, forKey: .content)
        }
        try fields.encodeIfPresent(toolCalls, forKey: .toolCalls)
        try fields.encodeIfPresent(toolCallID, forKey: .toolCallID)
        try fields.encodeIfPresent(reasoningContent, forKey: .reasoningContent)
    }
}

private struct ToolDefinition: Encodable, Sendable {
    let type = "function"
    let function: Function

    struct Function: Encodable, Sendable {
        let name: String
        let description: String
        let parameters: Parameter
    }

    private init(_ tool: CharacterTool, description: String, properties: [String: Parameter], required: [String]? = nil) {
        function = Function(name: tool.rawValue, description: description,
                            parameters: .init(type: "object", properties: properties,
                                              required: required, additionalProperties: false))
    }

    static let act = ToolDefinition(
        .act, description: "Execute physical actions in Agent Gridfield, including building a blueprint and acquiring an inventory target.",
        properties: ["actions": .init(type: "array", items: action, minItems: 1)],
        required: ["actions"]
    )
    static let memory = ToolDefinition(
        .memory, description: "Read or update the notebook and persistent memory entries for this world.",
        properties: [
            "text": .init(description: "Replace the whole notebook. Empty text clears it."),
            "set": .init(type: "object", description: "Entry IDs mapped to new text.", valueType: .init()),
            "remove": .init(type: "array", items: .init(), description: "Entry IDs to delete."),
        ]
    )
    static let vision = ToolDefinition(
        .vision, description: "Request one coordinate-labeled image of the current Agent Gridfield map. "
            + "The image arrives on your next turn. Coordinates match those used by act.",
        properties: [:]
    )
    static let requestPlan = ToolDefinition(
        .requestPlan, description: "Start a background construction plan and return immediately.",
        properties: [
            "brief": .init(description: "Design intent and style only. The planner chooses the site and coordinates."),
            "include_vision": .init(type: "boolean", description: "Attach the current map image if vision is enabled. Defaults to false."),
        ],
        required: ["brief"]
    )

    private static let stand = Parameter(type: "array", items: .init(type: "integer"),
                                         description: "Exact [x,y] tile orthogonally adjacent to the target.",
                                         minItems: 2, maxItems: 2)

    private static let action = Parameter(type: "object", properties: [
        "action": .init(values: CharacterActionName.allCases.map(\.rawValue)),
        "direction": .init(values: Direction.allCases.map(\.rawValue)),
        "x": .init(type: "integer"),
        "y": .init(type: "integer"),
        "target": .init(values: CollectTarget.Kind.allCases.map(\.rawValue)),
        "item": .init(values: Item.allCases.map(\.rawValue)),
        "structure": .init(values: Structure.allCases.map(\.rawValue)),
        "stand": stand,
        "count": .init(type: "integer", description: "Required desired inventory total for acquire. For craft and item collection, quantity to process, defaulting to 1.", minimum: 1),
        "text": .init(),
        "planID": .init(description: "Required for apply_plan. Copy the ID from context.pendingPlan."),
        "placements": .init(type: "array", items: placement,
                            description: "Required for build_blueprint. Final tiles in any order.", minItems: 1),
    ], required: ["action"], additionalProperties: false)

    private static let placement = Parameter(type: "object", properties: [
        "x": .init(type: "integer"),
        "y": .init(type: "integer"),
        "structure": .init(values: [Structure.wall, .floor, .grassBed].map(\.rawValue),
                           description: "Wall edges join automatically."),
    ], required: ["x", "y", "structure"], additionalProperties: false)

    enum AdditionalProperties: Encodable, Sendable {
        case allowed(Bool)
        case schema(Parameter)

        func encode(to encoder: any Encoder) throws {
            var value = encoder.singleValueContainer()
            switch self {
            case .allowed(let allowed): try value.encode(allowed)
            case .schema(let schema): try value.encode(schema)
            }
        }
    }

    final class Parameter: Encodable, Sendable {
        let type: String
        let values: [String]?
        let properties: [String: Parameter]?
        let items: Parameter?
        let required: [String]?
        let additionalProperties: AdditionalProperties?
        let description: String?
        let minItems: Int?
        let maxItems: Int?
        let minimum: Int?

        init(type: String = "string", values: [String]? = nil, properties: [String: Parameter]? = nil,
             items: Parameter? = nil, required: [String]? = nil, additionalProperties: Bool? = nil,
             description: String? = nil, valueType: Parameter? = nil, minItems: Int? = nil, maxItems: Int? = nil,
             minimum: Int? = nil) {
            self.type = type
            self.values = values
            self.properties = properties
            self.items = items
            self.required = required
            self.additionalProperties = valueType.map(AdditionalProperties.schema)
                ?? additionalProperties.map(AdditionalProperties.allowed)
            self.description = description
            self.minItems = minItems
            self.maxItems = maxItems
            self.minimum = minimum
        }

        enum CodingKeys: String, CodingKey {
            case type, properties, items, required, additionalProperties, description, minItems, maxItems, minimum
            case values = "enum"
        }
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private struct APIErrorResponse: Decodable {
    struct Detail: Decodable {
        let message: String
    }
    let error: Detail
}

enum ModelAPIError: LocalizedError {
    case httpStatus(Int, String?)
    case invalidResponse
    case incompleteStream
    case noToolCall(String?)
    case textInsteadOfTool(String)
    case duplicateToolCallID
    case missingToolCallID
    case plannerUnavailable
    case invalidPlanResponse

    var errorDescription: String? {
        switch self {
        case .httpStatus(401, _), .httpStatus(403, _):
            "The API denied access. Check your API key and model permissions."
        case .httpStatus(404, _):
            "The API endpoint or model could not be found. Check your model settings."
        case .httpStatus(429, _):
            "The API rate limit or usage quota was reached."
        case .httpStatus(let status, let detail?) where !detail.isEmpty:
            "The API returned HTTP \(status).\n\(detail)"
        case .httpStatus(let status, _):
            "The API returned HTTP \(status). Check the API endpoint and whether the model supports tool calls."
        case .invalidResponse:
            "Could not read the API response. See Developer Tools for details."
        case .incompleteStream:
            "The stream ended before the response was complete. See Developer Tools for details."
        case .noToolCall(let reason?):
            "The model did not call a tool. It finished with \(String(reason.prefix(60))). See Developer Tools for details."
        case .noToolCall, .textInsteadOfTool:
            "The model did not call a tool. See Developer Tools for the response."
        case .duplicateToolCallID:
            "The model reused a tool call ID in one response. See Developer Tools for details."
        case .missingToolCallID:
            "The tool call is missing an ID. See Developer Tools for the response."
        case .plannerUnavailable:
            "Background planning is unavailable for this model."
        case .invalidPlanResponse:
            "The planner did not return a valid blueprint. See Developer Tools for the response."
        }
    }
}

private extension JSONEncoder {
    func jsonString(_ value: some Encodable) throws -> String {
        String(decoding: try encode(value), as: UTF8.self)
    }
}
