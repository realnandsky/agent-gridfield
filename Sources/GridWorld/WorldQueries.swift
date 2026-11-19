enum ResourceKind: String, CaseIterable, Decodable, Sendable {
    case tree, bush, branch, log, plank, grass
    case grassBed = "grass_bed"
}

struct QueryBatch: Decodable {
    let queries: [WorldQuery]

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: ToolField.self)
        guard fields.allKeys.map(\.stringValue) == ["queries"] else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Expected queries only"))
        }
        queries = try fields.decode([WorldQuery].self, forKey: ToolField("queries"))
    }
}

enum WorldQuery: Decodable {
    enum Name: String, CaseIterable, Decodable {
        case findResources = "find_resources", estimateMaterials = "estimate_materials"
        case previewBuild = "preview_build", findBuildSites = "find_build_sites"
    }

    static let blueprintLimit = 408
    case findResources(ResourceKind, limit: Int)
    case estimateMaterials([Structure: Int])
    case previewBuild([BlueprintPlacement])
    case findBuildSites(width: Int, height: Int, limit: Int)
    case invalid

    init(from decoder: any Decoder) throws {
        guard let fields = try? decoder.container(keyedBy: ToolField.self),
              let name = try? fields.decode(Name.self, forKey: ToolField("query")) else {
            self = .invalid
            return
        }
        func value<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
            try? fields.decode(type, forKey: ToolField(name))
        }
        let hasLimit = fields.contains(ToolField("limit"))
        let limit = hasLimit ? value(Int.self, "limit").flatMap { (1...10).contains($0) ? $0 : nil } : 3
        let count = fields.allKeys.count
        switch name {
        case .findResources:
            guard count == (hasLimit ? 3 : 2), let resource = value(ResourceKind.self, "resource"), let limit else {
                self = .invalid
                return
            }
            self = .findResources(resource, limit: limit)
        case .estimateMaterials:
            guard count == 2, let counts = value([String: Int].self, "counts") else {
                self = .invalid
                return
            }
            var parsed: [Structure: Int] = [:]
            var total = 0
            for (name, count) in counts {
                guard let structure = Structure(rawValue: name), (0...(Self.blueprintLimit - total)).contains(count) else {
                    self = .invalid
                    return
                }
                parsed[structure] = count
                total += count
            }
            self = .estimateMaterials(parsed)
        case .previewBuild:
            guard count == 2, let placements = value([BlueprintPlacement].self, "placements"),
                  (1...Self.blueprintLimit).contains(placements.count) else {
                self = .invalid
                return
            }
            self = .previewBuild(placements)
        case .findBuildSites:
            guard count == (hasLimit ? 4 : 3), let width = value(Int.self, "width"), width > 0,
                  let height = value(Int.self, "height"), height > 0, let limit else {
                self = .invalid
                return
            }
            self = .findBuildSites(width: width, height: height, limit: limit)
        }
    }

    func result(in world: World, at index: Int) -> ToolReceipt.Query? {
        switch self {
        case .findResources(let resource, let limit):
            .init(index: index, resources: world.findResources(resource, limit: limit))
        case .estimateMaterials(let counts):
            .init(index: index, materials: world.estimateMaterials(counts))
        case .previewBuild(let placements):
            .init(index: index, preview: world.previewBuild(placements))
        case .findBuildSites(let width, let height, let limit):
            .init(index: index, sites: world.findBuildSites(width: width, height: height, limit: limit))
        case .invalid:
            nil
        }
    }
}

struct BlueprintPlacement: Decodable, Sendable {
    let x: Int
    let y: Int
    let structure: Structure

    var position: Position { Position(x: x, y: y) }
}

struct MaterialEstimate: Encodable, Sendable {
    let required: [String: Int]
    let crafts: [String: Int]
    let missing: [String: Int]
}

struct ResourceCandidate: Encodable, Sendable {
    let position: [Int]
    let stand: [Int]
    let steps: Int
    let count: Int
    let target: String
}

struct BlueprintPreview: Encodable, Sendable {
    struct Failure: Encodable, Sendable {
        let index: Int
        let position: [Int]
        let reason: ActionOutcome
    }

    struct WallSeam: Encodable, Sendable {
        let from: [Int]
        let to: [Int]
        let direction: String
    }

    let materials: MaterialEstimate
    let validLayout: Bool
    let failure: Failure?
    let wallSeams: [WallSeam]?
}

struct BuildSite: Encodable, Sendable {
    let origin: [Int]
    let entrance: [Int]
    let stepsToEntrance: Int
    let clear: [[Int]]
}

extension World {
    func findResources(_ resource: ResourceKind, limit: Int) -> [ResourceCandidate] {
        let reachable = reachability()
        let item = Item(rawValue: resource.rawValue)
        var candidates: [ResourceCandidate] = []
        for y in 0..<height {
            for x in 0..<width {
                let position = Position(x: x, y: y)
                guard let tile = tile(at: position) else { continue }
                let count: Int
                let target: String
                switch resource {
                case .tree:
                    count = tile.terrain == .tree ? Self.logsPerTree : 0
                    target = "above"
                case .bush:
                    count = tile.resources[.grass, default: 0]
                    target = "above"
                default:
                    guard let item else { continue }
                    count = tile.items[item, default: 0] + (item == .branch ? tile.resources[.branch, default: 0] : 0)
                    target = "item"
                }
                guard count > 0, let stand = reachable.closestStand(to: position) else { continue }
                candidates.append(.init(position: [x, y], stand: [stand.position.x, stand.position.y],
                                        steps: stand.distance, count: count, target: target))
            }
        }
        return Array(candidates.sorted {
            ($0.steps, $0.position[1], $0.position[0]) < ($1.steps, $1.position[1], $1.position[0])
        }.prefix(limit))
    }

    func estimateMaterials(_ counts: [Structure: Int]) -> MaterialEstimate {
        let required = Self.requiredItems(counts)
        var needed = required
        var available = inventory
        var crafts: [String: Int] = [:]
        // Expand dependent recipes before their ingredients so carried planks are allocated only once.
        for recipe in [Recipe.grassBed, .plank] {
            let output = recipe.output
            let demand = needed.removeValue(forKey: output.item) ?? 0
            let fromInventory = min(demand, available[output.item, default: 0])
            available[output.item, default: 0] -= fromInventory
            let batches = (demand - fromInventory + output.count - 1) / output.count
            guard batches > 0 else { continue }
            crafts[recipe.rawValue] = batches
            for (ingredient, count) in recipe.ingredients {
                needed[ingredient, default: 0] += batches * count
            }
        }
        var missing: [Item: Int] = [:]
        for (item, demand) in needed where demand > available[item, default: 0] {
            missing[item] = demand - available[item, default: 0]
        }
        return MaterialEstimate(required: required.namedCounts, crafts: crafts, missing: missing.namedCounts)
    }

    func previewBuild(_ placements: [BlueprintPlacement]) -> BlueprintPreview {
        var counts: [Structure: Int] = [:]
        for placement in placements { counts[placement.structure, default: 0] += 1 }
        let estimate = estimateMaterials(counts)
        var simulated = suppliedForPreview(Self.requiredItems(counts))
        for (index, placement) in placements.enumerated() {
            let outcome = simulated.interact(at: placement.position) { .place($0, placement.structure) }.outcome
            if !outcome.success {
                return BlueprintPreview(materials: estimate, validLayout: false,
                                        failure: .init(index: index, position: [placement.x, placement.y], reason: outcome),
                                        wallSeams: nil)
            }
        }
        let newWalls = Set(placements.filter { $0.structure.blocksMovement }.map(\.position))
        return BlueprintPreview(materials: estimate, validLayout: true, failure: nil,
                                wallSeams: simulated.wallSeams(touching: newWalls))
    }

    private func wallSeams(touching newWalls: Set<Position>) -> [BlueprintPreview.WallSeam] {
        var seams: [BlueprintPreview.WallSeam] = []
        for from in newWalls.sorted(by: { ($0.y, $0.x) < ($1.y, $1.x) }) {
            guard let wall = tile(at: from)?.fixture else { continue }
            for direction in Direction.allCases {
                let to = from.neighbor(direction)
                if newWalls.contains(to), direction == .north || direction == .west { continue }
                guard let neighbor = tile(at: to)?.fixture, neighbor.blocksMovement else { continue }
                let outgoing = wall.wallArms.contains(direction)
                let incoming = neighbor.wallArms.contains(direction.opposite)
                guard outgoing != incoming else { continue }
                seams.append(.init(from: [from.x, from.y], to: [to.x, to.y], direction: direction.rawValue))
            }
        }
        return seams
    }

    private static func requiredItems(_ counts: [Structure: Int]) -> [Item: Int] {
        var required: [Item: Int] = [:]
        for (structure, count) in counts where count > 0 { required[structure.item, default: 0] += count }
        return required
    }

    func findBuildSites(width columns: Int, height rows: Int, limit: Int) -> [BuildSite] {
        guard columns <= width, rows <= height else { return [] }
        let reachable = reachability()
        var sites: [BuildSite] = []
        for y in 0...(height - rows) {
            for x in 0...(width - columns) {
                let xs = x..<(x + columns)
                let ys = y..<(y + rows)
                var clear: [[Int]] = []
                var usable = true
                var entrance: (position: [Int], steps: Int)?
                for row in ys {
                    for column in xs {
                        let position = Position(x: column, y: row)
                        guard let tile = tile(at: position), tile.terrain != .water,
                              !tile.hasFloor, tile.fixture == nil else {
                            usable = false
                            continue
                        }
                        if tile.terrain == .tree || tile.hasBush { clear.append([column, row]) }
                        for direction in Direction.allCases {
                            let outside = position.neighbor(direction)
                            guard !xs.contains(outside.x) || !ys.contains(outside.y),
                                  let distance = reachable.distance(to: outside),
                                  distance + 1 < (entrance?.steps ?? Int.max) else { continue }
                            entrance = ([column, row], distance + 1)
                        }
                    }
                }
                guard usable, let entrance else { continue }
                sites.append(.init(origin: [x, y], entrance: entrance.position,
                                   stepsToEntrance: entrance.steps, clear: clear))
            }
        }
        return Array(sites.sorted {
            ($0.clear.count, $0.stepsToEntrance, $0.origin[1], $0.origin[0])
                < ($1.clear.count, $1.stepsToEntrance, $1.origin[1], $1.origin[0])
        }.prefix(limit))
    }
}
