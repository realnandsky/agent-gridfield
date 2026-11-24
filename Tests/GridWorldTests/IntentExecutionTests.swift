import Testing
@testable import GridWorld

@Test func intentInterruptKeepsAppliedWalkAndSkipsRemainingActions() throws {
    var world = World(bushCount: 0)
    let destination = Position(x: 10, y: 5)
    var intent = IntentExecution(actions: [.walkTo(destination), .world(.finish)])
    let preparation = try #require(intent.preparation(in: world))
    intent.accept(preparation.prepare())

    let advance = intent.advance(world: &world)
    let step = try #require(advance)
    #expect(step.outcome == nil)
    #expect(world.avatar == Position(x: 9, y: 5))

    let interrupted = intent.interrupt(in: world)
    let interruption = try #require(interrupted)
    #expect(interruption.outcome == .interrupted)
    #expect(interruption.history?.avatar == [9, 5])
    let next = intent.advance(world: &world)
    #expect(next == nil)

    let receipt = intent.receipt(observation: world.observation(), memory: nil, recentHistory: nil)
    #expect(receipt.results == [.interrupted])
    #expect(receipt.skipped == 1)
    #expect(receipt.walks?.first?.steps == 1)
    #expect(receipt.walks?.first?.destination == [10, 5])
    #expect(receipt.observation.avatar == Position(x: 9, y: 5))
}

@Test func intentWalkChecksTheLiveNextTile() throws {
    var world = World(bushCount: 0, inventory: [.plank: 1])
    let destination = Position(x: 10, y: 5)
    var intent = IntentExecution(actions: [.walkTo(destination)])
    let preparation = try #require(intent.preparation(in: world))
    intent.accept(preparation.prepare())
    _ = intent.advance(world: &world)
    let placement = world.apply(.place(.east, .wall))
    try #require(placement == .placed)

    let advance = intent.advance(world: &world)
    let blocked = try #require(advance)
    #expect(blocked.outcome == .wallBlocked)
    #expect(world.avatar == Position(x: 9, y: 5))
    #expect(world.tile(at: destination)?.fixture == .wall)
    let receipt = intent.receipt(observation: world.observation(), memory: nil, recentHistory: nil)
    #expect(receipt.walks?.first?.steps == 1)
}

@Test func preparedCollectionDoesNotRemoveAReplacementFixture() throws {
    var world = World(bushCount: 0, inventory: [.plank: 1])
    let target = Position(x: 8, y: 4)
    var intent = IntentExecution(actions: [.collectAt(target, .above)])
    let preparation = try #require(intent.preparation(in: world))
    intent.accept(preparation.prepare())
    let collection = world.apply(.collect(.north, .above))
    let placement = world.apply(.place(.north, .wall))
    try #require(collection == .collected)
    try #require(placement == .placed)

    let advance = intent.advance(world: &world)
    let blocked = try #require(advance)
    #expect(blocked.outcome == .blockUnavailable)
    #expect(world.tile(at: target)?.fixture == .wall)
}

@Test func interruptedAcquisitionReportsOnlyCompletedPhysicalSteps() throws {
    var world = World(bushCount: 0)
    let tree = Position(x: 8, y: 4)
    var intent = IntentExecution(actions: [.acquire(.log, count: 2)])
    let preparation = try #require(intent.preparation(in: world))
    intent.accept(preparation.prepare())

    let advance = intent.advance(world: &world)
    let fellTree = try #require(advance)
    #expect(fellTree.outcome == nil)
    #expect(world.tile(at: tree)?.terrain == .grass)
    #expect(world.tile(at: tree)?.items[.log] == 2)
    #expect(world.inventory[.log] == nil)

    _ = intent.interrupt(in: world)
    let receipt = intent.receipt(observation: world.observation(), memory: nil, recentHistory: nil)
    #expect(receipt.results == [.interrupted])
    #expect(receipt.plans?.first?.steps == 1)
    #expect(receipt.plans?.first?.failure?.outcome == .interrupted)
    #expect(receipt.observation.inventory["log"] == nil)
}
