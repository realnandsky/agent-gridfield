import Foundation
import Observation

struct APIExchange: Identifiable, Encodable, Sendable {
    enum Brain: String, Encodable, Sendable {
        case fast, slow
    }

    enum Outcome: Encodable, Sendable {
        case waiting
        case receiving(status: Int, phase: String, preview: String)
        case response(status: Int, headers: String, body: String)
        case cancelled
        case failed(message: String)

        var label: String {
            switch self {
            case .waiting: "Waiting for response"
            case .receiving(_, let phase, _): phase
            case .response(let status, _, _): "HTTP \(status)"
            case .cancelled: "Canceled"
            case .failed: "Connection failed"
            }
        }

        var liveLabel: String? {
            switch self {
            case .waiting, .receiving: label
            default: nil
            }
        }
    }

    let id = UUID()
    let startedAt = Date()
    let method: String
    let address: String
    let requestHeaders: String
    let requestBody: String
    var brain: Brain = .fast
    var planID: UUID? = nil
    var visionID: UUID? = nil
    var additionalVisionIDs: [UUID]? = nil
    var wakeReason: String? = nil
    var summary: String? = nil
    var finishedAt: Date? = nil
    var outcome: Outcome = .waiting

    var isLive: Bool { outcome.liveLabel != nil }

    func duration(until now: Date = Date()) -> TimeInterval {
        max(0, (finishedAt ?? now).timeIntervalSince(startedAt))
    }

    var displaySummary: String {
        if let summary, !summary.isEmpty { return summary }
        if case .receiving = outcome { return outcome.label }
        if brain == .fast, let wakeReason, !wakeReason.isEmpty {
            return wakeReason.replacingOccurrences(of: "_", with: " ")
        }
        return outcome.label
    }

    var livePreviewLine: String? {
        guard case .receiving(_, _, let preview) = outcome else { return nil }
        return Self.latestPreviewLine(from: preview)
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        String(format: "%.1fs", max(0, seconds))
    }

    static func latestPreviewLine(from preview: String) -> String? {
        let trimmed = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lines = trimmed
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let last = lines.last else { return nil }
        let snippet: String
        if last.count < 16 && lines.count > 1 {
            snippet = lines.suffix(3).joined(separator: " ")
        } else {
            snippet = last
        }
        let collapsed = snippet.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        if collapsed.count > 140 && (collapsed.hasPrefix("{") || collapsed.hasPrefix("[")) {
            return "…" + String(collapsed.suffix(139))
        }
        return collapsed
    }

    static func summarize(brain: Brain, outcome: Outcome) -> String {
        switch outcome {
        case .cancelled:
            return "Canceled"
        case .failed:
            return "Failed"
        case .waiting, .receiving:
            return outcome.label
        case .response(let status, _, let body):
            guard (200..<300).contains(status) else { return "HTTP \(status)" }
            guard let json = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any] else {
                return brain == .slow ? "Invalid plan" : "HTTP \(status)"
            }
            if brain == .slow {
                if let content = message["content"] as? String,
                   let plan = try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any],
                   let placements = plan["placements"] as? [Any] {
                    return "\(placements.count) placements"
                }
                return "Invalid plan"
            }

            let toolCalls = message["tool_calls"] as? [[String: Any]] ?? []
            if toolCalls.isEmpty {
                let content = (message["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return content.isEmpty ? "HTTP \(status)" : "Text reply"
            }

            var parts: [String] = []
            for call in toolCalls {
                let function = call["function"] as? [String: Any]
                let name = function?["name"] as? String ?? ""
                if name == "act",
                   let arguments = function?["arguments"] as? String,
                   let parsed = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any],
                   let actions = parsed["actions"] as? [[String: Any]],
                   !actions.isEmpty {
                    let labels = actions.compactMap { action -> String? in
                        guard let actionName = action["action"] as? String, !actionName.isEmpty else { return nil }
                        if actionName == "build_blueprint", let placements = action["placements"] as? [Any] {
                            return "build_blueprint (\(placements.count))"
                        }
                        return actionName
                    }
                    if labels.isEmpty {
                        parts.append("act")
                    } else {
                        parts.append(contentsOf: collapseAdjacentLabels(labels))
                    }
                } else if !name.isEmpty {
                    parts.append(name)
                }
            }
            if parts.isEmpty { return "HTTP \(status)" }
            if parts.count <= 3 { return parts.joined(separator: " + ") }
            return parts.prefix(2).joined(separator: " + ") + " + \(parts.count - 2) more"
        }
    }

    private static func collapseAdjacentLabels(_ labels: [String]) -> [String] {
        var groups: [(label: String, count: Int)] = []
        for label in labels {
            if let last = groups.last, last.label == label {
                groups[groups.count - 1].count += 1
            } else {
                groups.append((label, 1))
            }
        }
        return groups.map { $0.count > 1 ? "\($0.label) ×\($0.count)" : $0.label }
    }
}

@MainActor
@Observable
final class APIDebugger {
    private struct APIUpdate: Encodable {
        let exchangeID: UUID
        let outcome: APIExchange.Outcome
    }

    private let export: DebugExport?
    @ObservationIgnored private var requestJournals: [UUID: DebugJournal] = [:]
    var prompt = ""
    private(set) var exchanges: [APIExchange] = []

    init(debugExport: DebugExport? = nil) {
        export = debugExport
    }

    func record(_ exchange: APIExchange, apiKey: String? = nil) throws {
        try Task.checkCancellation()
        exchanges.append(exchange)
        if let journal = export?.currentJournal {
            requestJournals[exchange.id] = journal
            journal.registerAPIKey(apiKey)
            journal.event("api_request", exchange)
        }
    }

    func finish(_ id: UUID, with outcome: APIExchange.Outcome) {
        requestJournals[id]?.event("api_update", APIUpdate(exchangeID: id, outcome: outcome))
        if outcome.liveLabel == nil { requestJournals[id] = nil }
        guard let index = exchanges.lastIndex(where: { $0.id == id }) else { return }
        exchanges[index].outcome = outcome
        if outcome.liveLabel == nil {
            if exchanges[index].finishedAt == nil {
                exchanges[index].finishedAt = Date()
            }
            exchanges[index].summary = APIExchange.summarize(brain: exchanges[index].brain, outcome: outcome)
        }
    }

    func clear() {
        exchanges.removeAll()
        export?.event("api_history_cleared", [String: String]())
    }
}
