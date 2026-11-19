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
        Window("Agent Gridfield", id: "world") {
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
                    let bundle = Bundle.main
                    let prefix = bundle.object(forInfoDictionaryKey: "GridWorldVersionPrefix") as? String ?? ""
                    let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                    let options: [NSApplication.AboutPanelOptionKey: Any] =
                        version.map { [.applicationVersion: prefix + $0] } ?? [:]
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
            GameActivity(messages: session.messages)
        }
        .padding(18)
        .frame(minWidth: 640, minHeight: 480)
        .inspector(isPresented: $showDebug) {
            APIDebugView(debugger: debugger, session: session)
                .inspectorColumnWidth(min: 315, ideal: 420, max: 720)
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

                WorldMap(world: session.world)
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

                Spacer(minLength: 12)

                if session.isRunning {
                    Text(debugger.exchanges.last?.outcome.liveLabel ?? "Running actions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Button("Start", action: start)
                        .buttonStyle(.borderedProminent)
                        .disabled(session.isRunning || currentGoal.isEmpty)
                    Button("Stop", action: session.stop)
                        .buttonStyle(.bordered)
                        .disabled(!session.isRunning)
                }
                .controlSize(.regular)
            }
            .frame(width: 132)
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

private struct GameActivity: View {
    let messages: [CharacterMessage]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Activity")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if messages.isEmpty {
                            Text("No character messages yet.")
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9)
                }
                .onChange(of: messages.last?.id, initial: true) { _, latest in
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
