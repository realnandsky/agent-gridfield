import Foundation

struct Position: Hashable, Sendable {
    let x: Int
    let y: Int

    func neighbor(_ direction: Direction) -> Position {
        switch direction {
        case .north: Position(x: x, y: y - 1)
        case .south: Position(x: x, y: y + 1)
        case .west: Position(x: x - 1, y: y)
        case .east: Position(x: x + 1, y: y)
        }
    }
}

enum Direction: String, CaseIterable, Sendable {
    case north, south, west, east

    var opposite: Direction {
        switch self {
        case .north: .south
        case .south: .north
        case .west: .east
        case .east: .west
        }
    }
}

enum Terrain: String, Sendable {
    case grass, water, tree
}

enum Item: String, CaseIterable, Sendable {
    case branch, log, plank, grass
    case grassBed = "grass_bed"

    var displayName: String {
        switch self {
        case .branch: "Branches"
        case .log: "Logs"
        case .plank: "Planks"
        case .grass: "Grass"
        case .grassBed: "Grass Beds"
        }
    }
}

enum Recipe: String, CaseIterable, Sendable {
    case plank
    case grassBed = "grass_bed"

    var ingredients: [Item: Int] {
        switch self {
        case .plank: [.log: 1]
        case .grassBed: [.grass: 2, .plank: 2]
        }
    }

    var output: (item: Item, count: Int) {
        switch self {
        case .plank: (.plank, 4)
        case .grassBed: (.grassBed, 1)
        }
    }
}

enum Structure: String, CaseIterable, Decodable, Sendable {
    case floor, wall
    case wallNS = "wall_ns", wallEW = "wall_ew"
    case cornerNE = "corner_ne", cornerSE = "corner_se", cornerSW = "corner_sw", cornerNW = "corner_nw"
    case grassBed = "grass_bed"

    var wallArms: [Direction] {
        switch self {
        case .floor, .wall, .grassBed: []
        case .wallNS: [.north, .south]
        case .wallEW: [.east, .west]
        case .cornerNE: [.north, .east]
        case .cornerSE: [.south, .east]
        case .cornerSW: [.south, .west]
        case .cornerNW: [.north, .west]
        }
    }

    var mapID: String {
        switch self {
        case .floor: "fl"
        case .wall: "w"
        case .grassBed: "bed"
        case .wallNS: "wns"
        case .wallEW: "wew"
        case .cornerNE: "cne"
        case .cornerSE: "cse"
        case .cornerSW: "csw"
        case .cornerNW: "cnw"
        }
    }

    var blocksMovement: Bool { self == .wall || !wallArms.isEmpty }
    var item: Item { self == .grassBed ? .grassBed : .plank }
}

enum CollectTarget: Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case item, above, ground
    }

    case item(Item)
    case above
    case ground
}

enum WorldAction: Sendable {
    case move(Direction)
    case collect(Direction, CollectTarget, count: Int = 1)
    case drop(Direction, Item)
    case craft(Recipe, count: Int = 1)
    case place(Direction, Structure)
    case finish
}

enum ActionOutcome: String, Codable, Sendable {
    case moved, arrived, collected, dropped, finished, inspected
    case crafted, placed, acquired, built
    case messageSent = "message_sent"
    case memoryUpdated = "memory_updated"
    case visionUnavailable = "vision_unavailable"
    case waterBlocked = "water_blocked", treeBlocked = "tree_blocked"
    case boundary, blockUnavailable = "block_unavailable", itemAbsent = "item_absent"
    case itemNotCarried = "item_not_carried", invalidArguments = "invalid_arguments"
    case unknownTool = "unknown_tool"
    case wallBlocked = "wall_blocked", buildBlocked = "build_blocked"
    case occupied, missingIngredients = "missing_ingredients", unreachable, interrupted

    var success: Bool {
        switch self {
        case .moved, .arrived, .collected, .dropped, .crafted, .placed, .acquired, .built,
             .messageSent, .memoryUpdated, .finished, .inspected: true
        case .boundary, .waterBlocked, .treeBlocked, .blockUnavailable, .itemAbsent, .itemNotCarried,
             .invalidArguments, .unknownTool, .visionUnavailable, .wallBlocked, .buildBlocked, .occupied, .missingIngredients,
             .unreachable, .interrupted: false
        }
    }
}

struct Tile: Equatable, Sendable {
    let terrain: Terrain
    var items: [Item: Int] = [:]
    var resources: [Item: Int] = [:]
    var hasFloor = false
    var fixture: Structure?

    var hasBush: Bool { resources[.grass, default: 0] > 0 }
}

struct WorldObservation: Encodable, Equatable, Sendable {
    let view: [[Tile]]
    let avatar: Position
    let inventory: [String: Int]
    let notebook: String

    private static let legend = [
        "gr": "grass", "wa": "water", "air": "air", "tr": "tree", "bu": "bush",
    ].merging(Dictionary(uniqueKeysWithValues: Structure.allCases.map { ($0.mapID, $0.rawValue) })) { _, structure in
        structure
    }

    enum CodingKeys: String, CodingKey {
        case legend, mapEncoding, ground, above, avatar, inventory, items, notebook
    }

    func encode(to encoder: any Encoder) throws {
        var ground: [String] = []
        var above: [String] = []
        var items: [(x: Int, y: Int, item: Item, count: Int)] = []
        for (y, row) in view.enumerated() {
            ground.append(Self.encodeRow(row.map { tile in
                if tile.hasFloor { return Structure.floor.mapID }
                return tile.terrain == .water ? "wa" : "gr"
            }))
            above.append(Self.encodeRow(row.map { tile in
                if tile.terrain == .tree { return "tr" }
                if tile.hasBush { return "bu" }
                return tile.fixture?.mapID ?? "air"
            }))
            for (x, tile) in row.enumerated() {
                var counts = tile.items
                if let branches = tile.resources[.branch], branches > 0 {
                    counts[.branch, default: 0] += branches
                }
                for (item, count) in counts.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                    items.append((x, y, item, count))
                }
            }
        }

        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Self.legend, forKey: .legend)
        try values.encode("x_ranges_v1", forKey: .mapEncoding)
        try values.encode(ground, forKey: .ground)
        try values.encode(above, forKey: .above)
        try values.encode([avatar.x, avatar.y], forKey: .avatar)
        try values.encode(inventory, forKey: .inventory)
        try values.encode(notebook, forKey: .notebook)
        if !items.isEmpty {
            var entries = values.nestedUnkeyedContainer(forKey: .items)
            for item in items {
                var entry = entries.nestedUnkeyedContainer()
                try entry.encode(item.x)
                try entry.encode(item.y)
                try entry.encode(item.item.rawValue)
                try entry.encode(item.count)
            }
        }
    }

    private static func encodeRow(_ cells: [String]) -> String {
        var runs: [String] = []
        var start = 0
        while start < cells.count {
            var end = start
            while end + 1 < cells.count, cells[end + 1] == cells[start] { end += 1 }
            let x = start == end ? String(start) : "\(start)..\(end)"
            runs.append("\(x)=\(cells[start])")
            start = end + 1
        }
        return runs.joined(separator: " ")
    }
}

struct World: Equatable, Sendable {
    static let logsPerTree = 2

    let width = 17
    let height = 12
    private(set) var avatar = Position(x: 8, y: 5)
    private(set) var inventory: [Item: Int]
    private var tiles: [Tile]

    init(bushCount: Int = 12, inventory: [Item: Int] = [:]) {
        self.inventory = inventory
        let treeColumns: [[Int]] = [
            [9], [10], [8, 11], [10, 12], [8, 12], [11],
            [10], [7, 10, 11], [7, 9, 11], [], [], [],
        ]
        tiles = Array(repeating: Tile(terrain: .grass), count: width * height)

        let waterSpans: [(row: Int, columns: ClosedRange<Int>)] = [
            (0, 0...2), (1, 0...4), (2, 0...6), (3, 0...7),
            (4, 1...7), (5, 2...7), (6, 3...6), (7, 4...5),
            (7, 15...16), (8, 14...16), (9, 12...16), (10, 12...16), (11, 13...16),
        ]
        for (row, columns) in waterSpans {
            for column in columns {
                tiles[row * width + column] = Tile(terrain: .water)
            }
        }

        for (row, columns) in treeColumns.enumerated() {
            for column in columns {
                let branches = 2 + (column + row) % 2
                tiles[row * width + column] = Tile(terrain: .tree, resources: [.branch: branches])
            }
        }

        for position in [Position(x: 9, y: 5), Position(x: 7, y: 2), Position(x: 11, y: 9)] {
            tiles[position.y * width + position.x].items[.branch] = 1
        }

        let spawn = avatar.y * width + avatar.x
        let bushSites = tiles.indices.filter {
            $0 != spawn && tiles[$0].terrain == .grass && tiles[$0].items.isEmpty
        }
        for site in bushSites.shuffled().prefix(max(0, bushCount)) {
            tiles[site].resources[.grass] = 1
        }
    }

    func tile(at position: Position) -> Tile? {
        guard let index = index(of: position) else { return nil }
        return tiles[index]
    }

    func wallArms(at position: Position) -> [Direction] {
        guard let wall = tile(at: position)?.fixture, wall.blocksMovement else { return [] }
        return Direction.allCases.filter { direction in
            let neighbor = tile(at: position.neighbor(direction))?.fixture
            if wall == .wall { return neighbor?.blocksMovement == true }
            return wall.wallArms.contains(direction) || neighbor == .wall
        }
    }

    func observation(notebook: String = "") -> WorldObservation {
        let view = stride(from: 0, to: tiles.count, by: width).map { start in
            Array(tiles[start..<(start + width)])
        }
        return WorldObservation(view: view, avatar: avatar, inventory: inventory.namedCounts, notebook: notebook)
    }

    struct Reachability {
        let start: Position
        let arrivals: [Position: (from: Position, direction: Direction, distance: Int)]

        func distance(to position: Position) -> Int? {
            position == start ? 0 : arrivals[position]?.distance
        }

        func route(to destination: Position) -> [Direction]? {
            guard distance(to: destination) != nil else { return nil }
            var route: [Direction] = []
            var cursor = destination
            while let step = arrivals[cursor] {
                route.append(step.direction)
                cursor = step.from
            }
            return route.reversed()
        }

        func closestStand(to target: Position, allowing: (Position) -> Bool = { _ in true })
            -> (position: Position, facing: Direction, distance: Int)? {
            var closest: (position: Position, facing: Direction, distance: Int)?
            for direction in Direction.allCases {
                let stand = target.neighbor(direction)
                guard allowing(stand), let distance = distance(to: stand),
                      distance < (closest?.distance ?? Int.max) else { continue }
                closest = (stand, direction.opposite, distance)
            }
            return closest
        }
    }

    func reachability(from start: Position? = nil, avoiding blocked: Set<Position> = []) -> Reachability {
        let start = start ?? avatar
        var queue = [start]
        var next = 0
        var arrivals: [Position: (from: Position, direction: Direction, distance: Int)] = [:]
        while next < queue.count {
            let position = queue[next]
            next += 1
            let distance = arrivals[position]?.distance ?? 0
            for direction in Direction.allCases {
                let neighbor = position.neighbor(direction)
                guard neighbor != start, arrivals[neighbor] == nil, !blocked.contains(neighbor),
                      movementOutcome(to: neighbor) == .moved else { continue }
                arrivals[neighbor] = (position, direction, distance + 1)
                queue.append(neighbor)
            }
        }
        return Reachability(start: start, arrivals: arrivals)
    }

    func shortestRoute(to destination: Position) -> [Direction]? {
        reachability().route(to: destination)
    }

    func firstTreeForAccess(to stands: [Position]) -> Position? {
        guard !stands.isEmpty else { return nil }
        struct Route {
            let cost: Int
            let firstTree: Position?
        }
        let targets = Set(stands)
        // A cut costs more than walking across the entire map, so walking breaks ties between routes.
        let treeCost = width * height
        var costs = [avatar: 0]
        var frontier = [avatar: Route(cost: 0, firstTree: nil)]
        while let (position, route) = frontier.min(by: {
            ($0.value.cost, $0.key.y, $0.key.x) < ($1.value.cost, $1.key.y, $1.key.x)
        }) {
            frontier.removeValue(forKey: position)
            if targets.contains(position) { return route.firstTree }
            for direction in Direction.allCases {
                let next = position.neighbor(direction)
                let outcome = movementOutcome(to: next)
                guard outcome == .treeBlocked || outcome == .moved else { continue }
                let isTree = outcome == .treeBlocked
                let cost = route.cost + 1 + (isTree ? treeCost : 0)
                guard cost < costs[next, default: .max] else { continue }
                costs[next] = cost
                frontier[next] = Route(cost: cost, firstTree: route.firstTree ?? (isTree ? next : nil))
            }
        }
        return nil
    }

    mutating func interact(at target: Position, standingAt requestedStand: Position? = nil,
                           action: (Direction) -> WorldAction)
        -> (outcome: ActionOutcome, actions: [WorldAction]) {
        guard tile(at: target) != nil else { return (.boundary, []) }
        let reachable = reachability()
        let stand: (position: Position, facing: Direction)
        if let requestedStand {
            guard tile(at: requestedStand) != nil,
                  let side = Direction.allCases.first(where: { target.neighbor($0) == requestedStand }) else {
                return (.invalidArguments, [])
            }
            stand = (requestedStand, side.opposite)
        } else {
            guard let nearest = reachable.closestStand(to: target) else { return (.unreachable, []) }
            stand = (nearest.position, nearest.facing)
        }
        guard let route = reachable.route(to: stand.position) else { return (.unreachable, []) }

        var projected = self
        projected.avatar = stand.position
        let interaction = action(stand.facing)
        let outcome = projected.apply(interaction)
        guard outcome.success else { return (outcome, []) }
        self = projected
        return (outcome, route.map(WorldAction.move) + [interaction])
    }

    mutating func apply(_ action: WorldAction) -> ActionOutcome {
        switch action {
        case .move(let direction):
            let target = avatar.neighbor(direction)
            let outcome = movementOutcome(to: target)
            if outcome == .moved { avatar = target }
            return outcome
        case .collect(let direction, let selection, let count):
            guard let target = index(of: avatar.neighbor(direction)) else { return .boundary }
            return collect(selection, at: target, count: count)
        case .drop(let direction, let item):
            guard let target = index(of: avatar.neighbor(direction)) else { return .boundary }
            guard inventory.remove(item) else { return .itemNotCarried }
            tiles[target].items[item, default: 0] += 1
            return .dropped
        case .craft(let recipe, let count):
            return craft(recipe, count: count)
        case .place(let direction, let structure):
            guard let target = index(of: avatar.neighbor(direction)) else { return .boundary }
            return place(structure, at: target)
        case .finish:
            return .finished
        }
    }

    private func movementOutcome(to target: Position) -> ActionOutcome {
        guard let tile = tile(at: target) else { return .boundary }
        switch tile.terrain {
        case .water: return .waterBlocked
        case .tree: return .treeBlocked
        case .grass: return tile.fixture?.blocksMovement == true ? .wallBlocked : .moved
        }
    }

    private func index(of position: Position) -> Int? {
        guard (0..<width).contains(position.x), (0..<height).contains(position.y) else { return nil }
        return position.y * width + position.x
    }

    private mutating func craft(_ recipe: Recipe, count: Int) -> ActionOutcome {
        guard count > 0 else { return .invalidArguments }
        let ingredients = recipe.ingredients
        guard ingredients.allSatisfy({ inventory[$0.key, default: 0] / $0.value >= count }) else {
            return .missingIngredients
        }
        let output = recipe.output
        let currentOutput = inventory[output.item, default: 0]
        guard count <= (Int.max - currentOutput) / output.count else { return .invalidArguments }
        for (item, units) in ingredients {
            _ = inventory.remove(item, count: units * count)
        }
        inventory[output.item] = currentOutput + output.count * count
        return .crafted
    }

    private mutating func place(_ structure: Structure, at index: Int) -> ActionOutcome {
        let tile = tiles[index]
        guard tile.terrain == .grass, !tile.hasBush else { return .buildBlocked }
        switch structure {
        case .floor:
            guard !tile.hasFloor, tile.fixture?.blocksMovement != true else { return .occupied }
        case .grassBed:
            guard tile.fixture == nil else { return .occupied }
        default:
            guard tile.fixture == nil, !tile.hasFloor else { return .occupied }
        }
        guard inventory.remove(structure.item) else { return .itemNotCarried }
        if structure == .floor {
            tiles[index].hasFloor = true
        } else {
            tiles[index].fixture = structure
        }
        return .placed
    }

    private mutating func collect(_ selection: CollectTarget, at index: Int, count: Int) -> ActionOutcome {
        guard count > 0 else { return .invalidArguments }
        switch selection {
        case .item(let item):
            let loose = min(count, tiles[index].items[item, default: 0])
            let attached = count - loose
            let availableAttached = item == .branch ? tiles[index].resources[item, default: 0] : 0
            guard attached <= availableAttached else { return .itemAbsent }
            let (total, overflow) = inventory[item, default: 0].addingReportingOverflow(count)
            guard !overflow else { return .invalidArguments }
            _ = tiles[index].items.remove(item, count: loose)
            _ = tiles[index].resources.remove(item, count: attached)
            inventory[item] = total
        case .above:
            guard count == 1 else { return .invalidArguments }
            if tiles[index].terrain == .tree {
                var items = tiles[index].items
                items[.log, default: 0] += Self.logsPerTree
                tiles[index] = Tile(terrain: .grass, items: items)
            } else if tiles[index].resources.remove(.grass) {
                inventory[.grass, default: 0] += 1
            } else if let fixture = tiles[index].fixture {
                tiles[index].fixture = nil
                inventory[fixture.item, default: 0] += 1
            } else {
                return .blockUnavailable
            }
        case .ground:
            guard count == 1 else { return .invalidArguments }
            guard tiles[index].hasFloor else { return .blockUnavailable }
            tiles[index].hasFloor = false
            inventory[.plank, default: 0] += 1
        }
        return .collected
    }
}

extension Dictionary where Key == Item, Value == Int {
    var namedCounts: [String: Int] {
        Dictionary<String, Int>(uniqueKeysWithValues: map { ($0.key.rawValue, $0.value) })
    }

    fileprivate mutating func remove(_ item: Item, count: Int = 1) -> Bool {
        guard count > 0, let available = self[item], available >= count else { return false }
        self[item] = available == count ? nil : available - count
        return true
    }
}
