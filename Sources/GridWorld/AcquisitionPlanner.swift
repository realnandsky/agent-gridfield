enum AcquisitionPlanner {
    // Expand product requirements before ingredients, then craft in the opposite order.
    private static let craftingOrder: [Recipe] = {
        var visited: Set<Item> = []
        var ordered: [Recipe] = []
        func visit(_ recipe: Recipe) {
            guard visited.insert(recipe.output.item).inserted else { return }
            for dependency in Recipe.allCases where recipe.ingredients[dependency.output.item] != nil {
                visit(dependency)
            }
            ordered.append(recipe)
        }
        Recipe.allCases.forEach(visit)
        return ordered
    }()

    static func provision(_ targets: [Item: Int], in plan: inout WorldPlan) -> PlanFailure? {
        guard targets.values.allSatisfy({ $0 >= 0 }) else {
            return PlanFailure(.invalidArguments, "Inventory targets must be nonnegative.")
        }

        var projected = plan
        var demands = targets
        var batches: [Item: Int] = [:]

        // Felling a tree removes its attached branches, so reserve requested branches first.
        if let failure = gather(.branch, to: targets[.branch, default: 0], in: &projected) {
            return failure
        }

        for recipe in craftingOrder.reversed() {
            let output = recipe.output
            let demand = demands.removeValue(forKey: output.item) ?? 0
            if let failure = gather(output.item, to: demand, in: &projected, allowShortage: true) {
                return failure
            }
            let shortfall = max(0, demand - projected.world.inventory[output.item, default: 0])
            let count = shortfall / output.count + (shortfall % output.count == 0 ? 0 : 1)
            guard count > 0 else { continue }
            batches[output.item] = count
            for ingredient in Item.allCases {
                guard let units = recipe.ingredients[ingredient] else { continue }
                let (required, multiplicationOverflow) = units.multipliedReportingOverflow(by: count)
                let (total, additionOverflow) = demands[ingredient, default: 0].addingReportingOverflow(required)
                guard !multiplicationOverflow, !additionOverflow else {
                    return PlanFailure(.invalidArguments, "The inventory targets require too many recipe ingredients.",
                                       item: ingredient)
                }
                demands[ingredient] = total
            }
        }

        for item in Item.allCases {
            if let failure = gather(item, to: demands[item, default: 0], in: &projected) {
                return failure
            }
        }
        for recipe in craftingOrder {
            for _ in 0..<batches[recipe.output.item, default: 0] {
                let outcome = projected.apply(.craft(recipe))
                guard outcome.success else {
                    return PlanFailure(outcome, "Could not craft \(recipe.output.item.rawValue).",
                                       item: recipe.output.item)
                }
            }
        }
        plan = projected
        return nil
    }

    private struct Source {
        enum Kind: Int {
            case loose, bush, tree

            var actions: Int { self == .tree ? 2 : 1 }
        }

        let position: Position
        let kind: Kind
        let count: Int
    }

    private static func sources(of item: Item, in world: World) -> [Source] {
        var sources: [Source] = []
        for y in 0..<world.height {
            for x in 0..<world.width {
                let position = Position(x: x, y: y)
                guard let tile = world.tile(at: position) else { continue }
                let loose = tile.items[item, default: 0]
                let attached = item == .branch ? tile.resources[.branch, default: 0] : 0
                if loose + attached > 0 {
                    sources.append(Source(position: position, kind: .loose, count: loose + attached))
                }
                if item == .grass, tile.hasBush {
                    sources.append(Source(position: position, kind: .bush, count: 1))
                }
                if item == .log, tile.terrain == .tree {
                    sources.append(Source(position: position, kind: .tree, count: loose + World.logsPerTree))
                }
            }
        }
        return sources
    }

    private static func gather(_ item: Item, to target: Int, in plan: inout WorldPlan,
                               allowShortage: Bool = false) -> PlanFailure? {
        while plan.world.inventory[item, default: 0] < target {
            let stock = plan.world.inventory[item, default: 0]
            let candidates = sources(of: item, in: plan.world)
            let reachability = plan.world.reachability()
            let accessible = candidates.compactMap { source in
                reachability.closestStand(to: source.position).map { stand in (source, stand) }
            }
            if let (source, stand) = accessible.min(by: { lhs, rhs in
                let (left, leftStand) = lhs
                let (right, rightStand) = rhs
                return (leftStand.distance + left.kind.actions, left.kind.rawValue,
                        -min(left.count, target - stock), left.position.y, left.position.x)
                    < (rightStand.distance + right.kind.actions, right.kind.rawValue,
                       -min(right.count, target - stock), right.position.y, right.position.x)
            }) {
                let count = min(source.count, target - stock)
                let action: CollectTarget = source.kind == .loose ? .item(item) : .above
                let outcome = plan.interact(at: source.position, standingAt: stand.position) {
                    .collect($0, action, count: source.kind == .loose ? count : 1)
                }
                guard outcome.success else { return collectionFailure(outcome, item: item, at: source.position) }
                if source.kind == .tree {
                    let pickup = plan.apply(.collect(stand.facing, .item(.log), count: count))
                    guard pickup.success else { return collectionFailure(pickup, item: item, at: source.position) }
                }
                continue
            }
            let stands = candidates.flatMap { source in Direction.allCases.map { source.position.neighbor($0) } }
            if let tree = plan.world.firstTreeForAccess(to: stands) {
                let outcome = plan.interact(at: tree) { .collect($0, .above) }
                guard outcome.success else { return collectionFailure(outcome, item: item, at: tree) }
                continue
            }
            if allowShortage { return nil }
            let reason = candidates.isEmpty
                ? "Gathering can supply \(stock) of \(target) required \(item.rawValue). No sources remain."
                : "Gathering can supply \(stock) of \(target) required \(item.rawValue). Remaining sources are unreachable."
            return PlanFailure(.missingIngredients, reason, item: item, needed: target, available: stock)
        }
        return nil
    }

    private static func collectionFailure(_ outcome: ActionOutcome, item: Item, at position: Position) -> PlanFailure {
        PlanFailure(outcome, "Could not gather \(item.rawValue) at (\(position.x), \(position.y)).",
                    position: position, item: item)
    }
}
