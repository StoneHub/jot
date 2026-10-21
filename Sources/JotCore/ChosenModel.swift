import Foundation

/// The model one feature uses: Apple Intelligence unless that feature's custom-model switch is on. Settings are read for
/// each request, so a change in Settings or `jot settings` applies to the next one without rebuilding any owner.
public struct ChosenModel: GenerationProvider {
    public enum Feature: Sendable {
        case cleanup, suggestions, notes
        public var settingKey: String {
            switch self {
            case .cleanup: return JotSettings.customModelForCleanup
            case .suggestions: return JotSettings.customModelForSuggestions
            case .notes: return JotSettings.customModelForNotes
            }
        }
    }

    public let feature: Feature
    private let settings: JotSettings
    private let apple: any GenerationProvider
    private let key: @Sendable (RemoteModelConfiguration.Format) -> String?

    public init(_ feature: Feature, settings: JotSettings = .standard, apple: any GenerationProvider = AppleIntelligenceProvider(),
                key: @escaping @Sendable (RemoteModelConfiguration.Format) -> String? = { ModelKeyStore.key(for: $0) }) {
        self.feature = feature
        self.settings = settings
        self.apple = apple
        self.key = key
    }

    public var usesCustomModel: Bool { settings.bool(feature.settingKey) }
    /// The model's name as `jot status` and `jot notes` report it.
    public var displayName: String { usesCustomModel ? settings.text(JotSettings.customModelName) : "Apple on-device" }

    /// The provider for a request made now.
    public var current: any GenerationProvider {
        guard usesCustomModel else { return apple }
        let configuration = settings.customModel
        let key = key
        return RemoteModelProvider(configuration: configuration, key: { configuration.flatMap { key($0.format) } })
    }

    public var availability: CleanupAvailability { current.availability }
    /// `apple` replaces Apple Intelligence's own availability, as the recovery harness injects it; a custom model reports its own.
    public func availability(orApple apple: @autoclosure () -> CleanupAvailability) -> CleanupAvailability {
        usesCustomModel ? current.availability : apple()
    }
    public var isOnDevice: Bool { current.isOnDevice }
    public func generate(_ request: ModelRequest) async throws -> String { try await current.generate(request) }
    public func generateTexts(_ request: ModelRequest) async throws -> [String] { try await current.generateTexts(request) }
}
