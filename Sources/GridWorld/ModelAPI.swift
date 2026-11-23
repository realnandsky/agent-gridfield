import Foundation

enum CharacterTool: String, Sendable {
    case act, memory, query, vision
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
    case initial(WorldObservation, vision: VisionCall? = nil)
    case result([ToolReply])
}

protocol CharacterModel: Sendable {
    var visionEnabled: Bool { get }
    func chooseTools(_ turn: ModelTurn) async throws -> [ToolCall]
}

extension CharacterModel {
    var visionEnabled: Bool { false }
}

struct ChatCompletionsModel: CharacterModel {
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
        let first = try await request(turn)
        do {
            return try decodeCalls(first.0, exchangeID: first.1)
        } catch ModelAPIError.textInsteadOfTool {
            let retry = try await request(turn, retryingTextResponse: true)
            do {
                return try decodeCalls(retry.0, exchangeID: retry.1)
            } catch ModelAPIError.textInsteadOfTool {
                throw ModelAPIError.noToolCall("stop")
            }
        }
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
                throw ModelAPIError.textInsteadOfTool
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

    private func request(_ turn: ModelTurn, retryingTextResponse: Bool = false) async throws -> (Data, UUID?) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let prompt = await debugger?.prompt ?? ""
        let instructionRole = endpoint.host == "api.openai.com" ? "developer" : "system"
        let observation: WorldObservation?
        var images: [(vision: VisionCall, callID: String?)] = []
        var history: [ChatMessage] = []
        switch turn {
        case .initial(let initialObservation, let openingScan):
            observation = initialObservation
            if let openingScan { images.append((openingScan, nil)) }
        case .result(let replies):
            observation = nil
            history.append(ChatMessage(
                role: "assistant",
                toolCalls: replies.map(\.call), reasoningContent: replies.first?.call.reasoningContent
            ))
            for reply in replies {
                history.append(ChatMessage(
                    role: "tool", content: try encoder.jsonString(reply.receipt), toolCallID: reply.call.id
                ))
                if let vision = reply.vision { images.append((vision, reply.call.id)) }
            }
        }
        let frames = images.compactMap { image -> (vision: VisionCall, callID: String?, frame: VisionFrame)? in
            guard visionEnabled, !retryingTextResponse, let frame = image.vision.frame else { return nil }
            return (image.vision, image.callID, frame)
        }
        let userContent = try encoder.jsonString(PlayerTurn(
            goal: taskGoal, observation: observation, instructions: prompt.isEmpty ? nil : prompt
        ))
        let retryReminder = retryingTextResponse
            ? "\nYour previous response used plain text without a tool call. Submit at least one tool call now. Use act's say to speak and act's finish to end the run."
            : ""
        let visionRules = visionEnabled ? Self.visionRules : ""
        var messages = [
            ChatMessage(role: instructionRole, content: Self.rules + visionRules + retryReminder),
            ChatMessage(role: "user", content: userContent),
        ] + history
        var imageMessageIndices: [Int] = []
        for image in frames {
            let imageURL = "data:image/png;base64," + image.frame.png.base64EncodedString()
            if let callID = image.callID {
                // Keep all tool receipts together, then identify each attached map by its call ID.
                imageMessageIndices.append(messages.count)
                messages.append(ChatMessage(
                    role: "user", content: "Agent Gridfield map for vision tool call \(callID).",
                    imageURL: imageURL
                ))
            } else {
                imageMessageIndices.append(1)
                messages[1].imageURL = imageURL
            }
        }

        let isZhipu = ModelSettings.isZhipuHost(endpoint.host)
        let toolStream = streaming && ModelSettings.isGLMFlash(host: endpoint.host, model: model)
        let tools = visionEnabled ? Self.tools + [.vision] : Self.tools
        var body = ChatRequest(model: model, messages: messages, tools: tools, toolChoice: "auto",
                               reasoningEffort: reasoningEffort, stream: streaming ? true : nil,
                               toolStream: toolStream ? true : nil,
                               parallelToolCalls: isZhipu ? nil : true, store: isZhipu ? nil : false)
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
            for (index, image) in zip(imageMessageIndices, frames) {
                let frame = image.frame
                body.messages[index].imageURL = "[PNG \(frame.width)×\(frame.height), \(frame.png.count) bytes]"
            }
            let loggedPayload = frames.isEmpty ? payload : try encoder.encode(body)
            let exchange = APIExchange(
                method: "POST",
                address: redacted(endpoint.absoluteString),
                requestHeaders: debugHeaders(request.allHTTPHeaderFields ?? [:]),
                requestBody: redacted(String(decoding: loggedPayload, as: UTF8.self)), visionID: frames.first?.vision.id,
                additionalVisionIDs: frames.count > 1 ? frames.dropFirst().map(\.vision.id) : nil
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
            for image in frames { await image.vision.update(.sending) }
            try Task.checkCancellation()
            (data, response) = try await receive(request, exchangeID: exchangeID)
        } catch {
            let cancelled = Task.isCancelled || (error as? URLError)?.code == .cancelled
            for image in frames { await image.vision.update(cancelled ? .cancelled : .failed) }
            if let debugger, let exchangeID {
                await debugger.finish(exchangeID, with: cancelled ? .cancelled : .failed(message: redacted(error.localizedDescription)))
            }
            throw error
        }
        let succeeded = (200..<300).contains(response.statusCode)
        for image in frames { await image.vision.update(succeeded ? .sent : .rejected(response.statusCode)) }
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

    private static let streamingSession = networkSession(resourceTimeout: 30 * 60)
    private static let nonStreamingSession = networkSession(resourceTimeout: 180)

    private static func networkSession(resourceTimeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = resourceTimeout
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    private static let rules = """
        You control the avatar in Agent Gridfield. The player supplies goal and optional instructions.

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

        [Memory]
        Each request includes the goal and current world observation. Subsequent requests include the immediately preceding calls, their receipts in call order, and the preceding reasoning when available.
        The notebook and memory entries persist across stop and restart in the same world. The notebook text is in every observation; saved entries are in tool receipts at memory.entries.
        memory accepts optional text (replace the notebook, empty string clears it), set (entry ID to text), and remove (entry IDs).
        Entry IDs are nonblank strings. An ID can appear in either set or remove per call. All changes apply together.
        Notebook text is limited to \(MemoryReceipt.notebookByteLimit) UTF-8 bytes; saved IDs and entry text share a separate \(MemoryReceipt.byteLimit)-byte limit.
        memory({}) returns saved entries and the current observation. recentHistory contains up to four earlier batches of processed actions and queries.
        Historical preview_build events include placementCount and bounds [[minX,minY],[maxX,maxY]] of all proposed placements. History count groups identical adjacent actions.

        [Actions]
        act accepts a nonempty ordered actions array.
        action     | fields besides action
        move       | direction
        walk_to    | x, y (integers)
        collect    | direction, target (target=item requires item and allows count)
        collect_at | x, y, target (same item and count rules as collect)
        place_at   | x, y, structure, optional stand
        drop       | direction, item
        craft      | item (recipe name), optional count
        place      | direction, structure (full type name from legend)
        say        | text
        finish    | none

        direction = north | south | east | west
        direction target = one cell from the current avatar; out-of-bounds targets fail
        move = step into target; water, trees, walls and corners block movement
        walk_to = follow the shortest four-direction route to the exact [x,y] cell using the same movement rules
        collect_at and place_at walk to the nearest reachable neighboring cell and perform the action. place_at can specify an exact stand, using the same rules as preview_build
        failed coordinate actions leave the avatar in place
        walk_to results: arrived (including zero steps), boundary (outside the map), unreachable (no route)
        drop = transfer 1 item from inventory to target
        count is a positive integer, defaults to 1, and applies to the entire action. If there are too few items or ingredients, the action fails without transferring or crafting any.

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

        [Build]
        structure     | required ground  | required above | consume
        floor         | grass            | air or grass_bed | 1 plank
        grass_bed     | grass or floor   | air            | 1 grass_bed
        walls/corners | grass            | air            | 1 plank
        wall suffix = arms extending from the center of its cell
        building corners by position: upper-left corner_se (east+south), upper-right corner_sw (south+west),
        lower-left corner_ne (north+east), lower-right corner_nw (north+west)

        [Queries]
        query accepts a nonempty queries array; each entry uses the query field to select an operation.
        Queries read the current world.
        query              | fields besides query
        find_resources     | resource, optional limit
        estimate_materials | counts (object: structure name -> quantity)
        preview_build     | placements (ordered array of {x,y,structure,stand?})
        find_build_sites  | width, height, optional limit and nonOverlapping
        query limit defaults to 3, range 1–10; coordinates and sizes are integers
        find_resources returns reachable candidates {position, stand, steps, count, target}, nearest first
        resource tree or bush uses target=above; tree count is logs dropped by felling; pick up logs separately
        other resources are collectible items; use target=item with item matching the resource
        estimate_materials returns required finished items, recommended craft batches, and missing raw ingredients after inventory
        preview_build checks the given placement order with hypothetical materials; returns materials, validLayout and the first failure {index, position, reason} if any
        stand is an optional exact [x,y] tile orthogonally adjacent to the placement target. Placement fails if the specified stand cannot be reached. If omitted, placement uses the nearest reachable stand.
        for an unreachable placement with a reachable stand at the start, failure.lostAccessAfter contains the zero-based index and [x,y] position of the earlier placement that cut access
        after successful simulation, preview.wallSeams lists one-sided connections between adjacent walls as {from, to, direction}; an empty array means none found
        find_build_sites ranks rectangular footprints by fewest cells to clear then shortest walk to a perimeter entrance
        nonOverlapping: true returns as many footprints as fit without sharing tiles, up to limit, with rank breaking ties
        each site has origin (top-left), entrance, stepsToEntrance (assuming entrance cleared), and clear (tree or bush coordinates)

        [Turn]
        return one or more available tool calls and leave assistant content empty
        calls execute in the order returned, against the state left by earlier calls
        the next request includes one receipt per call unless finish ends the run first
        action and query batches stop at the first failure or finish; earlier effects persist
        receipt = results (attempted outcomes in order), skipped (count), observation (final state)
        receipt.walks, when present, lists successful walks as {index, destination: [x,y], steps}; index is zero-based
        receipt.queries lists {index, resources|materials|preview|sites} for each query, corresponding result = inspected
        say = display nonempty text in game chat
        finish = end the current run
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

    private static let tools: [ToolDefinition] = [.act, .memory, .query]
}

private struct PlayerTurn: Encodable {
    let goal: String
    let observation: WorldObservation?
    let instructions: String?
}

private struct ChatRequest: Encodable {
    let model: String
    var messages: [ChatMessage]
    let tools: [ToolDefinition]
    let toolChoice: String
    let reasoningEffort: String?
    let stream: Bool?
    let toolStream: Bool?
    let parallelToolCalls: Bool?
    let store: Bool?

    enum CodingKeys: String, CodingKey {
        case model, messages, tools, store, stream
        case reasoningEffort = "reasoning_effort"
        case toolChoice = "tool_choice"
        case toolStream = "tool_stream"
        case parallelToolCalls = "parallel_tool_calls"
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
        .act, description: "Execute an ordered batch of actions in Agent Gridfield.",
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
    static let query = ToolDefinition(
        .query, description: "Inspect resources, materials, build sites or a proposed blueprint in the current world.",
        properties: ["queries": .init(type: "array", items: queryItem, minItems: 1)],
        required: ["queries"]
    )
    static let vision = ToolDefinition(
        .vision, description: "Request one coordinate-labeled image of the current Agent Gridfield map. "
            + "The image arrives on your next turn. Coordinates match those used by act.",
        properties: [:]
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
        "count": .init(type: "integer", description: "Recipe runs for craft or items to collect for target=item. Defaults to 1.", minimum: 1),
        "text": .init(),
    ], required: ["action"], additionalProperties: false)

    private static let queryItem = Parameter(type: "object", properties: [
        "query": .init(values: WorldQuery.Name.allCases.map(\.rawValue)),
        "resource": .init(values: ResourceKind.allCases.map(\.rawValue)),
        "limit": .init(type: "integer"),
        "width": .init(type: "integer"),
        "height": .init(type: "integer"),
        "nonOverlapping": .init(type: "boolean", description: "Select build sites that share no tiles."),
        "counts": .init(type: "object", properties: Dictionary(uniqueKeysWithValues:
            Structure.allCases.map { ($0.rawValue, Parameter(type: "integer")) }), additionalProperties: false),
        "placements": .init(type: "array", items: .init(type: "object", properties: [
            "x": .init(type: "integer"),
            "y": .init(type: "integer"),
            "structure": .init(values: Structure.allCases.map(\.rawValue)),
            "stand": stand,
        ], required: ["x", "y", "structure"], additionalProperties: false)),
    ], required: ["query"], additionalProperties: false)

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
    case textInsteadOfTool
    case duplicateToolCallID
    case missingToolCallID

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
        }
    }
}

private extension JSONEncoder {
    func jsonString(_ value: some Encodable) throws -> String {
        String(decoding: try encode(value), as: UTF8.self)
    }
}
