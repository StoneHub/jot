import Foundation

/// First-run setup's pages, in order. Microphone access is asked on the microphone page and Accessibility on the dictation page, where each is needed.
public enum SetupStep: Int, CaseIterable, Comparable, Sendable {
    case welcome, models, microphone, dictation, intelligence, summary

    public var title: String {
        switch self {
        case .welcome: "Welcome to Jot"
        case .models: "Speech models"
        case .microphone: "Microphone"
        case .dictation: "Try dictation"
        case .intelligence: "Apple Intelligence"
        case .summary: "Summary"
        }
    }

    public var next: SetupStep? { SetupStep(rawValue: rawValue + 1) }
    public var previous: SetupStep? { SetupStep(rawValue: rawValue - 1) }

    public static func < (lhs: SetupStep, rhs: SetupStep) -> Bool { lhs.rawValue < rhs.rawValue }
}
