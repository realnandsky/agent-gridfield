import AppKit
import SwiftUI

struct WorldMap: View {
    let world: World

    var body: some View {
        Canvas(opaque: true, colorMode: .nonLinear) { context, size in
            drawWorld(in: context, step: size.width / CGFloat(world.width))
        }
        .aspectRatio(CGFloat(world.width) / CGFloat(world.height), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.black.opacity(0.13), lineWidth: 1)
        }
        .accessibilityLabel("World map")
    }

    @MainActor
    func visionFrame() -> VisionFrame? {
        let step: CGFloat = 40
        let margin: CGFloat = 28
        let mapWidth = CGFloat(world.width) * step
        let mapHeight = CGFloat(world.height) * step
        let width = mapWidth + 2 * margin
        let height = mapHeight + 2 * margin
        let canvas = Canvas(opaque: true, colorMode: .nonLinear) { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(hex: 0xF2F3EC)))
            var map = context
            map.translateBy(x: margin, y: margin)
            drawWorld(in: map, step: step)
            map.stroke(Path(CGRect(x: 0, y: 0, width: mapWidth, height: mapHeight)),
                       with: .color(Color(hex: 0x667069)), lineWidth: 1)

            func number(_ index: Int, at x: CGFloat, _ y: CGFloat) {
                let text = Text(verbatim: String(index))
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color(hex: 0x323D37))
                context.draw(text, at: CGPoint(x: x, y: y))
            }
            for column in 0..<world.width {
                let x = margin + (CGFloat(column) + 0.5) * step
                number(column, at: x, margin / 2)
                number(column, at: x, height - margin / 2)
            }
            for row in 0..<world.height {
                let y = margin + (CGFloat(row) + 0.5) * step
                number(row, at: margin / 2, y)
                number(row, at: width - margin / 2, y)
            }
        }
        .frame(width: width, height: height)
        let renderer = ImageRenderer(content: canvas)
        renderer.isOpaque = true
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return nil }
        return VisionFrame(png: data, width: image.width, height: image.height)
    }

    private func drawWorld(in context: GraphicsContext, step: CGFloat) {
        for row in 0..<world.height {
            for column in 0..<world.width {
                let position = Position(x: column, y: row)
                guard let tile = world.tile(at: position) else { continue }
                var cell = context
                cell.translateBy(x: CGFloat(column) * step, y: CGFloat(row) * step)
                cell.scaleBy(x: step, y: step)
                drawTile(tile, at: position, in: cell)
            }
        }
        var avatar = context
        avatar.translateBy(x: CGFloat(world.avatar.x) * step, y: CGFloat(world.avatar.y) * step)
        avatar.scaleBy(x: step, y: step)
        drawAvatar(in: avatar)
    }

    private func drawTile(_ tile: Tile, at position: Position, in context: GraphicsContext) {
        let variation = (position.x * 7 + position.y * 11 + position.x * position.y) % 4
        let background = tile.terrain == .water ? Self.water[variation] : Self.grass[variation]
        context.fill(Path(CGRect(x: 0, y: 0, width: 1, height: 1)), with: .color(background))
        context.stroke(
            Path { path in
                path.move(to: CGPoint(x: 0, y: 1))
                path.addLines([CGPoint(x: 1, y: 1), CGPoint(x: 1, y: 0)])
            },
            with: .color(.black.opacity(0.12)), lineWidth: 0.018
        )

        switch tile.terrain {
        case .grass: break
        case .water: drawWater(at: position, variation: variation, in: context)
        case .tree: drawTree(branches: tile.resources[.branch, default: 0], in: context)
        }

        if tile.hasBush { drawBush(in: context) }
        if tile.hasFloor { drawFloor(in: context) }
        if let fixture = tile.fixture {
            if fixture == .grassBed {
                drawBed(in: context)
            } else {
                drawWall(world.wallArms(at: position), in: context)
            }
        }

        let items = tile.items.sorted(by: { $0.key.rawValue < $1.key.rawValue })
        let isCompact = tile.terrain == .tree || tile.hasBush || tile.fixture != nil || position == world.avatar
            || items.count > 1
        for (index, entry) in items.enumerated() {
            var item = context
            if isCompact {
                let columns = items.count > 2 ? 3 : 2
                let scale: CGFloat = columns == 3 ? 0.32 : 0.46
                let rows = (items.count + columns - 1) / columns
                item.translateBy(x: 0.02 + CGFloat(index % columns) * scale,
                                 y: 1 - CGFloat(rows - index / columns) * scale)
                item.scaleBy(x: scale, y: scale)
            }
            switch entry.key {
            case .branch: drawBranch(in: item)
            case .log: drawLogs(entry.value, in: item)
            case .grass: drawBush(in: item)
            case .plank: drawPlank(in: item)
            case .grassBed: drawBed(in: item)
            }
        }
    }

    private func drawBush(in context: GraphicsContext) {
        context.fill(ellipse(0.15, 0.67, 0.70, 0.19), with: .color(Color(hex: 0x314731).opacity(0.22)))
        context.fill(ellipse(0.20, 0.42, 0.40, 0.31), with: .color(Color(hex: 0x557D31)))
        context.fill(ellipse(0.45, 0.37, 0.35, 0.37), with: .color(Color(hex: 0x396B38)))
        let blades = Path { path in
            path.move(to: CGPoint(x: 0.50, y: 0.70))
            path.addQuadCurve(to: CGPoint(x: 0.32, y: 0.31), control: CGPoint(x: 0.51, y: 0.44))
            path.move(to: CGPoint(x: 0.52, y: 0.69))
            path.addQuadCurve(to: CGPoint(x: 0.54, y: 0.25), control: CGPoint(x: 0.45, y: 0.43))
            path.move(to: CGPoint(x: 0.57, y: 0.70))
            path.addQuadCurve(to: CGPoint(x: 0.72, y: 0.43), control: CGPoint(x: 0.62, y: 0.48))
        }
        context.stroke(blades, with: .color(Color(hex: 0xAFCA53)),
                       style: StrokeStyle(lineWidth: 0.055, lineCap: .round))
    }

    private func drawFloor(in context: GraphicsContext) {
        context.fill(Path(CGRect(x: 0, y: 0, width: 1, height: 1)), with: .color(Color(hex: 0x8C613F)))
        for (index, color) in [0xD4A778, 0xC59866, 0xDDB389].enumerated() {
            let board = CGRect(x: 0.018, y: 0.018 + CGFloat(index) / 3, width: 0.964, height: 0.301)
            context.fill(Path(board), with: .color(Color(hex: UInt32(color))))
        }
    }

    private func drawWall(_ arms: [Direction], in context: GraphicsContext) {
        if arms.isEmpty {
            context.fill(Path(CGRect(x: 0.30, y: 0.30, width: 0.40, height: 0.40)),
                         with: .color(Color(hex: 0x62412D)))
            context.fill(Path(CGRect(x: 0.37, y: 0.37, width: 0.26, height: 0.26)),
                         with: .color(Color(hex: 0xAF7950)))
            return
        }
        var context = context
        context.clip(to: Path(CGRect(x: 0, y: 0, width: 1, height: 1)))
        let wall = Path { path in
            for arm in arms {
                let end: CGPoint = switch arm {
                case .north: CGPoint(x: 0.5, y: 0)
                case .south: CGPoint(x: 0.5, y: 1)
                case .west: CGPoint(x: 0, y: 0.5)
                case .east: CGPoint(x: 1, y: 0.5)
                }
                path.move(to: CGPoint(x: 0.5, y: 0.5))
                path.addLine(to: end)
            }
        }
        context.stroke(wall, with: .color(Color(hex: 0x62412D)),
                       style: StrokeStyle(lineWidth: 0.40, lineCap: .square))
        context.stroke(wall, with: .color(Color(hex: 0xAF7950)),
                       style: StrokeStyle(lineWidth: 0.26, lineCap: .square))
        context.stroke(wall, with: .color(Color(hex: 0xE0B186)),
                       style: StrokeStyle(lineWidth: 0.065, lineCap: .square))
    }

    private func drawPlank(in context: GraphicsContext) {
        let board = Path(roundedRect: CGRect(x: 0.15, y: 0.37, width: 0.70, height: 0.26), cornerRadius: 0.035)
        context.fill(board, with: .color(Color(hex: 0xE0AF78)))
        context.stroke(board, with: .color(Color(hex: 0x805637)), lineWidth: 0.04)
    }

    private func drawBed(in context: GraphicsContext) {
        let frame = Path(roundedRect: CGRect(x: 0.22, y: 0.10, width: 0.56, height: 0.80), cornerRadius: 0.07)
        let cover = Path(roundedRect: CGRect(x: 0.28, y: 0.37, width: 0.44, height: 0.45), cornerRadius: 0.045)
        let pillow = Path(roundedRect: CGRect(x: 0.31, y: 0.19, width: 0.38, height: 0.17), cornerRadius: 0.05)
        context.fill(frame, with: .color(Color(hex: 0x704B32)))
        context.fill(cover, with: .color(Color(hex: 0xA8BF63)))
        context.fill(pillow, with: .color(Color(hex: 0xF5E2A7)))
    }

    private func drawWater(at position: Position, variation: Int, in context: GraphicsContext) {
        let shore = Path { path in
            for direction in Direction.allCases {
                guard let next = world.tile(at: position.neighbor(direction)), next.terrain != .water else {
                    continue
                }
                let edge: (CGPoint, CGPoint) = switch direction {
                case .north: (CGPoint(x: 0, y: 0.025), CGPoint(x: 1, y: 0.025))
                case .south: (CGPoint(x: 0, y: 0.975), CGPoint(x: 1, y: 0.975))
                case .west: (CGPoint(x: 0.025, y: 0), CGPoint(x: 0.025, y: 1))
                case .east: (CGPoint(x: 0.975, y: 0), CGPoint(x: 0.975, y: 1))
                }
                path.move(to: edge.0)
                path.addLine(to: edge.1)
            }
        }
        context.stroke(shore, with: .color(Color(hex: 0xB9DDD4).opacity(0.65)), lineWidth: 0.048)
        guard variation == 0 || variation == 2 else { return }
        let ripple = Path { path in
            path.move(to: CGPoint(x: 0.22, y: 0.43))
            path.addQuadCurve(to: CGPoint(x: 0.69, y: 0.43), control: CGPoint(x: 0.46, y: 0.51))
            path.move(to: CGPoint(x: 0.43, y: 0.63))
            path.addQuadCurve(to: CGPoint(x: 0.77, y: 0.62), control: CGPoint(x: 0.62, y: 0.68))
        }
        context.stroke(
            ripple, with: .color(Color(hex: 0xD5F1E9).opacity(0.47)),
            style: StrokeStyle(lineWidth: 0.023, lineCap: .round)
        )
    }

    private func drawTree(branches: Int, in context: GraphicsContext) {
        context.fill(ellipse(0.17, 0.72, 0.67, 0.16), with: .color(Color(hex: 0x264B39).opacity(0.20)))
        context.fill(
            Path(roundedRect: CGRect(x: 0.43, y: 0.56, width: 0.14, height: 0.26), cornerRadius: 0.026),
            with: .color(Color(hex: 0x594731))
        )
        context.fill(ellipse(0.14, 0.28, 0.47, 0.44), with: .color(Color(hex: 0x386A4D)))
        context.fill(ellipse(0.39, 0.26, 0.46, 0.44), with: .color(Color(hex: 0x306047)))
        context.fill(ellipse(0.26, 0.10, 0.48, 0.49), with: .color(Color(hex: 0x467D58)))
        context.fill(ellipse(0.36, 0.19, 0.22, 0.095), with: .color(Color(hex: 0x73A472).opacity(0.55)))

        for index in 0..<branches {
            let x = 0.63 + CGFloat(index) * 0.065
            context.fill(ellipse(x, 0.56, 0.039, 0.039), with: .color(Color(hex: 0xF4CE84)))
        }
    }

    private func drawBranch(in context: GraphicsContext) {
        let branch = Path { path in
            path.move(to: CGPoint(x: 0.32, y: 0.67))
            path.addLine(to: CGPoint(x: 0.69, y: 0.36))
            path.move(to: CGPoint(x: 0.49, y: 0.53))
            path.addLine(to: CGPoint(x: 0.43, y: 0.35))
        }
        context.stroke(
            branch, with: .color(Color(hex: 0x5B3628)),
            style: StrokeStyle(lineWidth: 0.19, lineCap: .round, lineJoin: .round)
        )
        context.stroke(
            branch, with: .color(Color(hex: 0xFFC078)),
            style: StrokeStyle(lineWidth: 0.097, lineCap: .round, lineJoin: .round)
        )
    }

    private func drawLogs(_ count: Int, in context: GraphicsContext) {
        for index in (0..<min(count, 2)).reversed() {
            let x = 0.15 + 0.12 * CGFloat(index)
            let y = count == 1 ? 0.38 : 0.49 - 0.18 * CGFloat(index)
            let bark = Path(roundedRect: CGRect(x: x, y: y, width: 0.58, height: 0.24), cornerRadius: 0.11)
            let end = ellipse(x + 0.39, y, 0.19, 0.24)
            context.fill(bark, with: .color(Color(hex: 0x9F6742)))
            context.stroke(bark, with: .color(Color(hex: 0x563B29)), lineWidth: 0.035)
            context.fill(end, with: .color(Color(hex: 0xF0C788)))
            context.stroke(end, with: .color(Color(hex: 0x563B29)), lineWidth: 0.027)
            context.stroke(
                ellipse(x + 0.446, y + 0.063, 0.078, 0.114),
                with: .color(Color(hex: 0xB07B46)), lineWidth: 0.019
            )
        }
    }

    private func drawAvatar(in context: GraphicsContext) {
        context.fill(ellipse(0.12, 0.20, 0.76, 0.73), with: .color(.black.opacity(0.25)))
        context.fill(ellipse(0.11, 0.11, 0.78, 0.78), with: .color(Color(hex: 0x1F2725)))
        context.fill(ellipse(0.165, 0.165, 0.67, 0.67), with: .color(Color(hex: 0xFFF9E8)))
        let body = Path { path in
            path.move(to: CGPoint(x: 0.275, y: 0.68))
            path.addQuadCurve(to: CGPoint(x: 0.725, y: 0.68), control: CGPoint(x: 0.5, y: 0.48))
            path.addQuadCurve(to: CGPoint(x: 0.275, y: 0.68), control: CGPoint(x: 0.5, y: 0.92))
            path.closeSubpath()
        }
        context.fill(body, with: .color(Color(hex: 0xD65937)))
        context.fill(ellipse(0.375, 0.385, 0.082, 0.101), with: .color(Color(hex: 0x1F2725)))
        context.fill(ellipse(0.543, 0.385, 0.082, 0.101), with: .color(Color(hex: 0x1F2725)))
    }

    private func ellipse(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: x, y: y, width: width, height: height))
    }

    private static let grass: [Color] = [0xBBD094, 0xB5CB8B, 0xB1C989, 0xBED296].map(Color.init(hex:))
    private static let water: [Color] = [0x609DA6, 0x5D99A5, 0x66A2AA, 0x629FAA].map(Color.init(hex:))
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double(hex >> 16) / 255,
            green: Double((hex >> 8) & 255) / 255,
            blue: Double(hex & 255) / 255
        )
    }
}
