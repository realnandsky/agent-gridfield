struct BlueprintPlacement: Decodable, Sendable {
    let x: Int
    let y: Int
    let structure: Structure

    var position: Position { Position(x: x, y: y) }

    static func bounds(of placements: [BlueprintPlacement]) -> [[Int]]? {
        guard let first = placements.first else { return nil }
        var minX = first.x, maxX = first.x
        var minY = first.y, maxY = first.y
        for placement in placements.dropFirst() {
            minX = min(minX, placement.x)
            maxX = max(maxX, placement.x)
            minY = min(minY, placement.y)
            maxY = max(maxY, placement.y)
        }
        return [[minX, minY], [maxX, maxY]]
    }

    init(x: Int, y: Int, structure: Structure) {
        self.x = x
        self.y = y
        self.structure = structure
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: ToolField.self)
        guard Set(fields.allKeys.map(\.stringValue)) == ["x", "y", "structure"] else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                   debugDescription: "Expected placement x, y, and structure"))
        }
        self.init(x: try fields.decode(Int.self, forKey: ToolField("x")),
                  y: try fields.decode(Int.self, forKey: ToolField("y")),
                  structure: try fields.decode(Structure.self, forKey: ToolField("structure")))
    }
}

enum BlueprintPlanner {
    static func layoutFailure(_ placements: [BlueprintPlacement], in world: World) -> PlanFailure? {
        guard !placements.isEmpty else {
            return PlanFailure(.invalidArguments, "The blueprint must contain at least one placement.")
        }
        return validate(placements, in: world).failure
    }

    static func build(_ placements: [BlueprintPlacement], in plan: inout WorldPlan) -> PlanFailure? {
        guard !placements.isEmpty else {
            return PlanFailure(.invalidArguments, "The blueprint must contain at least one placement.")
        }
        let ordered = placements.sorted { ($0.y, $0.x, $0.structure.rawValue) < ($1.y, $1.x, $1.structure.rawValue) }
        let validation = validate(ordered, in: plan.world)
        if let failure = validation.failure { return failure }
        var projected = plan
        let pending = validation.pending
        let footprint = Set(pending.map(\.position)).sorted(by: positionOrder)
        if let failure = prepareSite(footprint, in: &projected) { return failure }
        var required: [Item: Int] = [:]
        for placement in pending { required[placement.structure.item, default: 0] += 1 }
        if let failure = AcquisitionPlanner.provision(required, in: &projected) { return failure }
        let nonblocking = pending.filter { !$0.structure.blocksMovement }
        if let failure = place(nonblocking, in: &projected) { return failure }
        let walls = pending.filter { $0.structure.blocksMovement }
        if !walls.isEmpty {
            let distances = escapeDistances(in: projected.world, walls: Set(walls.map(\.position)))
            guard !distances.isEmpty else {
                return PlanFailure(.unreachable, "The blueprint leaves no walkable tile for the avatar to exit to.")
            }
            if let failure = place(walls, in: &projected, toward: distances) { return failure }
        }
        plan = projected
        return nil
    }

    private static func validate(_ placements: [BlueprintPlacement], in world: World)
        -> (pending: [BlueprintPlacement], failure: PlanFailure?) {
        var fixtures: [Position: Structure] = [:]
        var floors: Set<Position> = []
        var pending: [BlueprintPlacement] = []
        for placement in placements {
            let position = placement.position
            let structure = placement.structure
            guard let tile = world.tile(at: position) else {
                return ([], PlanFailure(.boundary, "The placement is outside the map.", position: position))
            }
            guard tile.terrain != .water else {
                return ([], PlanFailure(.buildBlocked, "The placement is on water.", position: position))
            }
            if structure == .floor {
                guard tile.fixture?.blocksMovement != true, fixtures[position]?.blocksMovement != true else {
                    return ([], PlanFailure(.occupied, "A floor and a wall cannot share a tile.", position: position))
                }
                if floors.insert(position).inserted, !tile.hasFloor { pending.append(placement) }
                continue
            }
            guard !structure.blocksMovement || (!tile.hasFloor && !floors.contains(position)) else {
                return ([], PlanFailure(.occupied, "A floor and a wall cannot share a tile.", position: position))
            }
            if let other = fixtures[position] {
                guard other == structure else {
                    return ([], PlanFailure(.occupied, "Two fixtures share this blueprint tile.", position: position))
                }
                continue
            }
            fixtures[position] = structure
            if let existing = tile.fixture {
                guard existing == structure || (structure == .wall && existing.blocksMovement) else {
                    return ([], PlanFailure(.occupied, "An existing fixture occupies this tile.", position: position))
                }
            } else {
                pending.append(placement)
            }
        }
        return (pending, nil)
    }

    private static func prepareSite(_ footprint: [Position], in plan: inout WorldPlan) -> PlanFailure? {
        while true {
            let reachability = plan.world.reachability()
            var inaccessible: [Position] = []
            var nearestObstacle: (position: Position, distance: Int)?
            for position in footprint {
                guard let stand = reachability.closestStand(to: position) else {
                    inaccessible.append(position)
                    continue
                }
                guard let tile = plan.world.tile(at: position), tile.terrain == .tree || tile.hasBush else { continue }
                if stand.distance < (nearestObstacle?.distance ?? .max) {
                    nearestObstacle = (position, stand.distance)
                }
            }
            let obstacle: Position
            if let nearestObstacle {
                obstacle = nearestObstacle.position
            } else if let firstUnreachable = inaccessible.first {
                let stands = inaccessible.flatMap { position in Direction.allCases.map(position.neighbor) }
                guard let tree = plan.world.firstTreeForAccess(to: stands) else {
                    return PlanFailure(.unreachable, "No passable approach to the placement.", position: firstUnreachable)
                }
                obstacle = tree
            } else {
                return nil
            }
            let outcome = plan.interact(at: obstacle) { .collect($0, .above) }
            if !outcome.success {
                return PlanFailure(outcome, "Could not clear the obstacle at this tile.", position: obstacle)
            }
        }
    }

    private static func escapeDistances(in world: World, walls: Set<Position>) -> [Position: Int] {
        let initial = world.reachability()
        let accessible = Set(initial.arrivals.keys).union([initial.start])
        var unchecked = accessible.subtracting(walls)
        var escape: Set<Position> = []
        var escapeDistance = Int.max
        while let start = unchecked.min(by: positionOrder) {
            let reachable = world.reachability(from: start, avoiding: walls)
            let area = Set(reachable.arrivals.keys).union([start])
            unchecked.subtract(area)
            let nearest = area.compactMap { initial.distance(to: $0) }.min() ?? .max
            if area.count > escape.count || (area.count == escape.count && nearest < escapeDistance) {
                escape = area
                escapeDistance = nearest
            }
        }

        // Measure from the exit with future walls still open. Building from farthest to nearest
        // leaves each wall an adjacent stand on a shorter, still-open path to the exit.
        var distances = Dictionary(uniqueKeysWithValues: escape.map { ($0, 0) })
        var queue = Array(escape)
        var next = 0
        while next < queue.count {
            let position = queue[next]
            next += 1
            let distance = distances[position, default: 0]
            for direction in Direction.allCases {
                let neighbor = position.neighbor(direction)
                guard accessible.contains(neighbor), distances[neighbor] == nil else { continue }
                distances[neighbor] = distance + 1
                queue.append(neighbor)
            }
        }
        return distances
    }

    private static func place(_ placements: [BlueprintPlacement], in plan: inout WorldPlan,
                              toward escape: [Position: Int]? = nil) -> PlanFailure? {
        var remaining = placements
        while let first = remaining.first {
            let reachability = plan.world.reachability()
            let furthest = escape.flatMap { distances in remaining.compactMap { distances[$0.position] }.max() }
            var best: (index: Int, stand: Position, distance: Int)?
            for (index, placement) in remaining.enumerated() {
                if let escape, escape[placement.position] != furthest { continue }
                let stand = reachability.closestStand(to: placement.position) {
                    guard let escape, let furthest else { return true }
                    return escape[$0, default: .max] < furthest
                }
                if let stand, stand.distance < (best?.distance ?? .max) {
                    best = (index, stand.position, stand.distance)
                }
            }
            guard let best else {
                let blocked = remaining.first { escape?[$0.position] == furthest } ?? first
                return PlanFailure(.unreachable, "No reachable stand that preserves safe access.",
                                   position: blocked.position)
            }
            let placement = remaining.remove(at: best.index)
            let outcome = plan.interact(at: placement.position, standingAt: best.stand) { .place($0, placement.structure) }
            if !outcome.success {
                return PlanFailure(outcome, "Could not place \(placement.structure.rawValue) here.",
                                   position: placement.position)
            }
        }
        return nil
    }

    private static func positionOrder(_ lhs: Position, _ rhs: Position) -> Bool {
        (lhs.y, lhs.x) < (rhs.y, rhs.x)
    }
}
