import Foundation

enum CharacterActionName: String, CaseIterable {
    case move, collect, drop, craft, place, say
    case collectAt = "collect_at", placeAt = "place_at"
    case walkTo = "walk_to", finish
}

enum CharacterAction: Decodable, Sendable {
    case world(WorldAction)
    case walkTo(Position)
    case collectAt(Position, CollectTarget)
    case placeAt(Position, Structure)
    case say(String)
    case invalid

    init(from decoder: any Decoder) throws {
        guard let fields = try? decoder.container(keyedBy: ToolField.self) else {
            self = .invalid
            return
        }
        func value<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
            try? fields.decode(type, forKey: ToolField(name))
        }
        func string(_ name: String) -> String? { value(String.self, name) }
        func position() -> Position? {
            guard let x = value(Int.self, "x"), let y = value(Int.self, "y") else { return nil }
            return Position(x: x, y: y)
        }
        guard let name = string("action").flatMap(CharacterActionName.init(rawValue:)) else {
            self = .invalid
            return
        }

        let count = fields.allKeys.count
        let direction = string("direction").flatMap(Direction.init(rawValue:))
        switch name {
        case .move:
            guard count == 2, let direction else {
                self = .invalid
                return
            }
            self = .world(.move(direction))
        case .walkTo:
            guard count == 3, let destination = position() else {
                self = .invalid
                return
            }
            self = .walkTo(destination)
        case .collect, .collectAt:
            guard let kind = string("target").flatMap(CollectTarget.Kind.init(rawValue:)) else {
                self = .invalid
                return
            }
            let baseCount = name == .collect ? 3 : 4
            let target: CollectTarget
            switch kind {
            case .item:
                guard count == baseCount + 1, let item = string("item").flatMap(Item.init(rawValue:)) else {
                    self = .invalid
                    return
                }
                target = .item(item)
            case .above, .ground:
                guard count == baseCount else {
                    self = .invalid
                    return
                }
                target = kind == .above ? .above : .ground
            }
            if name == .collect, let direction {
                self = .world(.collect(direction, target))
            } else if name == .collectAt, let destination = position() {
                self = .collectAt(destination, target)
            } else {
                self = .invalid
            }
        case .placeAt:
            guard count == 4, let destination = position(),
                  let structure = value(Structure.self, "structure") else {
                self = .invalid
                return
            }
            self = .placeAt(destination, structure)
        case .drop:
            guard count == 3, let direction,
                  let item = string("item").flatMap(Item.init(rawValue:)) else {
                self = .invalid
                return
            }
            self = .world(.drop(direction, item))
        case .craft:
            guard count == 2, let recipe = string("item").flatMap(Recipe.init(rawValue:)) else {
                self = .invalid
                return
            }
            self = .world(.craft(recipe))
        case .place:
            guard count == 3, let direction,
                  let structure = string("structure").flatMap(Structure.init(rawValue:)) else {
                self = .invalid
                return
            }
            self = .world(.place(direction, structure))
        case .say:
            guard count == 2,
                  let text = string("text")?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                self = .invalid
                return
            }
            self = .say(text)
        case .finish:
            self = count == 1 ? .world(.finish) : .invalid
        }
    }
}

struct ToolField: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(_ name: String) { stringValue = name }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
}

struct ActionBatch: Decodable, Sendable {
    let actions: [CharacterAction]

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: ToolField.self)
        guard fields.allKeys.map(\.stringValue) == ["actions"] else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Expected actions only"))
        }
        actions = try fields.decode([CharacterAction].self, forKey: ToolField("actions"))
    }
}

struct ToolReceipt: Encodable, Sendable {
    struct Walk: Encodable, Sendable {
        let index: Int
        let destination: [Int]
        let steps: Int
    }

    struct Query: Encodable, Sendable {
        let index: Int
        var resources: [ResourceCandidate]?
        var materials: MaterialEstimate?
        var preview: BlueprintPreview?
        var sites: [BuildSite]?
    }

    let results: [ActionOutcome]
    let skipped: Int
    let observation: WorldObservation
    var walks: [Walk]? = nil
    var queries: [Query]? = nil
    var memory: MemoryReceipt? = nil
    var recentHistory: [[HistoryEvent]]? = nil

    var finished: Bool { results.last == .finished }
}
