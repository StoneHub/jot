import Foundation

public enum PerformanceEventKind: String, Codable, Sendable {
    case launch, modelLoadStarted, modelsReady, modelsUnloaded, pause, resume
    case dictationStarted, dictationReleased, dictationCancelled, ambientStarted
    case sleep, deviceChange, audioGap, processingFailed
}
