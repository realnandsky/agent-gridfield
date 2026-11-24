import Foundation
import Security
import SwiftUI

enum ThinkingEffort: String, CaseIterable, Codable {
    case automatic, none, low, high, max

    var label: String {
        switch self {
        case .automatic: "Provider Default"
        case .none: "Off"
        case .low: "Low"
        case .high: "High"
        case .max: "Maximum"
        }
    }

    var requestValue: String? { self == .automatic ? nil : rawValue }
}

struct ModelSettings {
    struct Configuration: Codable, Hashable {
        var address: String
        var model: String
        var effort: ThinkingEffort = .automatic
        var streaming: Bool = true
        var visionEnabled: Bool? = nil

        var menuLabel: String { "\(model) · \(address)" }
        var allowsVision: Bool {
            let host = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased()
            let name = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return visionEnabled ?? (
                (host == "api.openai.com" && ["gpt-5-mini", "gpt-5-mini-2025-08-07"].contains(name))
                || (ModelSettings.isZhipuHost(host) && ["glm-5.3-flash", "glm-5.3-flashx"].contains(name))
            )
        }

        func resolve() throws -> ModelSettings {
            try ModelSettings(address: address, model: model, effort: effort, streaming: streaming, visionEnabled: visionEnabled)
        }

        func matches(_ settings: ModelSettings) -> Bool {
            model == settings.model && (try? resolve().endpoint) == settings.endpoint
        }
    }

    private static let defaultConfiguration = Configuration(address: "https://api.openai.com/v1", model: "gpt-5-mini",
                                                          effort: .low)
    static let presets = [
        defaultConfiguration,
        Configuration(address: "https://open.bigmodel.cn/api/paas/v4", model: "glm-5.3-flash", effort: .low),
        Configuration(address: "https://api.deepseek.com", model: "deepseek-flash", effort: .low),
    ]
    private static let configurationsPreference = "ModelAPIConfigurations"
    private static let addressPreference = "ModelAPIAddress"
    private static let modelPreference = "ModelAPIModel"
    private static let effortPreference = "ModelThinkingEffort"
    private static let streamingPreference = "ModelStreaming"

    let address: URL
    let endpoint: URL
    let model: String
    let effort: ThinkingEffort
    let streaming: Bool
    private let visionEnabled: Bool?

    var configuration: Configuration {
        Configuration(address: address.absoluteString, model: model, effort: effort, streaming: streaming,
                      visionEnabled: visionEnabled)
    }

    static var activeConfiguration: Configuration {
        savedConfigurations().first ?? defaultConfiguration
    }

    static func savedConfigurations(in defaults: UserDefaults = .standard) -> [Configuration] {
        if let data = defaults.data(forKey: configurationsPreference),
           let configurations = try? JSONDecoder().decode([Configuration].self, from: data) {
            return configurations
        }
        guard defaults.object(forKey: addressPreference) != nil || defaults.object(forKey: modelPreference) != nil else {
            return []
        }
        return [Configuration(
            address: defaults.string(forKey: addressPreference) ?? defaultConfiguration.address,
            model: defaults.string(forKey: modelPreference) ?? defaultConfiguration.model,
            effort: defaults.string(forKey: effortPreference).flatMap(ThinkingEffort.init(rawValue:)) ?? .automatic,
            streaming: defaults.object(forKey: streamingPreference) as? Bool ?? true
        )]
    }

    init(address: String, model: String, effort: ThinkingEffort = .automatic, streaming: Bool = true,
         visionEnabled: Bool? = nil) throws {
        guard var parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parts.scheme?.lowercased(),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              scheme == "https" || (scheme == "http" && Self.isLoopback(host)) else {
            throw ModelSettingsError.invalidAddress
        }
        parts.scheme = scheme
        parts.host = host
        guard let address = parts.url else { throw ModelSettingsError.invalidAddress }
        let path = parts.percentEncodedPath.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        if path.hasSuffix("/v1") || (Self.isZhipuHost(host) && path == "/api/paas/v4") {
            parts.percentEncodedPath = path + "/chat/completions"
        } else if path.isEmpty {
            parts.percentEncodedPath = host == "api.openai.com" ? "/v1/chat/completions" : "/chat/completions"
        }
        guard let endpoint = parts.url else { throw ModelSettingsError.invalidAddress }
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ModelSettingsError.missingModel }
        self.address = address
        self.endpoint = endpoint
        self.model = name
        self.effort = effort == .none && Self.isGLMFlash(host: host, model: name) ? .low : effort
        self.streaming = streaming
        self.visionEnabled = visionEnabled
    }

    static func isZhipuHost(_ host: String?) -> Bool {
        host == "open.bigmodel.cn" || host == "api.z.ai"
    }

    static func isGLMFlash(host: String?, model: String) -> Bool {
        isZhipuHost(host) && ["glm-5.3-flash", "glm-5.3-flashx", "glm-5.3-flashx-legal"]
            .contains(model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    func makeClient(debugger: APIDebugger, taskGoal: String) throws -> ChatCompletionsModel {
        let key = try ModelKeychain.read(for: endpoint)
        guard key != nil || Self.isLoopback(endpoint.host ?? "") else {
            throw ModelSettingsError.missingKey
        }
        return ChatCompletionsModel(endpoint: endpoint, model: model, apiKey: key, taskGoal: taskGoal,
                                    reasoningEffort: effort.requestValue, streaming: streaming,
                                    visionEnabled: configuration.allowsVision,
                                    debugger: debugger)
    }

    func save(newKey: String, in defaults: UserDefaults = .standard) throws {
        let configurations = [configuration] + Self.savedConfigurations(in: defaults).filter { !$0.matches(self) }
        let data = try JSONEncoder().encode(configurations)
        let key = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            guard key.utf8.allSatisfy({ (33...126).contains($0) }) else {
                throw ModelSettingsError.invalidKey
            }
            try ModelKeychain.save(key, for: endpoint)
        }
        defaults.set(data, forKey: Self.configurationsPreference)
    }

    func removeKey() throws {
        try ModelKeychain.remove(for: endpoint)
    }

    private static func isLoopback(_ host: String) -> Bool {
        ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }
}

private enum ModelKeychain {
    private static func query(for endpoint: URL) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "io.gridworld.macos.model-api",
            kSecAttrAccount as String: endpoint.absoluteString,
        ]
    }

    static func read(for endpoint: URL) throws -> String? {
        var query = query(for: endpoint)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ModelSettingsError.keychain(status) }
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            throw ModelSettingsError.keychain(errSecDecode)
        }
        return key
    }

    static func save(_ key: String, for endpoint: URL) throws {
        let query = query(for: endpoint)
        let values: [String: Any] = [
            kSecValueData as String: Data(key.utf8),
            kSecAttrLabel as String: "Agent Gridfield Model API",
        ]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            let item = query.merging(values) { _, newValue in newValue }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ModelSettingsError.keychain(status) }
    }

    static func remove(for endpoint: URL) throws {
        let status = SecItemDelete(query(for: endpoint) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ModelSettingsError.keychain(status)
        }
    }
}

private enum ModelSettingsError: LocalizedError {
    case invalidAddress, missingModel, missingKey, invalidKey
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidAddress: "Enter an HTTPS API URL. Loopback addresses also support HTTP."
        case .missingModel: "Enter a model name."
        case .missingKey: "Save an API key for this endpoint in Settings."
        case .invalidKey: "Check your API key for spaces or line breaks."
        case .keychain(let status):
            "Could not access macOS Keychain (\(status))."
        }
    }
}

struct ModelSettingsView: View {
    @ViewState private var configurations = ModelSettings.savedConfigurations()
    @ViewState private var draft = ModelSettings.activeConfiguration
    @ViewState private var newKey = ""
    @ViewState private var status: String?
    @ViewState private var error: String?

    private var canDisableThinking: Bool {
        let address = draft.address.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = URLComponents(string: address)?.host?.lowercased()
        return !ModelSettings.isGLMFlash(host: host, model: draft.model)
    }

    private var availablePresets: [ModelSettings.Configuration] {
        ModelSettings.presets.filter { preset in
            guard let settings = try? preset.resolve() else { return false }
            return !configurations.contains { $0.matches(settings) }
        }
    }

    private var configurationMenu: some View {
        Menu("Switch Configuration") {
            if !configurations.isEmpty {
                Section("Saved") {
                    ForEach(configurations, id: \.self) { configuration in
                        Button {
                            apply(configuration, key: "")
                        } label: {
                            if configuration == configurations.first {
                                Label(configuration.menuLabel, systemImage: "checkmark")
                            } else {
                                Text(verbatim: configuration.menuLabel)
                            }
                        }
                    }
                }
            }
            let presets = availablePresets
            if !presets.isEmpty {
                Section("Provider Presets") {
                    ForEach(presets, id: \.self) { preset in
                        Button(preset.menuLabel) {
                            draft = preset
                            newKey = ""
                            status = nil
                        }
                    }
                }
            }
        }
        .fixedSize()
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Configuration") { configurationMenu }
                TextField("API URL", text: $draft.address)
                TextField("Model", text: $draft.model)
                SecureField("API Key", text: $newKey, prompt: Text("Leave blank to keep the saved key"))
                Picker("Planning Effort", selection: Binding(
                    get: { !canDisableThinking && draft.effort == .none ? .low : draft.effort },
                    set: { draft.effort = $0 }
                )) {
                    ForEach(ThinkingEffort.allCases.filter { canDisableThinking || $0 != .none }, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
                Toggle("Stream Responses", isOn: $draft.streaming)
                Toggle("Vision", isOn: Binding(
                    get: { draft.allowsVision },
                    set: { draft.visionEnabled = $0 }
                ))
                .help("Lets models with image input and tool support request a map with coordinates.")
            } footer: {
                Text("Configuration changes take effect on your next run. API keys are stored in macOS Keychain.")
            }
            HStack {
                Button("Remove Key for This URL") {
                    do {
                        try draft.resolve().removeKey()
                        newKey = ""
                        status = "Key removed"
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                Spacer()
                if let status { Text(status).foregroundStyle(.secondary) }
                Button("Save") {
                    apply(draft, key: newKey)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(width: 590)
        .onChange(of: draft) {
            if draft != configurations.first { status = nil }
        }
        .onChange(of: newKey) {
            if !newKey.isEmpty { status = nil }
        }
        .alert("Model Settings", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private func apply(_ configuration: ModelSettings.Configuration, key: String) {
        do {
            let settings = try configuration.resolve()
            try settings.save(newKey: key)
            configurations = ModelSettings.savedConfigurations()
            draft = settings.configuration
            newKey = ""
            status = "Saved"
        } catch {
            self.error = error.localizedDescription
        }
    }
}
