import Foundation

struct MemoryPatch: Decodable, Sendable {
    let set: [String: String]
    let remove: [String]
    let text: String?

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: ToolField.self)
        let setKey = ToolField("set")
        let removeKey = ToolField("remove")
        let textKey = ToolField("text")
        guard fields.allKeys.allSatisfy({ ["set", "remove", "text"].contains($0.stringValue) }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown memory operation"))
        }
        set = fields.contains(setKey) ? try fields.decode([String: String].self, forKey: setKey) : [:]
        remove = fields.contains(removeKey) ? try fields.decode([String].self, forKey: removeKey) : []
        text = fields.contains(textKey)
            ? try fields.decode(String.self, forKey: textKey).trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
    }
}

struct MemoryReceipt: Encodable, Sendable {
    enum Update: String, Encodable {
        case applied, unchanged, invalid
        case tooLarge = "too_large"
    }

    static let byteLimit = 2400
    static let notebookByteLimit = 2400
    let entries: [String: String]
    let update: Update?
}

struct HistoryEvent: Encodable, Sendable {
    let action: String
    let result: ActionOutcome
    var count: Int? = nil
    var avatar: [Int]? = nil
    var query: ToolReceipt.Query? = nil

    init?(action: CharacterAction, result: ActionOutcome, from avatar: Position) {
        let description: String
        switch action {
        case .world(.craft(let recipe)):
            let ingredients = recipe.ingredients.namedCounts.sorted { $0.key < $1.key }
                .map { "\($0.value) \($0.key)" }.joined(separator: " + ")
            description = "craft \(ingredients) -> \(recipe.output.count) \(recipe.output.item.rawValue)"
        case .world(.move(let direction)):
            description = "move \(direction.rawValue)"
        case .world(.collect(let direction, let target)):
            description = Self.collectDescription(at: avatar.neighbor(direction), target: target)
        case .world(.place(let direction, let structure)):
            description = "place \(structure.rawValue) at \(Self.label(avatar.neighbor(direction)))"
        case .world(.drop(let direction, let item)):
            description = "drop \(item.rawValue) at \(Self.label(avatar.neighbor(direction)))"
        case .walkTo(let position):
            description = "walk_to \(Self.label(position))"
        case .collectAt(let position, let target):
            description = Self.collectDescription(at: position, target: target)
        case .placeAt(let position, let structure):
            description = "place \(structure.rawValue) at \(Self.label(position))"
        case .invalid:
            description = "invalid action"
        case .say, .world(.finish):
            return nil
        }
        self.init(action: description, result: result, from: avatar)
    }

    init(query: WorldQuery, result: ToolReceipt.Query?, from avatar: Position) {
        let description: String
        switch query {
        case .findResources(let resource, _):
            description = "find_resources \(resource.rawValue)"
        case .estimateMaterials:
            description = "estimate_materials"
        case .previewBuild:
            description = "preview_build"
        case .findBuildSites(let width, let height, _):
            description = "find_build_sites \(width)x\(height)"
        case .invalid:
            description = "invalid query"
        }
        self.init(action: description, result: result == nil ? .invalidArguments : .inspected, from: avatar)
        if var result {
            result.resources = result.resources.map { Array($0.prefix(3)) }
            result.sites = result.sites.map { Array($0.prefix(3)) }
            if let preview = result.preview {
                result.preview = BlueprintPreview(materials: preview.materials, validLayout: preview.validLayout,
                                                  failure: preview.failure,
                                                  wallSeams: preview.wallSeams.map { Array($0.prefix(3)) })
            }
            self.query = result
        }
    }

    private init(action description: String, result: ActionOutcome, from avatar: Position) {
        self.action = description
        self.result = result
        self.avatar = result.success ? nil : [avatar.x, avatar.y]
    }

    private static func label(_ position: Position) -> String { "[\(position.x),\(position.y)]" }

    private static func collectDescription(at position: Position, target: CollectTarget) -> String {
        let what: String
        switch target {
        case .above: what = "above"
        case .ground: what = "ground"
        case .item(let item): what = item.rawValue
        }
        return "collect \(what) at \(label(position))"
    }
}

struct RecentHistory {
    static let byteLimit = 2400
    private(set) var batches: [[HistoryEvent]] = []

    mutating func append(_ events: [HistoryEvent]) {
        var grouped: [HistoryEvent] = []
        for event in events {
            if let last = grouped.last, last.query == nil, event.query == nil,
               last.action == event.action, last.result == event.result, last.avatar == event.avatar {
                grouped[grouped.count - 1].count = (last.count ?? 1) + 1
            } else {
                grouped.append(event)
            }
        }
        guard !grouped.isEmpty else { return }
        batches.append(grouped)
        if batches.count > 4 { batches.removeFirst() }
        let encoder = JSONEncoder()
        while let data = try? encoder.encode(batches), data.count > Self.byteLimit {
            if batches.count > 1 {
                batches.removeFirst()
            } else if let firstRoutine = batches[0].firstIndex(where: { $0.query == nil && $0.result.success }) {
                batches[0].remove(at: firstRoutine)
            } else {
                batches[0].removeFirst()
            }
            if batches.first?.isEmpty == true { batches.removeFirst() }
        }
    }
}
