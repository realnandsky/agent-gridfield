import SwiftUI

struct BrainTimelineView: View {
    private struct ScrollKey: Equatable {
        let halfSeconds: Int
        let exchangeCount: Int
        let segmentCount: Int
        let handoffCount: Int
    }

    let session: GameSession
    let debugger: APIDebugger
    let selectedExchangeID: UUID?
    let onSelectExchange: (APIExchange) -> Void

    private static let labelColumnWidth: CGFloat = 52
    private static let trackHeight: CGFloat = 96
    private static let laneHeight: CGFloat = 22
    private static let barHeight: CGFloat = 16

    var body: some View {
        if let origin = session.runStartedAt {
            if session.isRunning {
                TimelineView(.periodic(from: origin, by: 0.1)) { context in
                    timelineContainer(origin: origin, now: context.date)
                }
            } else {
                timelineContainer(origin: origin, now: session.runEndedAt ?? Date())
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                headerRow(elapsed: nil)
                Text("Start a run to view Fast, Slow, and Engine activity.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 68)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color(nsColor: .separatorColor))
                    }
            }
        }
    }

    @ViewBuilder
    private func timelineContainer(origin: Date, now: Date) -> some View {
        let endDate = session.isRunning
            ? max(now, origin.addingTimeInterval(0.1))
            : max(session.runEndedAt ?? now, origin.addingTimeInterval(0.1))
        let elapsed = max(0, endDate.timeIntervalSince(origin))
        let runExchanges = debugger.exchanges.filter { $0.startedAt >= origin.addingTimeInterval(-0.05) }

        VStack(alignment: .leading, spacing: 6) {
            headerRow(elapsed: elapsed)

            HStack(alignment: .top, spacing: 0) {
                laneLabels
                GeometryReader { geometry in
                    let availableWidth = max(120, geometry.size.width)
                    let displaySeconds = max(10.0, elapsed * 1.05)
                    let minPixelsPerSecond: CGFloat = 8.0
                    let contentWidth = max(availableWidth, CGFloat(displaySeconds) * minPixelsPerSecond)
                    let pxPerSecond = contentWidth / CGFloat(displaySeconds)
                    let scrollKey = ScrollKey(
                        halfSeconds: Int(elapsed * 2),
                        exchangeCount: runExchanges.count,
                        segmentCount: session.engineSegments.count,
                        handoffCount: session.planHandoffs.count
                    )

                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: true) {
                            HStack(spacing: 0) {
                                timelineTrack(
                                    origin: origin,
                                    now: now,
                                    endDate: endDate,
                                    displaySeconds: displaySeconds,
                                    contentWidth: contentWidth,
                                    pxPerSecond: pxPerSecond,
                                    runExchanges: runExchanges
                                )
                                Color.clear
                                    .frame(width: 1, height: Self.trackHeight)
                                    .id("timeline-tail")
                            }
                        }
                        .onChange(of: scrollKey) { _, _ in
                            if session.isRunning && contentWidth > availableWidth {
                                proxy.scrollTo("timeline-tail", anchor: .trailing)
                            }
                        }
                    }
                }
            }
            .frame(height: Self.trackHeight + 10)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(nsColor: .separatorColor))
                    .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .accessibilityLabel("Fast, Slow, and Engine timeline")
    }

    private func headerRow(elapsed: TimeInterval?) -> some View {
        HStack(spacing: 8) {
            Text("Brain Timeline")
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 7) {
                legendDot("Fast", color: .blue)
                legendDot("Slow", color: .purple)
                legendDot("Engine", color: .green)
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [2, 1.5]))
                        .foregroundStyle(.secondary)
                        .frame(width: 8, height: 6)
                    Text("Wait")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if let elapsed {
                Text(APIExchange.formatDuration(elapsed))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func legendDot(_ title: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title)
        }
    }

    private var laneLabels: some View {
        VStack(alignment: .leading, spacing: 2) {
            laneTitle("Fast", color: .blue)
            laneTitle("Slow", color: .purple)
            laneTitle("Engine", color: .green)
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
        .padding(.horizontal, 6)
        .frame(width: Self.labelColumnWidth, height: Self.trackHeight, alignment: .topLeading)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.6))
                .frame(width: 1)
        }
    }

    private func laneTitle(_ text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(height: Self.laneHeight, alignment: .leading)
    }

    private func timelineTrack(
        origin: Date,
        now: Date,
        endDate: Date,
        displaySeconds: Double,
        contentWidth: CGFloat,
        pxPerSecond: CGFloat,
        runExchanges: [APIExchange]
    ) -> some View {
        let pulse = 0.40 + 0.55 * abs(sin(now.timeIntervalSince(origin) * 3.5))
        let fastExchanges = runExchanges.filter { $0.brain == .fast }
        let slowExchanges = runExchanges.filter { $0.brain == .slow }

        return ZStack(alignment: .topLeading) {
            Canvas { context, size in
                drawGridAndHandoffs(
                    in: context,
                    size: size,
                    origin: origin,
                    displaySeconds: displaySeconds,
                    pxPerSecond: pxPerSecond
                )
            }
            .frame(width: contentWidth, height: Self.trackHeight)
            .allowsHitTesting(false)

            ForEach(fastExchanges) { exchange in
                exchangeBlock(
                    exchange,
                    laneTop: 7,
                    origin: origin,
                    endDate: endDate,
                    pxPerSecond: pxPerSecond,
                    pulse: pulse
                )
            }

            ForEach(slowExchanges) { exchange in
                exchangeBlock(
                    exchange,
                    laneTop: 31,
                    origin: origin,
                    endDate: endDate,
                    pxPerSecond: pxPerSecond,
                    pulse: pulse
                )
            }

            ForEach(session.engineSegments) { segment in
                engineBlock(
                    segment,
                    origin: origin,
                    endDate: endDate,
                    pxPerSecond: pxPerSecond,
                    pulse: pulse,
                    runExchanges: runExchanges
                )
            }

            ForEach(session.planHandoffs) { handoff in
                handoffLabel(handoff, origin: origin, contentWidth: contentWidth, pxPerSecond: pxPerSecond)
            }
        }
        .frame(width: contentWidth, height: Self.trackHeight, alignment: .topLeading)
    }

    private func drawGridAndHandoffs(
        in context: GraphicsContext,
        size: CGSize,
        origin: Date,
        displaySeconds: Double,
        pxPerSecond: CGFloat
    ) {
        let separator = Color(nsColor: .separatorColor).opacity(0.45)
        for y in [CGFloat(27), CGFloat(51), CGFloat(75)] {
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(line, with: .color(separator), lineWidth: 0.75)
        }

        let stepSeconds = Self.tickInterval(for: displaySeconds)
        var second = 0.0
        while second <= displaySeconds {
            let x = CGFloat(second) * pxPerSecond
            if second > 0 {
                var grid = Path()
                grid.move(to: CGPoint(x: x, y: 2))
                grid.addLine(to: CGPoint(x: x, y: 75))
                context.stroke(grid, with: .color(separator.opacity(0.45)), lineWidth: 0.5)
            }
            var tick = Path()
            tick.move(to: CGPoint(x: x, y: 75))
            tick.addLine(to: CGPoint(x: x, y: 79))
            context.stroke(tick, with: .color(separator), lineWidth: 0.75)

            if x < size.width - 14 {
                let label = Text("\(Int(second))s")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                context.draw(
                    label,
                    at: CGPoint(x: second == 0 ? x + 2 : x, y: 87),
                    anchor: second == 0 ? .leading : .center
                )
            }
            second += stepSeconds
        }

        for handoff in session.planHandoffs {
            let x = min(size.width - 2, max(2, CGFloat(max(0, handoff.at.timeIntervalSince(origin))) * pxPerSecond))
            let color: Color = switch handoff.outcome {
            case .ready: .purple
            case .failed: .red
            case .cancelled: .secondary
            }
            var connector = Path()
            connector.move(to: CGPoint(x: x, y: 39))
            connector.addLine(to: CGPoint(x: x, y: 15))
            context.stroke(
                connector,
                with: .color(color.opacity(0.85)),
                style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])
            )
            context.fill(Path(ellipseIn: CGRect(x: x - 2.5, y: 36.5, width: 5, height: 5)), with: .color(color))
            let arrow = Path { path in
                path.move(to: CGPoint(x: x, y: 12))
                path.addLine(to: CGPoint(x: x - 3, y: 17))
                path.addLine(to: CGPoint(x: x + 3, y: 17))
                path.closeSubpath()
            }
            context.fill(arrow, with: .color(color))
        }
    }

    @ViewBuilder
    private func exchangeBlock(
        _ exchange: APIExchange,
        laneTop: CGFloat,
        origin: Date,
        endDate: Date,
        pxPerSecond: CGFloat,
        pulse: Double
    ) -> some View {
        let startOffset = max(0, exchange.startedAt.timeIntervalSince(origin))
        let duration = exchange.duration(until: endDate)
        let x = CGFloat(startOffset) * pxPerSecond
        let minWidth: CGFloat = exchange.brain == .slow ? 8 : 7
        let width = max(minWidth, CGFloat(duration) * pxPerSecond)
        let isSelected = exchange.id == selectedExchangeID
        let failed = exchange.isFailureOutcome
        let cancelled = exchange.isCancelledOutcome

        let fillColor: Color = if failed {
            .red
        } else if cancelled {
            exchange.brain == .slow ? Color.purple.opacity(0.28) : Color.secondary.opacity(0.55)
        } else {
            exchange.brain == .slow ? .purple : .blue
        }

        let labelText: String? = if width >= 56 {
            if exchange.brain == .slow && exchange.isLive {
                "Planning · \(APIExchange.formatDuration(duration))"
            } else {
                exchange.displaySummary
            }
        } else {
            nil
        }

        Button {
            onSelectExchange(exchange)
        } label: {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(fillColor)

                if exchange.brain == .slow && cancelled {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                        .foregroundStyle(Color.purple.opacity(0.85))
                }

                if exchange.isLive {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.white.opacity(pulse))
                            .frame(width: min(5, width * 0.4), height: Self.barHeight - 2)
                            .padding(.trailing, 1)
                    }
                }

                if let labelText {
                    Text(verbatim: labelText)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(cancelled && exchange.brain == .slow ? Color.primary : Color.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 4)
                }

                if isSelected {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.white.opacity(0.9), lineWidth: 2)
                        .overlay {
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Color.primary.opacity(0.75), lineWidth: 0.75)
                        }
                }
            }
            .frame(width: width, height: Self.barHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(x: x, y: laneTop)
        .help("\(exchange.brain == .slow ? "Slow" : "Fast") · \(exchange.displaySummary) · \(APIExchange.formatDuration(duration))")
    }

    @ViewBuilder
    private func engineBlock(
        _ segment: TimelineEngineSegment,
        origin: Date,
        endDate: Date,
        pxPerSecond: CGFloat,
        pulse: Double,
        runExchanges: [APIExchange]
    ) -> some View {
        let startOffset = max(0, segment.startedAt.timeIntervalSince(origin))
        let duration = max(0, (segment.endedAt ?? endDate).timeIntervalSince(segment.startedAt))
        let x = CGFloat(startOffset) * pxPerSecond
        let width = max(6, CGFloat(duration) * pxPerSecond)
        let linked = segment.exchangeID.flatMap { id in runExchanges.first { $0.id == id } }

        let content = ZStack(alignment: .leading) {
            if segment.kind == .waitingForPlan {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1.25, dash: [4, 3]))
                            .foregroundStyle(Color.secondary.opacity(0.75))
                    }
                if width >= 62 {
                    Text("wait_for_plan")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                }
            } else {
                let color: Color = switch segment.status {
                case .running, .completed: .green
                case .interrupted: .orange
                case .failed: .red
                case .stopped: Color.green.opacity(0.65)
                }
                RoundedRectangle(cornerRadius: 4)
                    .fill(color)

                if segment.endedAt == nil {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.white.opacity(pulse))
                            .frame(width: min(5, width * 0.4), height: Self.barHeight - 2)
                            .padding(.trailing, 1)
                    }
                }

                if width >= 48 {
                    Text(verbatim: segment.label)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 4)
                }
            }
        }
        .frame(width: width, height: Self.barHeight)
        .contentShape(Rectangle())

        if let linked {
            Button {
                onSelectExchange(linked)
            } label: {
                content
            }
            .buttonStyle(.plain)
            .offset(x: x, y: 55)
            .help("Engine · \(segment.kind == .waitingForPlan ? "Waiting for plan" : segment.label) · \(APIExchange.formatDuration(duration))")
        } else {
            content
                .offset(x: x, y: 55)
                .help("Engine · \(segment.kind == .waitingForPlan ? "Waiting for plan" : segment.label) · \(APIExchange.formatDuration(duration))")
        }
    }

    private func handoffLabel(
        _ handoff: TimelinePlanHandoff,
        origin: Date,
        contentWidth: CGFloat,
        pxPerSecond: CGFloat
    ) -> some View {
        let rawX = CGFloat(max(0, handoff.at.timeIntervalSince(origin))) * pxPerSecond
        let pillWidth: CGFloat = 64
        let centerX = min(max(pillWidth / 2 + 2, rawX), max(pillWidth / 2 + 2, contentWidth - pillWidth / 2 - 2))
        let color: Color = switch handoff.outcome {
        case .ready: .purple
        case .failed: .red
        case .cancelled: .secondary
        }
        let title = switch handoff.outcome {
        case .ready: "plan_ready"
        case .failed: "plan_failed"
        case .cancelled: "cancelled"
        }

        return Text(verbatim: title)
            .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(.regularMaterial, in: Capsule())
            .overlay {
                Capsule().strokeBorder(color.opacity(0.45), lineWidth: 0.75)
            }
            .frame(width: pillWidth, height: 14)
            .offset(x: centerX - pillWidth / 2, y: 20)
            .allowsHitTesting(false)
    }

    private static func tickInterval(for displaySeconds: Double) -> Double {
        if displaySeconds <= 12 { return 2 }
        if displaySeconds <= 35 { return 5 }
        if displaySeconds <= 90 { return 10 }
        if displaySeconds <= 180 { return 15 }
        return 30
    }
}

private extension APIExchange {
    var isFailureOutcome: Bool {
        switch outcome {
        case .failed: true
        case .response(let status, _, _): !(200..<300).contains(status)
        default: false
        }
    }

    var isCancelledOutcome: Bool {
        if case .cancelled = outcome { return true }
        return false
    }
}
