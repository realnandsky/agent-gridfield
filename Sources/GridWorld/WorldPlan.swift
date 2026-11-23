struct PlanFailure: Encodable, Sendable {
    let outcome: ActionOutcome
    let reason: String
    let position: [Int]?
    let item: String?
    let needed: Int?
    let available: Int?

    init(_ outcome: ActionOutcome, _ reason: String, position: Position? = nil,
         item: Item? = nil, needed: Int? = nil, available: Int? = nil) {
        self.outcome = outcome
        self.reason = reason
        self.position = position.map { [$0.x, $0.y] }
        self.item = item?.rawValue
        self.needed = needed
        self.available = available
    }

    private enum CodingKeys: String, CodingKey {
        case reason, position, item, needed, available
    }
}

struct WorldPlan {
    private(set) var world: World
    private(set) var actions: [WorldAction] = []

    init(world: World) {
        self.world = world
    }

    mutating func apply(_ action: WorldAction) -> ActionOutcome {
        let outcome = world.apply(action)
        if outcome.success { actions.append(action) }
        return outcome
    }

    mutating func interact(at target: Position, standingAt stand: Position? = nil,
                           action: (Direction) -> WorldAction) -> ActionOutcome {
        let interaction = world.interact(at: target, standingAt: stand, action: action)
        actions.append(contentsOf: interaction.actions)
        return interaction.outcome
    }
}
