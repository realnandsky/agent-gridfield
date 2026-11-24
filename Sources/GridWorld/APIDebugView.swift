import SwiftUI

struct APIDebugView: View {
    private enum Payload: String {
        case request, response, plan, notebook
    }

    private enum BrainFilter: String, CaseIterable {
        case all = "All"
        case fast = "Fast"
        case slow = "Slow"

        func matches(_ brain: APIExchange.Brain) -> Bool {
            switch self {
            case .all: true
            case .fast: brain == .fast
            case .slow: brain == .slow
            }
        }
    }

    let debugger: APIDebugger
    let session: GameSession
    @ViewState private var draft: String
    @ViewState private var selection: UUID?
    @ViewState private var brainFilter = BrainFilter.all
    @ViewState private var payload = Payload.request
    @ViewState private var showRaw = false
    @ViewState private var showVision = false
    @ViewState private var selectedVision: UUID?

    init(debugger: APIDebugger, session: GameSession) {
        self.debugger = debugger
        self.session = session
        _draft = ViewState(wrappedValue: debugger.prompt)
    }

    var body: some View {
        let filtered = debugger.exchanges.filter { brainFilter.matches($0.brain) }
        let latest = debugger.exchanges.last
        let latestFiltered = filtered.last
        let selected = debugger.exchanges.last { $0.id == selection } ?? latestFiltered ?? latest

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Developer Tools").font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Vision History", systemImage: "eye") {
                    openVision(session.visionCalls.last?.id)
                }
                .help("Review the agent's vision calls and map images")
            }

            Divider()

            BrainTimelineView(
                session: session,
                debugger: debugger,
                selectedExchangeID: selected?.id
            ) { exchange in
                selectFromTimeline(exchange)
            }

            HStack {
                Text("API Requests").font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if let latestFiltered, selected?.id != latestFiltered.id {
                    Button("Show Latest") { selection = latestFiltered.id }
                }
                Button("Clear", action: debugger.clear)
                    .disabled(latest == nil)
                    .help("Clear API requests")
            }

            if latest != nil {
                HStack(spacing: 8) {
                    Picker("Brain filter", selection: $brainFilter) {
                        ForEach(BrainFilter.allCases, id: \.self) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.small)

                    Text("\(filtered.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if filtered.isEmpty {
                    Text("No \(brainFilter.rawValue) Brain requests yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 55)
                        .border(Color(nsColor: .separatorColor))
                } else {
                    ScrollViewReader { proxy in
                        List(selection: $selection) {
                            ForEach(filtered.reversed()) { exchange in
                                exchangeRow(exchange)
                                    .tag(exchange.id)
                                    .id(exchange.id)
                            }
                        }
                        .listStyle(.plain)
                        .frame(minHeight: 55, idealHeight: 104, maxHeight: 124)
                        .border(Color(nsColor: .separatorColor))
                        .accessibilityLabel("API request history")
                        .onChange(of: selection) { _, target in
                            if let target { proxy.scrollTo(target) }
                        }
                    }
                }

                if let selected {
                    Text(verbatim: selected.address)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
            }

            HStack {
                Picker("Debug view", selection: $payload) {
                    Text("Request").tag(Payload.request)
                    Text("Response").tag(Payload.response)
                    Text("Plan").tag(Payload.plan)
                    Text("Notebook").tag(Payload.notebook)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                if payload == .request || payload == .response {
                    Toggle("Raw", isOn: $showRaw)
                        .help("Show the unformatted body")
                }
            }

            if payload == .notebook {
                let entries = session.memoryEntries.sorted { $0.key < $1.key }.map { "\($0.key)\n\($0.value)" }
                let text = ([session.notebook].filter { !$0.isEmpty } + entries).joined(separator: "\n\n")
                payloadView(body: text.isEmpty ? "The agent hasn't left any notes yet." : text, headers: "", formatJSON: false)
                    .accessibilityLabel("Agent notebook")
            } else if payload == .plan {
                planView(selectedExchange: selected)
            } else if let selected {
                details(for: selected)
            } else {
                Text("No API requests yet.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            Text("Additional Instructions").font(.headline)
            TextEditor(text: $draft)
                .font(.body)
                .frame(minHeight: 58, idealHeight: 80, maxHeight: 110)
                .border(Color(nsColor: .separatorColor))
                .accessibilityLabel("Additional instructions")
            HStack {
                Text(session.isRunning ? "Wakes the agent now" : "Applies on the next run")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Apply", action: applyPrompt)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines) == debugger.prompt)
            }
        }
        .padding(14)
        .sheet(isPresented: $showVision) {
            VisionHistoryView(session: session, selection: $selectedVision)
        }
        .onChange(of: latest?.id, initial: true) { previous, current in
            if selection == nil || selection == previous { selection = current }
        }
    }

    private func selectFromTimeline(_ exchange: APIExchange) {
        selection = exchange.id
        if !brainFilter.matches(exchange.brain) {
            brainFilter = .all
        }
        if payload == .plan || payload == .notebook {
            payload = exchange.outcome.liveLabel == nil ? .response : .request
        }
    }

    private func exchangeRow(_ exchange: APIExchange) -> some View {
        let isSlow = exchange.brain == .slow
        let badgeColor: Color = isSlow ? .purple : .blue
        let hasError: Bool = switch exchange.outcome {
        case .failed: true
        case .response(let status, _, _): !(200..<300).contains(status)
        default: false
        }

        return HStack(spacing: 6) {
            Text(exchange.startedAt, format: .dateTime.hour().minute().second())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Text(isSlow ? "Slow" : "Fast")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(badgeColor)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(badgeColor.opacity(0.14), in: Capsule())

            Text(verbatim: exchange.displaySummary)
                .font(.callout)
                .foregroundStyle(hasError ? .red : .primary)
                .lineLimit(1)
                .truncationMode(.tail)

            if exchange.visionID != nil {
                Image(systemName: "eye")
                    .font(.caption)
                    .foregroundStyle(.teal)
                    .accessibilityLabel("Includes a map image")
            }

            Spacer(minLength: 4)

            if exchange.isLive {
                TimelineView(.periodic(from: exchange.startedAt, by: 0.2)) { context in
                    Text(APIExchange.formatDuration(exchange.duration(until: context.date)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(badgeColor)
                }
            } else {
                Text(APIExchange.formatDuration(exchange.duration()))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func planView(selectedExchange: APIExchange?) -> some View {
        let plan = selectedExchange?.planID.flatMap { session.planRecord(for: $0) } ?? session.latestPlan

        if let plan {
            let slowExchange = debugger.exchanges.last { $0.brain == .slow && $0.planID == plan.id }
            let statusColor: Color = switch plan.status {
            case .planning: .purple
            case .ready: .orange
            case .applied: .green
            case .failed: .red
            case .cancelled: .secondary
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text(plan.status.rawValue)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(statusColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(statusColor.opacity(0.14), in: Capsule())

                        Spacer()

                        if let slowExchange {
                            Button("View Slow Request") {
                                selectFromTimeline(slowExchange)
                                payload = slowExchange.outcome.liveLabel == nil ? .response : .request
                            }
                            .controlSize(.small)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        planRow("Plan ID", value: plan.id.uuidString, monospaced: true)
                        planRow("Created Tick", value: plan.createdTick.map { "#\($0)" } ?? "—", monospaced: true)

                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("Duration")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 84, alignment: .leading)
                            if plan.status == .planning {
                                TimelineView(.periodic(from: plan.startedAt, by: 0.1)) { context in
                                    Text(APIExchange.formatDuration(max(0, context.date.timeIntervalSince(plan.startedAt))))
                                        .font(.caption.monospacedDigit())
                                }
                            } else if let finishedAt = plan.finishedAt {
                                Text(APIExchange.formatDuration(max(0, finishedAt.timeIntervalSince(plan.startedAt))))
                                    .font(.caption.monospacedDigit())
                            } else {
                                Text("—").font(.caption)
                            }
                        }

                        planRow(
                            "Placements",
                            value: plan.placementCount.map { $0 == 1 ? "1 tile" : "\($0) tiles" } ?? "—",
                            monospaced: true
                        )
                        planRow(
                            "Bounds",
                            value: plan.bounds.map { "[\($0[0][0]), \($0[0][1])] → [\($0[1][0]), \($0[1][1])]" } ?? "—",
                            monospaced: true
                        )
                    }

                    if let summary = plan.summary, !summary.isEmpty {
                        planTextSection("Summary", text: summary)
                    }
                    if !plan.brief.isEmpty {
                        planTextSection("Brief", text: plan.brief)
                    }
                    if let reason = plan.failureReason, !reason.isEmpty {
                        planTextSection(
                            plan.status == .failed ? "Failure Reason" : "Cancellation Reason",
                            text: reason,
                            tint: plan.status == .failed ? .red : .secondary
                        )
                    }
                    if plan.status == .planning, let preview = slowExchange?.livePreviewLine {
                        planTextSection("Live Preview", text: preview, tint: .purple)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .border(Color(nsColor: .separatorColor))
            .accessibilityLabel("Background plan details")
        } else {
            Text("No background plan in this run yet.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .border(Color(nsColor: .separatorColor))
        }
    }

    private func planRow(_ label: String, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
            Text(verbatim: value)
                .font(monospaced ? .caption.monospaced() : .caption)
                .textSelection(.enabled)
        }
    }

    private func planTextSection(_ title: String, text: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(verbatim: text)
                .font(.callout)
                .foregroundStyle(tint)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func details(for exchange: APIExchange) -> some View {
        if payload == .request {
            if let visionID = exchange.visionID {
                Button {
                    openVision(visionID)
                } label: {
                    Label("View Sent Map", systemImage: "eye")
                }
                .tint(.teal)
            }
            payloadView(body: exchange.requestBody, headers: exchange.requestHeaders)
        } else {
            switch exchange.outcome {
            case .response(_, let headers, let body):
                payloadView(body: body, headers: headers)
            case .receiving(let status, let phase, let preview):
                payloadView(body: "HTTP \(status) · \(phase)" + (preview.isEmpty ? "" : "\n\n" + preview), headers: "")
            case .waiting, .cancelled:
                Text(exchange.outcome.label)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                payloadView(body: message, headers: "")
            }
        }
    }

    private func payloadView(body: String, headers: String, formatJSON: Bool = true) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if !headers.isEmpty {
                    DisclosureGroup("HTTP Headers") {
                        Text(verbatim: headers).textSelection(.enabled)
                            .font(.system(.caption, design: .monospaced))
                    }
                }
                Text(verbatim: body.isEmpty ? "Empty body" : (formatJSON ? display(body) : body))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .border(Color(nsColor: .separatorColor))
    }

    private func display(_ body: String) -> String {
        guard !showRaw,
              let json = try? JSONSerialization.jsonObject(with: Data(body.utf8)),
              let pretty = try? JSONSerialization.data(
                withJSONObject: json, options: [.prettyPrinted, .withoutEscapingSlashes]
              ) else { return body }
        return String(decoding: pretty, as: UTF8.self)
    }

    private func applyPrompt() {
        draft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        debugger.prompt = draft
        session.playerInstructionsChanged()
    }

    private func openVision(_ id: UUID?) {
        selectedVision = id
        showVision = true
    }
}
