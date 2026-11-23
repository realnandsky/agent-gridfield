import Testing
@testable import GridWorld

@Test func blueprintPlacesAnInteriorAndClosesTheRingFromOutside() throws {
    var world = World(bushCount: 0, inventory: [.plank: 9, .grassBed: 1])
    let center = Position(x: 3, y: 10)
    let route = try #require(world.shortestRoute(to: center))
    for direction in route { try #require(world.apply(.move(direction)) == .moved) }
    let walls = (9...11).flatMap { y in
        (2...4).compactMap { x in
            Position(x: x, y: y) == center ? nil : BlueprintPlacement(x: x, y: y, structure: .wall)
        }
    }
    let blueprint = walls + [
        .init(x: center.x, y: center.y, structure: .grassBed),
        .init(x: center.x, y: center.y, structure: .floor),
    ]
    var plan = WorldPlan(world: world)
    try #require(BlueprintPlanner.build(blueprint, in: &plan) == nil)
    let built = plan.world
    #expect(built.inventory.isEmpty)
    #expect(built.tile(at: center)?.hasFloor == true)
    #expect(built.tile(at: center)?.fixture == .grassBed)
    #expect(built.shortestRoute(to: center) == nil)
    #expect(built.shortestRoute(to: Position(x: 8, y: 5)) != nil)
    #expect(Set(built.wallArms(at: Position(x: 2, y: 9))) == [.east, .south])
    #expect(Set(built.wallArms(at: Position(x: 3, y: 9))) == [.east, .west])
    #expect(Set(built.wallArms(at: Position(x: 4, y: 11))) == [.north, .west])
    for wall in walls { #expect(built.tile(at: wall.position)?.fixture == .wall) }

    var replay = world
    for action in plan.actions { try #require(replay.apply(action).success) }
    #expect(replay == built)

    let steps = plan.actions.count
    try #require(BlueprintPlanner.build(blueprint, in: &plan) == nil)
    #expect(plan.actions.count == steps)
    #expect(plan.world == built)

    var reordered = WorldPlan(world: world)
    try #require(BlueprintPlanner.build(blueprint.reversed(), in: &reordered) == nil)
    #expect(reordered.world == built)
    #expect(reordered.actions.count == steps)
}

@Test func blueprintClearsTreeAccessAndReusesTheLogsForConstruction() throws {
    let world = World(bushCount: 0)
    let location = Position(x: 14, y: 4)
    #expect(world.shortestRoute(to: location) == nil)
    var plan = WorldPlan(world: world)
    try #require(BlueprintPlanner.build([.init(x: location.x, y: location.y, structure: .floor)], in: &plan) == nil)
    #expect(plan.world.tile(at: location)?.hasFloor == true)
    #expect(plan.world.inventory == [.plank: 3])

    let stages: [String] = plan.actions.compactMap {
        switch $0 {
        case .collect(_, .above, _): "cut"
        case .collect(_, .item(.log), _): "pick up"
        case .craft(.plank, _): "craft"
        case .place(_, .floor): "place"
        default: nil
        }
    }
    #expect(stages == ["cut", "pick up", "craft", "place"])
}

@Test func rejectedBlueprintLeavesMaterialsObstaclesAndAvatarUntouched() throws {
    let world = World(bushCount: 0)
    var plan = WorldPlan(world: world)
    let blocked = BlueprintPlanner.build([
        .init(x: 8, y: 4, structure: .floor),
        .init(x: 7, y: 5, structure: .wall),
    ], in: &plan)
    #expect(blocked?.outcome == .buildBlocked)
    #expect(blocked?.position == [7, 5])
    #expect(plan.world == world)
    #expect(plan.actions.isEmpty)

    let shortage = BlueprintPlanner.build([.init(x: 8, y: 4, structure: .grassBed)], in: &plan)
    #expect(shortage?.outcome == .missingIngredients)
    #expect(shortage?.item == "grass")
    #expect(plan.world == world)
    #expect(plan.actions.isEmpty)
}
