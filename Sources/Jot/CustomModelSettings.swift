import SwiftUI
import JotCore

/// The optional model outside Apple Intelligence: where it is, its key, and which features use it. Apple Intelligence stays
/// the default; each feature has its own switch, off until turned on, and the group says where text goes first.
struct CustomModelSettings: View {
    @ObservedObject var service: SpeechService
    @State private var endpoint = ""
    @State private var model = ""
    @State private var key = ""
    @State private var hasKey = false
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        SettingsGroup(title: "Custom model", symbol: "server.rack", info: "Use a model server on this Mac, such as Ollama or LM Studio, or a hosted API with your own key, in place of Apple Intelligence. Speech recognition and audio always stay on this Mac.") {
            Text("Off unless you switch a feature on below. Audio never leaves this Mac. A feature switched on sends the text it uses to this endpoint: cleanup sends each live phrase and each dictation it cleans; suggestions send the field, the visible conversation and matching speech. Window images go only to Apple Intelligence.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(JotTheme.Padding.row)
            SettingRow(title: "API", info: "OpenAI-compatible covers Ollama, LM Studio, llama.cpp and most hosted APIs. Anthropic uses its Messages API.") {
                Picker("API", selection: $service.customModelFormat) {
                    Text("OpenAI-compatible").tag(RemoteModelConfiguration.Format.openAICompatible)
                    Text("Anthropic").tag(RemoteModelConfiguration.Format.anthropic)
                }.labelsHidden().pickerStyle(.menu).fixedSize()
            }
            RowDivider()
            SettingRow(title: "Endpoint", info: "The base URL, such as http://localhost:11434/v1 for Ollama, http://localhost:1234/v1 for LM Studio or https://api.anthropic.com/v1. Plain http works only for a server on this Mac.") {
                TextField("http://localhost:11434/v1", text: $endpoint).textFieldStyle(.roundedBorder)
                    .frame(minWidth: 200, idealWidth: 280, maxWidth: 280)
                    .onChange(of: endpoint) { _, value in if value != service.customModelEndpoint { service.customModelEndpoint = value } }
            }
            RowDivider()
            SettingRow(title: "Model", info: "The model name the endpoint expects, such as llama3.2 or qwen3:4b in Ollama.") {
                TextField("llama3.2", text: $model).textFieldStyle(.roundedBorder)
                    .frame(minWidth: 200, idealWidth: 280, maxWidth: 280)
                    .onChange(of: model) { _, value in if value != service.customModelName { service.customModelName = value } }
            }
            RowDivider()
            SettingRow(title: "API key", info: "Saved in your login Keychain, never in settings, diagnostics or logs. A server on this Mac usually needs none.") {
                HStack(spacing: 8) {
                    SecureField(hasKey ? "Saved in Keychain" : "Optional", text: $key).textFieldStyle(.roundedBorder).frame(width: 180)
                    Button("Save") { ModelKeyStore.save(key, for: service.customModelFormat); key = ""; refreshKey() }
                        .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if hasKey { Button("Remove") { ModelKeyStore.remove(for: service.customModelFormat); refreshKey() } }
                }
            }
            RowDivider()
            SettingRow(title: "Test connection", info: "Sends one short request that contains no transcript text.") {
                HStack(spacing: 8) {
                    if let testResult { Text(testResult).font(.caption).foregroundStyle(.secondary) }
                    Button(testing ? "Testing…" : "Test") { runTest() }
                        .disabled(testing || service.settings.customModel == nil)
                }
            }
            RowDivider()
            SettingToggle(title: "Use for cleanup", info: "Live speech, meetings and dictation cleanup use this model instead of Apple Intelligence. " + Self.destination(service, usesCustomModel: true),
                          isOn: $service.customModelForCleanup)
            RowDivider()
            SettingToggle(title: "Use for suggestions", info: "Double-tap Fn drafts use this model instead of Apple Intelligence, without a window image. " + Self.destination(service, usesCustomModel: true),
                          isOn: $service.customModelForSuggestions)
        }
        .onAppear { endpoint = service.customModelEndpoint; model = service.customModelName; refreshKey() }
        .onChange(of: service.customModelFormat) { _, _ in refreshKey(); testResult = nil }
    }

    /// Where a feature's text goes, for the explanation beside its switch.
    static func destination(_ service: SpeechService, usesCustomModel: Bool) -> String {
        guard usesCustomModel else { return "Runs on this Mac with Apple Intelligence." }
        guard let configuration = service.settings.customModel else { return "Set an endpoint and a model name first." }
        if configuration.isOnDevice { return "The text goes to the model server on this Mac." }
        return "The text is sent to \(configuration.requestURL.host ?? "the endpoint")."
    }

    private func refreshKey() { hasKey = ModelKeyStore.hasKey(for: service.customModelFormat) }

    private func runTest() {
        guard let configuration = service.settings.customModel else { return }
        testing = true; testResult = nil
        let format = configuration.format
        Task {
            let provider = RemoteModelProvider(configuration: configuration, key: { ModelKeyStore.key(for: format) })
            let request = ModelRequest(instructions: "Reply with the single word OK.", prompt: "Connection test.", maximumResponseTokens: 16)
            let result: String
            do { _ = try await provider.generate(request); result = "Connected" }
            catch let error as ModelUnavailable where error.reason == "unauthorized" { result = "Key refused" }
            catch RemoteModelProvider.Failure.status(let code) { result = "HTTP \(code)" }
            catch RemoteModelProvider.Failure.malformedResponse { result = "Unexpected reply" }
            catch { result = "No answer" }
            testResult = result; testing = false
        }
    }
}
