import Foundation
import Observation

struct VisionFrame: Sendable {
    let png: Data
    let width: Int
    let height: Int
}

@MainActor
@Observable
final class VisionCall: Identifiable {
    enum Status: Equatable {
        case pending, sending, sent, cancelled, failed, invalid, disabled, renderFailed
        case rejected(Int)

        var label: String {
            switch self {
            case .pending: "Pending"
            case .sending: "Sending"
            case .sent: "Sent"
            case .cancelled: "Request canceled"
            case .failed: "Send failed"
            case .invalid: "Invalid arguments"
            case .disabled: "Vision disabled"
            case .renderFailed: "Map rendering failed"
            case .rejected(let code): "API rejected · HTTP \(code)"
            }
        }
    }

    struct Trace: Encodable {
        let id: UUID
        let number: Int
        let toolCallID: String
        let exchangeID: UUID?
        let avatar: [Int]
        let width: Int?
        let height: Int?
        let bytes: Int?
    }

    let id = UUID()
    let requestedAt = Date()
    let number: Int
    let avatar: Position
    let frame: VisionFrame?
    private(set) var status: Status

    init(number: Int, avatar: Position, frame: VisionFrame?, status: Status) {
        self.number = number
        self.avatar = avatar
        self.frame = frame
        self.status = status
    }

    func update(_ status: Status) {
        guard self.status == .pending || self.status == .sending else { return }
        self.status = status
    }

    func trace(for call: ToolCall) -> Trace {
        Trace(id: id, number: number, toolCallID: call.id, exchangeID: call.debugExchangeID,
              avatar: [avatar.x, avatar.y], width: frame?.width, height: frame?.height, bytes: frame?.png.count)
    }
}
