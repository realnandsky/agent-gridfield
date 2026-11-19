import Foundation

struct ChatStream {
    private struct Chunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                struct Call: Decodable {
                    struct Function: Decodable {
                        let name: String?
                        let arguments: String?
                    }

                    let index: Int
                    let id: String?
                    let type: String?
                    let function: Function?
                }

                let content: String?
                let reasoningContent: String?
                let toolCalls: [Call]?
            }

            let index: Int
            let delta: Delta?
            let finishReason: String?
        }

        let choices: [Choice]
    }

    private struct CallParts {
        var id: String?
        var type: String?
        var name: String?
        var arguments = ""
    }

    private var content = ""
    private var reasoning = ""
    private var calls: [Int: CallParts] = [:]
    private var finishReason: String?
    private var usage: [String: Any]?

    var phase: String {
        if !calls.isEmpty { return "Receiving tool call" }
        if !content.isEmpty { return "Receiving response" }
        if !reasoning.isEmpty { return "Planning" }
        return "Waiting for content"
    }

    var preview: String { String((content.isEmpty ? reasoning : content).suffix(2400)) }

    mutating func append(_ event: Data) throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let chunk = try? decoder.decode(Chunk.self, from: event) else {
            throw ModelAPIError.invalidResponse
        }
        if event.range(of: Data("\"usage\"".utf8)) != nil,
           let json = try JSONSerialization.jsonObject(with: event) as? [String: Any],
           let reportedUsage = json["usage"] as? [String: Any] {
            usage = reportedUsage
        }
        guard let choice = chunk.choices.first(where: { $0.index == 0 }) else { return }
        if let finish = choice.finishReason { finishReason = finish }
        guard let delta = choice.delta else { return }
        if let text = delta.content { content += text }
        if let text = delta.reasoningContent { reasoning += text }
        for call in delta.toolCalls ?? [] {
            var parts = calls[call.index, default: CallParts()]
            if let id = call.id, !id.isEmpty { parts.id = id }
            if let type = call.type, !type.isEmpty { parts.type = type }
            if let name = call.function?.name, !name.isEmpty { parts.name = name }
            if let arguments = call.function?.arguments { parts.arguments += arguments }
            calls[call.index] = parts
        }
    }

    func responseData() throws -> Data {
        guard let finishReason, ["stop", "tool_calls"].contains(finishReason) else {
            throw ModelAPIError.incompleteStream
        }
        var message: [String: Any] = ["role": "assistant", "content": content]
        if !reasoning.isEmpty { message["reasoning_content"] = reasoning }
        if !calls.isEmpty {
            message["tool_calls"] = try calls.sorted(by: { $0.key < $1.key }).map { _, parts in
                guard let id = parts.id, let type = parts.type, let name = parts.name else {
                    throw ModelAPIError.incompleteStream
                }
                return ["id": id, "type": type, "function": ["name": name, "arguments": parts.arguments]] as [String: Any]
            }
        }
        var response: [String: Any] = ["choices": [["message": message, "finish_reason": finishReason]]]
        if let usage { response["usage"] = usage }
        return try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
    }
}
