import SwiftUI

struct APIDebugView: View {
    private enum Payload: String {
        case request, response, notebook
    }

    let debugger: APIDebugger
    let session: GameSession
    @ViewState private var draft: String
    @ViewState private var selection: UUID?
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
        let latest = debugger.exchanges.last
        let selected = debugger.exchanges.last { $0.id == selection } ?? latest

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

            HStack {
                Text("API Requests").font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if let latest, selected?.id != latest.id {
                    Button("Show Latest") { selection = latest.id }
                }
                Button("Clear", action: debugger.clear)
                    .disabled(latest == nil)
                    .help("Clear API requests")
            }

            if let selected {
                List(selection: $selection) {
                    ForEach(debugger.exchanges.reversed()) { exchange in
                        HStack {
                            Text(exchange.startedAt, format: .dateTime.hour().minute().second()).monospacedDigit()
                            Text(exchange.method)
                            if exchange.visionID != nil {
                                Image(systemName: "eye")
                                    .foregroundStyle(.teal)
                                    .accessibilityLabel("Includes a map image")
                            }
                            Spacer()
                            Text(exchange.outcome.label).monospacedDigit()
                        }
                        .tag(exchange.id)
                    }
                }
                .listStyle(.plain)
                .frame(minHeight: 55, idealHeight: 104, maxHeight: 124)
                .border(Color(nsColor: .separatorColor))
                .accessibilityLabel("API request history")

                Text(verbatim: selected.address)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(2)
            }

            HStack {
                Picker("Debug view", selection: $payload) {
                    Text("Request").tag(Payload.request)
                    Text("Response").tag(Payload.response)
                    Text("Notebook").tag(Payload.notebook)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                if payload != .notebook {
                    Toggle("Raw", isOn: $showRaw)
                        .help("Show the unformatted body")
                }
            }

            if payload == .notebook {
                let entries = session.memoryEntries.sorted { $0.key < $1.key }.map { "\($0.key)\n\($0.value)" }
                let text = ([session.notebook].filter { !$0.isEmpty } + entries).joined(separator: "\n\n")
                payloadView(body: text.isEmpty ? "The agent hasn't left any notes yet." : text, headers: "", formatJSON: false)
                    .accessibilityLabel("Agent notebook")
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
