import Foundation

/// The card's source line: whose words the suggestion came from, in plain terms.
public enum SuggestionAttribution {
    public static func line(plan: SuggestionPlan, selected: [SuggestionSource], sessionTitle: String?, windowImage: Bool = false) -> String {
        var parts: [String] = []
        if case .draft(let seed) = plan { parts.append(seed.isSelection ? "Your selection" : "Your notes") }
        if plan == .continuation { parts.append("Your text") }
        if selected.contains(where: { $0.kind == ScreenContext.kind }) { parts.append("text on screen") }
        if windowImage { parts.append("an image of the window") }
        if selected.contains(where: { $0.kind == HeardSpeech.kind }) { parts.append("what Jot heard") }
        if selected.contains(where: { $0.kind == AgentContext.kind }) { parts.append("your agent conversation") }
        if selected.contains(where: { $0.kind == "dictation" }) { parts.append("recent dictation") }
        if selected.contains(where: { $0.kind == "meeting-transcript" }) {
            parts.append(sessionTitle.map { "meeting ‘\($0)’" } ?? "recent speech")
        }
        guard let first = parts.first else { return "" }
        parts[0] = first.prefix(1).uppercased() + String(first.dropFirst())
        return parts.joined(separator: " + ")
    }
}
