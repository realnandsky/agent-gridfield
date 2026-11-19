import Foundation
import Observation

struct APIExchange: Identifiable, Encodable, Sendable {
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
    var visionID: UUID? = nil
    var outcome: Outcome = .waiting
}

@MainActor
@Observable
final class APIDebugger {
    private struct APIUpdate: Encodable {
        let exchangeID: UUID
        let outcome: APIExchange.Outcome
    }

    private let export: DebugExport?
    var prompt = ""
    private(set) var exchanges: [APIExchange] = []

    init(debugExport: DebugExport? = nil) {
        export = debugExport
    }

    func record(_ exchange: APIExchange, apiKey: String? = nil) {
        exchanges.append(exchange)
        export?.registerAPIKey(apiKey)
        export?.event("api_request", exchange)
    }

    func finish(_ id: UUID, with outcome: APIExchange.Outcome) {
        export?.event("api_update", APIUpdate(exchangeID: id, outcome: outcome))
        guard let index = exchanges.lastIndex(where: { $0.id == id }) else { return }
        exchanges[index].outcome = outcome
    }

    func clear() {
        exchanges.removeAll()
        export?.event("api_history_cleared", [String: String]())
    }
}
