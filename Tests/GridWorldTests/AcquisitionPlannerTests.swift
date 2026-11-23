import Testing
@testable import GridWorld

@Test func acquisitionUsesCarriedAndLooseStockBeforeCrafting() throws {
    var world = World(bushCount: 0)
    try #require(world.apply(.collect(.north, .above)) == .collected)
    try #require(world.apply(.collect(.north, .item(.log))) == .collected)
    try #require(world.apply(.craft(.plank)) == .crafted)
    try #require(world.apply(.drop(.east, .plank)) == .dropped)

    var plan = WorldPlan(world: world)
    #expect(AcquisitionPlanner.provision([.plank: 3], in: &plan) == nil)
    #expect(plan.actions.isEmpty)
    #expect(AcquisitionPlanner.provision([.plank: 4], in: &plan) == nil)
    #expect(plan.world.inventory == [.plank: 4])
    let pickup = try #require(plan.actions.first)
    if case .collect(.east, .item(.plank), count: 1) = pickup {
        #expect(plan.actions.count == 1)
    } else {
        Issue.record("Expected to pick up the loose plank.")
    }
}

@Test func acquisitionReservesInputsAndReplaysEveryRecipeAndHarvest() throws {
    let world = World(bushCount: .max)
    let initialReachability = world.reachability()
    var branchCount = 0
    for (y, row) in world.observation().view.enumerated() {
        for (x, tile) in row.enumerated()
        where initialReachability.closestStand(to: Position(x: x, y: y)) != nil {
            branchCount += tile.items[.branch, default: 0] + tile.resources[.branch, default: 0]
        }
    }
    let targets: [Item: Int] = [.branch: branchCount, .log: 1, .grass: 1, .plank: 5, .grassBed: 1]
    var plan = WorldPlan(world: world)
    try #require(AcquisitionPlanner.provision(targets, in: &plan) == nil)
    #expect(plan.world.inventory == [.branch: branchCount, .log: 1, .grass: 1, .plank: 6, .grassBed: 1])

    var replay = world
    var crafts: [Recipe] = []
    var fells = 0
    var gatheredLogs = 0
    for action in plan.actions {
        if case .craft(let recipe, count: 1) = action { crafts.append(recipe) }
        if case .collect(let direction, .above, _) = action,
           replay.tile(at: replay.avatar.neighbor(direction))?.terrain == .tree {
            fells += 1
        }
        if case .collect(_, .item(.log), let count) = action { gatheredLogs += count }
        try #require(replay.apply(action).success)
    }
    #expect(crafts == [.plank, .plank, .grassBed])
    #expect(fells == 2)
    #expect(gatheredLogs == 3)
    #expect(replay == plan.world)
}

@Test func acquisitionCanOpenATreeRouteToOtherwiseInaccessibleGrass() throws {
    let world = World(bushCount: .max)
    let reachability = world.reachability()
    let grass = world.observation().view.enumerated().flatMap { y, row in
        row.enumerated().compactMap { x, tile in tile.hasBush ? Position(x: x, y: y) : nil }
    }
    let reachableGrass = grass.count { reachability.closestStand(to: $0) != nil }
    try #require(grass.count > reachableGrass)
    var plan = WorldPlan(world: world)
    try #require(AcquisitionPlanner.provision([.grass: reachableGrass + 1], in: &plan) == nil)
    #expect(plan.world.inventory == [.grass: reachableGrass + 1])
    let tiles = plan.world.observation().view.flatMap { $0 }
    #expect(tiles.reduce(0) { $0 + $1.items[.log, default: 0] } == World.logsPerTree)
}

@Test func acquisitionReportsShortageAndLeavesThePlanUnchanged() throws {
    let world = World(bushCount: 0)
    var plan = WorldPlan(world: world)
    let failure = try #require(AcquisitionPlanner.provision([.log: .max, .plank: 1], in: &plan))
    #expect(failure.outcome == .invalidArguments)
    #expect(plan.actions.isEmpty)
    #expect(plan.world == world)

    let shortage = try #require(AcquisitionPlanner.provision([.log: 40], in: &plan))
    #expect(shortage.outcome == .missingIngredients)
    #expect(shortage.item == "log")
    #expect(shortage.needed == 40)
    #expect(shortage.available == 32)
    #expect(plan.actions.isEmpty)
    #expect(plan.world == world)
}
