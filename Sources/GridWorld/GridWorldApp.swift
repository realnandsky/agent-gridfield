import AppKit
import SwiftUI

// Keep the State property wrapper available with SDKs that also provide a State macro.
typealias ViewState<Value> = SwiftUI.State<Value>

@main
struct GridWorldApp: App {
    @ViewState private var session: GameSession
    @ViewState private var debugger: APIDebugger
    private let debugExportEnabled: Bool
    private let debugLaunchIssue: String?

    private var releaseLabel: String? {
        let bundle = Bundle.main
        let prefix = bundle.object(forInfoDictionaryKey: "GridWorldVersionPrefix") as? String ?? ""
        return (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).map { prefix + $0 }
    }

    init() {
        let export: DebugExport?
        do {
            export = try DebugExport.launch(arguments: CommandLine.arguments)
            debugLaunchIssue = nil
        } catch {
            export = nil
            debugLaunchIssue = error.localizedDescription
            DebugExport.logger.error("Cannot start debug export: \(error.localizedDescription, privacy: .public)")
        }
        debugExportEnabled = export != nil
        _session = ViewState(wrappedValue: GameSession(debugExport: export))
        _debugger = ViewState(wrappedValue: APIDebugger(debugExport: export))
    }

    var body: some Scene {
        Window(releaseLabel.map { "Agent Gridfield · \($0)" } ?? "Agent Gridfield", id: "world") {
            GameView(session: session, debugger: debugger, debugExportEnabled: debugExportEnabled)
                .safeAreaInset(edge: .top) {
                    if let debugLaunchIssue {
                        Text("Could not start debug export. \(debugLaunchIssue)")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(8)
                    }
                }
        }
        .defaultSize(width: 874, height: 654)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Agent Gridfield") {
                    let options: [NSApplication.AboutPanelOptionKey: Any] =
                        releaseLabel.map { [.applicationVersion: $0] } ?? [:]
                    NSApplication.shared.orderFrontStandardAboutPanel(options: options)
                }
            }
        }

        Settings {
            ModelSettingsView()
        }
    }
}

private struct GameView: View {
    let session: GameSession
    let debugger: APIDebugger
    let debugExportEnabled: Bool
    @AppStorage("TaskGoal") private var taskGoal =
        "Build a small house with wooden walls and corners, a doorway, wood floors, and a grass bed."
    @ViewState private var showDebug = false
    @Environment(\.openSettings) private var openSettings

    private var currentGoal: String { taskGoal.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Goal").font(.headline)
                TextField("Goal", text: $taskGoal, axis: .vertical)
                    .labelsHidden()
                    .lineLimit(1...3)
                    .disabled(session.isRunning)
                    .help("Send this goal to the agent when you select Start")
            }
            worldPane
            Divider()
            GameActivity(messages: session.messages, calls: session.toolActivity)
        }
        .padding(18)
        .frame(minWidth: 640, minHeight: 480)
        .inspector(isPresented: $showDebug) {
            APIDebugView(debugger: debugger, session: session)
                .inspectorColumnWidth(min: 340, ideal: 460, max: 780)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showDebug.toggle()
                } label: {
                    Label("Developer Tools", systemImage: "curlybraces")
                        .labelStyle(.iconOnly)
                }
                .help("Show or hide Developer Tools")

                Button {
                    openSettings()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                        .labelStyle(.iconOnly)
                }
                .help("Open model settings")
            }
        }
        .alert("Model API", isPresented: Binding(
            get: { session.issue != nil },
            set: { if !$0 { session.issue = nil } }
        )) {
            Button("Settings…") { openSettings() }
            Button("Close", role: .cancel) {}
        } message: {
            Text(session.issue ?? "")
        }
        .onChange(of: currentGoal, initial: true) { _, _ in updateDebugInputs() }
        .onChange(of: debugger.prompt) { _, _ in updateDebugInputs() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            updateDebugInputs()
        }
        .onDisappear { session.stop() }
    }

    private var worldPane: some View {
        HStack(spacing: 19) {
            VStack(alignment: .trailing, spacing: 8) {
                Button {
                    session.reset()
                    debugger.clear()
                } label: {
                    Label("Reset World", systemImage: "arrow.counterclockwise")
                }
                .controlSize(.small)
                .help("Stop the current run and reset the map, character, and history")

                WorldMap(world: session.world, ghostPlacements: session.blueprintOverlay)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 12) {
                Text("Inventory")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)

                ForEach(Item.allCases, id: \.rawValue) { item in
                    HStack {
                        Text(item.displayName)
                        Spacer()
                        Text(session.world.inventory[item, default: 0], format: .number).monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                }

                Spacer(minLength: 10)

                DualBrainStatusView(session: session, debugger: debugger)

                if session.canInterruptIntent {
                    Button("Interrupt Intent", systemImage: "hand.raised", action: session.interruptIntent)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Cancel the current intent and background planning, then ask the agent to replan")
                }

                HStack(spacing: 8) {
                    Button("Start", action: start)
                        .buttonStyle(.borderedProminent)
                        .disabled(session.isRunning || currentGoal.isEmpty)
                    Button("Stop", action: session.stop)
                        .buttonStyle(.bordered)
                        .disabled(!session.isRunning)
                        .help("Interrupt the agent and keep changes already made to the world")
                }
                .controlSize(.regular)
            }
            .frame(width: 168)
            .padding(.vertical, 6)
        }
    }

    private func start() {
        do {
            let settings = try ModelSettings.activeConfiguration.resolve()
            let model = try settings.makeClient(debugger: debugger, taskGoal: currentGoal)
            session.start(model: model, inputs: debugInputs(for: settings.configuration))
        } catch {
            session.issue = error.localizedDescription
        }
    }

    private func updateDebugInputs() {
        guard debugExportEnabled else { return }
        session.updateDebugInputs(debugInputs(for: ModelSettings.activeConfiguration))
    }

    private func debugInputs(for configuration: ModelSettings.Configuration) -> GameSession.DebugInputs {
        .init(goal: currentGoal, instructions: debugger.prompt, address: configuration.address,
              model: configuration.model, reasoningEffort: configuration.effort.rawValue,
              streaming: configuration.streaming, visionEnabled: configuration.allowsVision)
    }
}

private struct DualBrainStatusView: View {
    let session: GameSession
    let debugger: APIDebugger

    private var fastStatus: (label: String, color: Color, active: Bool) {
        switch session.phase {
        case .idle: ("Idle", Color.secondary.opacity(0.45), false)
        case .awaitingModel: ("Thinking", .blue, true)
        case .executingIntent: ("Executing", .cyan, true)
        case .waitingForPlan: ("Waiting for plan", .teal.opacity(0.75), true)
        }
    }

    private var activeSlowExchange: APIExchange? {
        debugger.exchanges.last { $0.brain == .slow && $0.isLive }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            brainCapsule(title: "Fast", dotColor: fastStatus.color, active: fastStatus.active) {
                Text(fastStatus.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(fastStatus.active ? .primary : .secondary)
                    .lineLimit(1)
            }

            if session.isPlanning {
                let slow = activeSlowExchange
                let startDate = session.latestPlan?.startedAt ?? slow?.startedAt ?? Date()
                let preview = slow?.livePreviewLine ?? slow?.outcome.liveLabel ?? "Waiting for response"
                brainCapsule(title: "Slow", dotColor: .purple, active: true) {
                    VStack(alignment: .leading, spacing: 2) {
                        TimelineView(.periodic(from: startDate, by: 0.1)) { context in
                            let elapsed = max(0, context.date.timeIntervalSince(startDate))
                            Text("Planning · \(APIExchange.formatDuration(elapsed))")
                                .font(.caption.weight(.medium).monospacedDigit())
                                .lineLimit(1)
                        }
                        Text(verbatim: preview)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            } else if let pending = session.pendingPlanSummary {
                brainCapsule(title: "Slow", dotColor: .orange, active: true) {
                    Text(pending.placementCount == 1 ? "Plan Ready · 1 tile" : "Plan Ready · \(pending.placementCount) tiles")
                        .font(.caption.weight(.medium).monospacedDigit())
                        .lineLimit(1)
                }
            } else {
                brainCapsule(title: "Slow", dotColor: Color.secondary.opacity(0.45), active: false) {
                    Text("Idle")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private func brainCapsule<Content: View>(
        title: String, dotColor: Color, active: Bool, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            active ? dotColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    active ? dotColor.opacity(0.32) : Color(nsColor: .separatorColor).opacity(0.6),
                    lineWidth: 1
                )
        }
    }
}

struct GameActivity: View {
    let messages: [CharacterMessage]
    let calls: [ToolActivity]
    @ViewState private var showsCalls = true

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Activity")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Picker("Activity feed", selection: $showsCalls) {
                    Text("Tool calls (\(calls.count))").tag(true)
                    Text("Messages (\(messages.count))").tag(false)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .fixedSize()
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if showsCalls {
                            if calls.isEmpty {
                                Label("Tool calls will appear when the agent acts.", systemImage: "wrench.and.screwdriver")
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(calls) { call in
                                ToolActivityRow(activity: call)
                            }
                        } else {
                            if messages.isEmpty {
                                Text("No messages yet.")
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(messages) { message in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(verbatim: message.sender).fontWeight(.semibold)
                                    Text(verbatim: message.text)
                                        .textSelection(.enabled)
                                }
                                .accessibilityElement(children: .combine)
                                .id(message.id)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9)
                }
                .onChange(of: showsCalls ? calls.last.map { AnyHashable($0.id) } : messages.last.map { AnyHashable($0.id) }, initial: true) { _, latest in
                    if let latest { proxy.scrollTo(latest, anchor: .bottom) }
                }
            }
            .font(.callout)
            .frame(height: 92)
            .background(.background, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(nsColor: .separatorColor))
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct ToolActivityRow: View {
    let activity: ToolActivity
    @ViewState private var showArguments = false

    private var symbol: String {
        switch activity.tool {
        case .act: "figure.walk"
        case .memory: "book.closed"
        case .vision: "eye"
        case .requestPlan: "map"
        case nil: "wrench"
        }
    }

    var body: some View {
        Button { showArguments.toggle() } label: {
            HStack(spacing: 9) {
                Text("#\(activity.id)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Image(systemName: symbol)
                    .frame(width: 22, height: 22)
                    .foregroundStyle(Color.accentColor)
                    .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 5))
                Text(verbatim: activity.function.name)
                    .font(.system(.callout, design: .monospaced).weight(.medium))
                    .lineLimit(1)
                Spacer()
                if activity.needsAttention { Image(systemName: "exclamationmark.circle") }
                Text(activity.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Inspect call arguments")
        .popover(isPresented: $showArguments) {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(activity.function.name) · Call #\(activity.id)").font(.headline)
                if let failure = activity.planFailure {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: failure.reason)
                        if let position = failure.position {
                            Text("Tile (\(position[0]), \(position[1]))").foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                    .textSelection(.enabled)
                }
                ScrollView {
                    Text(verbatim: activity.function.arguments)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(width: 320)
        }
    }
}
