import Foundation

struct IntentExecution {
    enum Step {
        case world
        case walk(Int)
        case plan(Int, HistoryEvent)
        case message(String)
    }

    struct Update {
        let index: Int
        let step: Step?
        let outcome: ActionOutcome?
        let history: HistoryEvent?
    }

    struct Preparation: Sendable {
        fileprivate let index: Int
        fileprivate let action: CharacterAction
        fileprivate let world: World

        var isExpensive: Bool { action.usesPlanner }

        func prepare() -> PreparedAction {
            switch action {
            case .walkTo(let destination):
                guard let route = world.shortestRoute(to: destination) else {
                    let outcome: ActionOutcome = world.tile(at: destination) == nil ? .boundary : .unreachable
                    return prepared(outcome)
                }
                return prepared(.arrived, primitives: route.map(WorldAction.move), walkDestination: destination)
            case .collectAt(let target, let selection, let count):
                var candidate = world
                let interaction = candidate.interact(at: target) { .collect($0, selection, count: count) }
                return prepared(interaction.outcome, primitives: interaction.actions, walkDestination: candidate.avatar)
            case .placeAt(let target, let structure, let stand):
                var candidate = world
                let interaction = candidate.interact(at: target, standingAt: stand) { .place($0, structure) }
                return prepared(interaction.outcome, primitives: interaction.actions, walkDestination: candidate.avatar)
            case .acquire(let item, let count):
                var plan = WorldPlan(world: world)
                if let failure = AcquisitionPlanner.provision([item: count], in: &plan) {
                    return prepared(failure.outcome, failure: failure)
                }
                return prepared(.acquired, primitives: plan.actions)
            case .buildBlueprint(let placements):
                var plan = WorldPlan(world: world)
                if let failure = BlueprintPlanner.build(placements, in: &plan) {
                    return prepared(failure.outcome, failure: failure)
                }
                return prepared(.built, primitives: plan.actions)
            case .world, .say, .invalid:
                return prepared(.invalidArguments)
            }
        }

        private func prepared(_ outcome: ActionOutcome, primitives: [WorldAction] = [],
                              walkDestination: Position? = nil, failure: PlanFailure? = nil) -> PreparedAction {
            // Keep the origin and target of each operation. An unrelated live world change can
            // coexist with the intent, and a changed origin or operation target can stop it safely.
            var candidate = world
            var steps: [Primitive] = []
            steps.reserveCapacity(primitives.count)
            for action in primitives {
                let step = Primitive(action: action, world: candidate)
                let result = candidate.apply(action)
                guard result.success else {
                    let failure = PlanFailure(result, "The planned step is no longer possible.", position: step.target)
                    return PreparedAction(index: index, origin: world.avatar, outcome: result, failure: failure)
                }
                steps.append(step)
            }
            return PreparedAction(index: index, origin: world.avatar, outcome: outcome, steps: steps,
                                  walkDestination: walkDestination, failure: failure)
        }
    }

    struct PreparedAction: Sendable {
        fileprivate let index: Int
        fileprivate let origin: Position
        fileprivate let outcome: ActionOutcome
        fileprivate var steps: [Primitive] = []
        fileprivate var walkDestination: Position? = nil
        fileprivate var failure: PlanFailure? = nil
    }

    fileprivate struct Primitive: Sendable {
        private enum Above: Equatable, Sendable {
            case tree, bush, fixture(Structure), empty

            init(_ tile: Tile?) {
                if tile?.terrain == .tree { self = .tree }
                else if tile?.hasBush == true { self = .bush }
                else if let fixture = tile?.fixture { self = .fixture(fixture) }
                else { self = .empty }
            }
        }

        let action: WorldAction
        let origin: Position
        let target: Position
        private let above: Above?

        init(action: WorldAction, world: World) {
            self.action = action
            origin = world.avatar
            switch action {
            case .move(let direction), .collect(let direction, _, _),
                 .place(let direction, _), .drop(let direction, _):
                target = origin.neighbor(direction)
            case .craft, .finish:
                target = origin
            }
            if case .collect(_, .above, _) = action {
                above = Above(world.tile(at: target))
            } else {
                above = nil
            }
        }

        func apply(to world: inout World) -> ActionOutcome {
            guard world.avatar == origin else { return .interrupted }
            if let above, above != Above(world.tile(at: target)) { return .blockUnavailable }
            return world.apply(action)
        }
    }

    private let actions: [CharacterAction]
    private let malformed: Bool
    private(set) var results: [ActionOutcome] = []
    private var walks: [ToolReceipt.Walk] = []
    private var plans: [ToolReceipt.Plan] = []
    private var prepared: PreparedAction?
    private var stepsExecuted = 0
    private var movementSteps = 0

    init(actions: [CharacterAction]) {
        malformed = actions.isEmpty
        self.actions = actions.isEmpty ? [.invalid] : actions
    }

    var actionCount: Int { actions.count }
    var skipped: Int { isComplete ? actions.count - results.count : 0 }
    var isComplete: Bool {
        results.count == actions.count || results.last.map { !$0.success || $0 == .finished } == true
    }
    var currentActionIndex: Int? { isComplete ? nil : results.count }

    func preparation(in world: World) -> Preparation? {
        guard prepared == nil, let index = currentActionIndex else { return nil }
        switch actions[index] {
        case .walkTo, .collectAt, .placeAt, .acquire, .buildBlueprint:
            return Preparation(index: index, action: actions[index], world: world)
        case .world, .say, .invalid:
            return nil
        }
    }

    mutating func accept(_ prepared: PreparedAction) {
        guard currentActionIndex == prepared.index, self.prepared == nil else { return }
        self.prepared = prepared
    }

    mutating func advance(world: inout World) -> Update? {
        guard let index = currentActionIndex else { return nil }
        let action = actions[index]
        switch action {
        case .world(let primitive):
            let origin = world.avatar
            let outcome = world.apply(primitive)
            let step: Step? = outcome.success && outcome != .finished ? .world : nil
            return complete(index, outcome, origin: origin, step: step)
        case .say(let message):
            return complete(index, .messageSent, origin: world.avatar, step: .message(message))
        case .invalid:
            return complete(index, .invalidArguments, origin: world.avatar)
        case .walkTo, .collectAt, .placeAt, .acquire, .buildBlueprint:
            guard let prepared else { return nil }
            guard stepsExecuted < prepared.steps.count else {
                return completePrepared(prepared, action: action, in: world)
            }

            let primitive = prepared.steps[stepsExecuted]
            let outcome = primitive.apply(to: &world)
            guard outcome.success else {
                let reason = outcome == .interrupted ? "The avatar moved while the intent was executing." :
                    "A planned step could not be applied to the current world."
                let failure = PlanFailure(outcome, reason, position: primitive.target)
                return complete(index, outcome, origin: world.avatar, failure: failure)
            }

            stepsExecuted += 1
            let step: Step
            if case .move = primitive.action {
                movementSteps += 1
                step = .walk(stepsExecuted)
            } else if action.usesPlanner,
                      let history = HistoryEvent(action: .world(primitive.action), result: outcome, from: primitive.origin) {
                step = .plan(stepsExecuted, history)
            } else {
                step = .world
            }
            if stepsExecuted == prepared.steps.count {
                return completePrepared(prepared, action: action, in: world, step: step)
            }
            return Update(index: index, step: step, outcome: nil, history: nil)
        }
    }

    mutating func interrupt(in world: World) -> Update? {
        guard let index = currentActionIndex else { return nil }
        let failure = PlanFailure(.interrupted, "The intent was interrupted.", position: world.avatar)
        return complete(index, .interrupted, origin: world.avatar, failure: failure)
    }

    func receipt(observation: WorldObservation, memory: MemoryReceipt?, recentHistory: [[HistoryEvent]]?) -> ToolReceipt {
        ToolReceipt(results: results, skipped: skipped, observation: observation,
                    walks: walks.isEmpty ? nil : walks, plans: plans.isEmpty ? nil : plans,
                    memory: memory, recentHistory: recentHistory)
    }

    private mutating func completePrepared(_ prepared: PreparedAction, action: CharacterAction,
                                           in world: World, step: Step? = nil) -> Update {
        if prepared.outcome.success {
            if case .walkTo(let destination) = action, world.avatar != destination {
                return complete(prepared.index, .interrupted, origin: world.avatar, step: step)
            }
            if case .acquire(let item, let count) = action, world.inventory[item, default: 0] < count {
                let failure = PlanFailure(.missingIngredients, "The inventory target is no longer met.",
                                          item: item, needed: count, available: world.inventory[item, default: 0])
                return complete(prepared.index, failure.outcome, origin: world.avatar, step: step, failure: failure)
            }
            if case .buildBlueprint(let placements) = action,
               let missing = placements.first(where: { placement in
                   guard let tile = world.tile(at: placement.position) else { return true }
                   if placement.structure == .floor { return !tile.hasFloor }
                   if placement.structure == .wall { return tile.fixture?.blocksMovement != true }
                   return tile.fixture != placement.structure
               }) {
                let failure = PlanFailure(.interrupted, "A blueprint placement changed while the intent was executing.",
                                          position: missing.position)
                return complete(prepared.index, failure.outcome, origin: world.avatar, step: step, failure: failure)
            }
        }
        return complete(prepared.index, prepared.outcome, origin: prepared.origin, step: step, failure: prepared.failure)
    }

    private mutating func complete(_ index: Int, _ outcome: ActionOutcome, origin: Position,
                                   step: Step? = nil, failure: PlanFailure? = nil) -> Update {
        let action = actions[index]
        if case .walkTo(let destination) = action, outcome == .arrived || outcome == .interrupted || movementSteps > 0 {
            walks.append(.init(index: index, destination: [destination.x, destination.y], steps: movementSteps))
        } else if !outcome.success, movementSteps > 0, let destination = prepared?.walkDestination {
            walks.append(.init(index: index, destination: [destination.x, destination.y], steps: movementSteps))
        }
        if action.usesPlanner {
            plans.append(.init(index: index, steps: stepsExecuted, failure: failure))
        }
        results.append(outcome)
        prepared = nil
        stepsExecuted = 0
        movementSteps = 0
        let history = malformed ? nil : HistoryEvent(action: action, result: outcome, from: origin)
        return Update(index: index, step: step, outcome: outcome, history: history)
    }
}

private extension CharacterAction {
    var usesPlanner: Bool {
        switch self {
        case .acquire, .buildBlueprint: true
        default: false
        }
    }
}
