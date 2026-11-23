import Foundation

enum CharacterActionName: String, CaseIterable {
    case move, collect, drop, craft, place, say
    case collectAt = "collect_at", placeAt = "place_at"
    case walkTo = "walk_to", finish
    case acquire, buildBlueprint = "build_blueprint"
}

enum CharacterAction: Decodable, Sendable {
    case world(WorldAction)
    case walkTo(Position)
    case collectAt(Position, CollectTarget, count: Int = 1)
    case placeAt(Position, Structure, stand: Position? = nil)
    case acquire(Item, count: Int)
    case buildBlueprint([BlueprintPlacement])
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
        let hasQuantity = fields.contains(ToolField("count"))
        func quantity() -> Int? {
            guard hasQuantity else { return 1 }
            guard let amount = value(Int.self, "count"), amount > 0 else { return nil }
            return amount
        }
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
            let amount: Int
            switch kind {
            case .item:
                guard count == baseCount + (hasQuantity ? 2 : 1), let itemCount = quantity(),
                      let item = string("item").flatMap(Item.init(rawValue:)) else {
                    self = .invalid
                    return
                }
                target = .item(item)
                amount = itemCount
            case .above, .ground:
                guard count == baseCount else {
                    self = .invalid
                    return
                }
                target = kind == .above ? .above : .ground
                amount = 1
            }
            if name == .collect, let direction {
                self = .world(.collect(direction, target, count: amount))
            } else if name == .collectAt, let destination = position() {
                self = .collectAt(destination, target, count: amount)
            } else {
                self = .invalid
            }
        case .placeAt:
            let standKey = ToolField("stand")
            guard count == (fields.contains(standKey) ? 5 : 4), let destination = position(),
                  let structure = value(Structure.self, "structure") else {
                self = .invalid
                return
            }
            do {
                let stand = try fields.decodeStand(forKey: standKey)
                self = .placeAt(destination, structure, stand: stand)
            } catch {
                self = .invalid
            }
        case .acquire:
            guard count == 3, let amount = value(Int.self, "count"), amount > 0,
                  let item = string("item").flatMap(Item.init(rawValue:)) else {
                self = .invalid
                return
            }
            self = .acquire(item, count: amount)
        case .buildBlueprint:
            guard count == 2, let placements = value([BlueprintPlacement].self, "placements"),
                  !placements.isEmpty else {
                self = .invalid
                return
            }
            self = .buildBlueprint(placements)
        case .drop:
            guard count == 3, let direction,
                  let item = string("item").flatMap(Item.init(rawValue:)) else {
                self = .invalid
                return
            }
            self = .world(.drop(direction, item))
        case .craft:
            guard count == (hasQuantity ? 3 : 2), let amount = quantity(),
                  let recipe = string("item").flatMap(Recipe.init(rawValue:)) else {
                self = .invalid
                return
            }
            self = .world(.craft(recipe, count: amount))
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

extension KeyedDecodingContainer {
    func decodeStand(forKey key: Key) throws -> Position? {
        guard contains(key) else { return nil }
        let coordinates = try decode([Int].self, forKey: key)
        guard coordinates.count == 2 else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self,
                                                   debugDescription: "Expected stand coordinates [x, y]")
        }
        return Position(x: coordinates[0], y: coordinates[1])
    }
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

    struct Plan: Encodable, Sendable {
        let index: Int
        let steps: Int
        let failure: PlanFailure?
    }

    let results: [ActionOutcome]
    let skipped: Int
    let observation: WorldObservation
    var walks: [Walk]? = nil
    var plans: [Plan]? = nil
    var memory: MemoryReceipt? = nil
    var recentHistory: [[HistoryEvent]]? = nil

    var finished: Bool { results.last == .finished }
}
