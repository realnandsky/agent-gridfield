import Foundation
import Testing
@testable import GridWorld

@Test func singleCellMovesAndFullMapView() {
    var world = World()
    let initial = world.observation()
    #expect(initial.inventory.isEmpty)
    #expect(initial.view.count == world.height)
    #expect(initial.view.allSatisfy { $0.count == world.width })
    #expect(initial.avatar == Position(x: 8, y: 5))
    #expect(initial.view[5][8].terrain == .grass)
    #expect(initial.view[4][8].terrain == .tree)
    #expect(initial.view[5][7].terrain == .water)
    #expect(initial.view[5][9].items == [.branch: 1])

    let spawn = world.avatar
    #expect(world.apply(.move(.north)) == .treeBlocked)
    #expect(world.apply(.move(.west)) == .waterBlocked)
    #expect(world.avatar == spawn)
    #expect(world.observation() == initial)
    #expect(world.apply(.move(.east)) == .moved)
    #expect(world.avatar == Position(x: spawn.x + 1, y: spawn.y))
    #expect(world.observation().avatar == world.avatar)
    #expect(world.observation().view == initial.view)

    for _ in 0..<4 { #expect(world.apply(.move(.north)) == .moved) }
    #expect(world.apply(.collect(.north, .above)) == .collected)
    #expect(world.apply(.move(.north)) == .moved)
    let border = world
    #expect(world.avatar == Position(x: 9, y: 0))
    #expect(world.apply(.move(.north)) == .boundary)
    #expect(world.apply(.collect(.north, .above)) == .boundary)
    #expect(world.apply(.drop(.north, .branch)) == .boundary)
    #expect(world == border)
    #expect(world.observation().avatar == Position(x: 9, y: 0))
    #expect(world.observation().view[0][9].terrain == .grass)
    #expect(world.observation().view[8][9].terrain == .tree)
}

@Test func shortestRouteUsesTheSameObstaclesAsMovement() throws {
    var world = World(bushCount: 0)
    let destination = Position(x: 8, y: 3)
    #expect(world.shortestRoute(to: world.avatar) == [])
    #expect(world.shortestRoute(to: Position(x: -1, y: 5)) == nil)
    #expect(world.shortestRoute(to: world.avatar.neighbor(.west)) == nil)
    #expect(world.shortestRoute(to: world.avatar.neighbor(.north)) == nil)

    let route = try #require(world.shortestRoute(to: destination))
    #expect(route.count == 4)
    for direction in route { #expect(world.apply(.move(direction)) == .moved) }
    #expect(world.avatar == destination)

    #expect(world.apply(.collect(.north, .above)) == .collected)
    #expect(world.apply(.collect(.north, .item(.log))) == .collected)
    #expect(world.apply(.craft(.plank)) == .crafted)
    #expect(world.apply(.place(.east, .wallNS)) == .placed)
    #expect(world.shortestRoute(to: world.avatar.neighbor(.east)) == nil)
}

@Test func collectingTreeLeavesLogsAndPreservesLooseItems() {
    var world = World()
    let tree = world.avatar.neighbor(.north)
    #expect(world.apply(.collect(.north, .item(.branch))) == .collected)
    #expect(world.apply(.drop(.north, .branch)) == .dropped)
    let start = world
    #expect(world.apply(.collect(.west, .above)) == .blockUnavailable)
    #expect(world.apply(.collect(.east, .above)) == .blockUnavailable)
    #expect(world == start)
    #expect(world.apply(.collect(.north, .above)) == .collected)
    #expect(world.avatar == start.avatar)
    #expect(world.inventory.isEmpty)
    #expect(world.tile(at: tree)?.terrain == .grass)
    #expect(world.observation().view[tree.y][tree.x].items == [.log: 2, .branch: 1])
    #expect(world.observation().view[tree.y][tree.x].resources.isEmpty)
    #expect(world.apply(.collect(.north, .above)) == .blockUnavailable)
    #expect(world.apply(.collect(.north, .item(.log))) == .collected)
    #expect(world.inventory[.log] == 1)
    #expect(world.apply(.move(.north)) == .moved)
    #expect(world.observation().view[tree.y][tree.x].items == [.log: 1, .branch: 1])
}

@Test func everyLogOnTheMapCanBeCollected() throws {
    var world = World()
    var visited: Set<Position> = []

    func collect() throws {
        let position = world.avatar
        visited.insert(position)
        for direction in Direction.allCases {
            let neighbor = position.neighbor(direction)
            guard !visited.contains(neighbor), let tile = world.tile(at: neighbor), tile.terrain != .water else {
                continue
            }
            if tile.terrain == .tree {
                try #require(world.apply(.collect(direction, .above)) == .collected)
                for _ in 0..<World.logsPerTree {
                    try #require(world.apply(.collect(direction, .item(.log))) == .collected)
                }
            }
            try #require(world.apply(.move(direction)) == .moved)
            try collect()
            let back = try #require(Direction.allCases.first { neighbor.neighbor($0) == position })
            try #require(world.apply(.move(back)) == .moved)
        }
    }

    try collect()
    #expect(world.inventory == [.log: 32])
    #expect(world.apply(.drop(.east, .log)) == .dropped)
    #expect(world.inventory[.log] == 31)
    #expect(world.apply(.collect(.east, .item(.log))) == .collected)
    #expect(world.inventory[.log] == 32)
}

@Test func resourceAndLooseItemTransfersAreAtomic() throws {
    var world = World()
    let tree = world.avatar.neighbor(.north)
    let ground = world.avatar.neighbor(.east)
    #expect(world.tile(at: tree)?.resources == [.branch: 2])
    #expect(world.apply(.collect(.north, .item(.branch))) == .collected)
    #expect(world.tile(at: tree)?.resources == [.branch: 1])
    #expect(world.inventory == [.branch: 1])
    #expect(world.apply(.drop(.north, .branch)) == .dropped)
    let data = try JSONEncoder().encode(world.observation())
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let items = try #require(json["items"] as? [[Any]])
    let treeItems = items.filter { $0[0] as? Int == tree.x && $0[1] as? Int == tree.y }
    #expect(treeItems.count == 1)
    let branches = try #require(treeItems.first)
    #expect(branches[2] as? String == "branch")
    #expect(branches[3] as? Int == 2)
    #expect(world.apply(.collect(.north, .item(.branch))) == .collected)
    #expect(world.tile(at: tree)?.items.isEmpty == true)
    #expect(world.tile(at: tree)?.resources == [.branch: 1])
    #expect(world.apply(.collect(.north, .item(.branch))) == .collected)
    #expect(world.tile(at: tree)?.resources.isEmpty == true)

    let exhausted = world
    #expect(world.apply(.collect(.north, .item(.branch))) == .itemAbsent)
    #expect(world == exhausted)

    #expect(world.apply(.drop(.east, .branch)) == .dropped)
    #expect(world.inventory == [.branch: 1])
    #expect(world.tile(at: ground)?.items == [.branch: 2])
    #expect(world.apply(.collect(.east, .item(.branch))) == .collected)
    #expect(world.tile(at: ground)?.items == [.branch: 1])
    #expect(world.inventory == [.branch: 2])
    #expect(world.apply(.drop(.west, .branch)) == .dropped)
    #expect(world.apply(.drop(.west, .branch)) == .dropped)
    #expect(world.inventory.isEmpty)
    let west = world.avatar.neighbor(.west)
    #expect(world.observation().view[west.y][west.x].items == [.branch: 2])

    let empty = world
    #expect(world.apply(.drop(.west, .branch)) == .itemNotCarried)
    #expect(world == empty)
}

@Test func compactObservationUsesWorldCoordinatesAndOmitsEmptyLists() throws {
    var world = World()
    #expect(world.apply(.collect(.north, .above)) == .collected)
    let data = try JSONEncoder().encode(world.observation())
    let observation = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let groundRows = try #require(observation["ground"] as? [String])
    let aboveRows = try #require(observation["above"] as? [String])
    let ground = groundRows.map(expandMapRow)
    let above = aboveRows.map(expandMapRow)
    #expect(ground.count == 12)
    #expect(above.count == 12)
    try #require((ground + above).allSatisfy { $0.count == 17 })
    #expect(observation["mapEncoding"] as? String == "x_ranges_v1")
    #expect(groundRows[4] == "0=gr 1..7=wa 8..16=gr")
    #expect(ground[4][8] == "gr")
    #expect(above[4][8] == "air")
    #expect(above[8][9] == "tr")
    #expect((observation["avatar"] as? [Int]) == [8, 5])
    let legend = try #require(observation["legend"] as? [String: String])
    #expect(legend["gr"] == "grass")
    #expect(legend["tr"] == "tree")
    #expect(legend["fl"] == "floor")
    #expect((ground + above).flatMap { $0 }.allSatisfy { legend[String($0)] != nil })
    let items = try #require(observation["items"] as? [[Any]])
    #expect(items.count == 19)
    #expect(items.contains { $0[0] as? Int == 8 && $0[1] as? Int == 4
        && $0[2] as? String == "log" && $0[3] as? Int == 2 })
    #expect(items.contains { $0[0] as? Int == 9 && $0[1] as? Int == 8
        && $0[2] as? String == "branch" && $0[3] as? Int == 3 })
    #expect(observation["view"] == nil)
    #expect(observation["branches"] == nil)
    #expect(observation["structures"] == nil)
    #expect(observation["block_state"] == nil)
    #expect((observation["inventory"] as? [String: Int]) == [:])

    let empty = WorldObservation(view: [[Tile(terrain: .grass)]], avatar: Position(x: 0, y: 0), inventory: [:],
                                 notebook: "")
    let emptyData = try JSONEncoder().encode(empty)
    let noLooseItems = try #require(JSONSerialization.jsonObject(with: emptyData) as? [String: Any])
    #expect(noLooseItems["items"] == nil)
}

@Test func bushesSpawnOnEmptyGrassAndAppearInFullMap() throws {
    let world = World()
    let observation = world.observation()
    let bushes = observation.view.flatMap { $0 }.filter(\.hasBush)
    #expect(bushes.count == 12)
    #expect(bushes.allSatisfy { $0.terrain == .grass && $0.items.isEmpty && $0.resources == [.grass: 1] })
    #expect(world.tile(at: world.avatar)?.hasBush == false)
    let data = try JSONEncoder().encode(observation)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let rows = try #require(json["above"] as? [String])
    #expect(rows.flatMap(expandMapRow).filter { $0 == "bu" }.count == bushes.count)
}

@Test func craftPlaceWalkAndRecoverAllStructures() throws {
    var world = World(bushCount: .max)
    let start = world
    #expect(world.apply(.craft(.plank)) == .missingIngredients)
    #expect(world == start)
    #expect(world.apply(.collect(.north, .above)) == .collected)
    #expect(world.apply(.collect(.north, .item(.log))) == .collected)
    #expect(world.apply(.craft(.plank)) == .crafted)
    #expect(world.inventory == [.plank: 4])

    let hasPlanks = world
    #expect(world.apply(.craft(.grassBed)) == .missingIngredients)
    #expect(world.apply(.place(.south, .floor)) == .buildBlocked)
    #expect(world.apply(.place(.west, .floor)) == .buildBlocked)
    #expect(world == hasPlanks)
    #expect(world.apply(.collect(.south, .above)) == .collected)
    #expect(world.apply(.collect(.south, .above)) == .blockUnavailable)
    #expect(world.apply(.move(.east)) == .moved)
    #expect(world.apply(.collect(.north, .above)) == .collected)
    #expect(world.apply(.move(.west)) == .moved)
    #expect(world.apply(.craft(.grassBed)) == .crafted)
    #expect(world.inventory == [.plank: 2, .grassBed: 1])

    #expect(world.apply(.place(.east, .floor)) == .placed)
    #expect(world.apply(.place(.east, .grassBed)) == .placed)
    #expect(world.apply(.place(.east, .wallNS)) == .occupied)
    let data = try JSONEncoder().encode(world.observation())
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let ground = try #require(json["ground"] as? [String])
    let above = try #require(json["above"] as? [String])
    #expect(expandMapRow(ground[5])[9] == "fl")
    #expect(expandMapRow(above[5])[9] == "bed")
    #expect(world.apply(.collect(.east, .ground)) == .collected)
    #expect(world.tile(at: Position(x: 9, y: 5))?.hasFloor == false)
    #expect(world.tile(at: Position(x: 9, y: 5))?.fixture == .grassBed)
    #expect(world.apply(.place(.east, .floor)) == .placed)
    #expect(world.apply(.move(.east)) == .moved)
    #expect(world.apply(.move(.west)) == .moved)
    #expect(world.apply(.collect(.east, .above)) == .collected)
    #expect(world.inventory == [.plank: 1, .grassBed: 1])
    #expect(world.apply(.move(.east)) == .moved)
    #expect(world.apply(.move(.west)) == .moved)
    #expect(world.apply(.collect(.east, .ground)) == .collected)
    #expect(world.apply(.collect(.east, .ground)) == .blockUnavailable)

    for wall in Structure.allCases.filter(\.blocksMovement) {
        #expect(world.apply(.place(.east, wall)) == .placed)
        #expect(world.tile(at: Position(x: 9, y: 5))?.fixture == wall)
        #expect(world.apply(.move(.east)) == .wallBlocked)
        #expect(world.apply(.collect(.east, .above)) == .collected)
    }
    #expect(world.inventory == [.plank: 2, .grassBed: 1])
    #expect(world.apply(.move(.east)) == .moved)
}


func expandMapRow(_ row: String) -> [String] {
    var cells: [String] = []
    for run in row.split(separator: " ") {
        let fields = run.split(separator: "=")
        guard fields.count == 2 else { return [] }
        let bounds = fields[0].components(separatedBy: "..")
        guard bounds.count <= 2, let start = Int(bounds[0]), start == cells.count,
              let end = Int(bounds[bounds.count - 1]), start <= end, end <= 16 else { return [] }
        cells.append(contentsOf: repeatElement(String(fields[1]), count: end - start + 1))
    }
    return cells
}

@Test func blueprintReportsOneSidedWallSeams() {
    let world = World(bushCount: 0)
    let edges = [
        BlueprintPlacement(x: 9, y: 5, structure: .wallEW),
        BlueprintPlacement(x: 8, y: 6, structure: .wallNS),
    ]
    let wrong = world.previewBuild([.init(x: 8, y: 5, structure: .cornerNW)] + edges)
    #expect(wrong.validLayout)
    #expect(wrong.wallSeams?.count == 2)
    #expect(wrong.wallSeams?.map(\.to) == [[8, 6], [9, 5]])
    let correct = world.previewBuild([.init(x: 8, y: 5, structure: .cornerSE)] + edges)
    #expect(correct.validLayout)
    #expect(correct.wallSeams?.isEmpty == true)
    #expect(world.tile(at: Position(x: 8, y: 5))?.fixture == nil)
}
