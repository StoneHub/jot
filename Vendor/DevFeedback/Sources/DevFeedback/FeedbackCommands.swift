import SwiftUI

#if DEBUG
struct FeedbackSessionFocusKey: FocusedValueKey {
    typealias Value = FeedbackSession
}

extension FocusedValues {
    var devFeedbackSession: FeedbackSession? {
        get { self[FeedbackSessionFocusKey.self] }
        set { self[FeedbackSessionFocusKey.self] = newValue }
    }
}
#endif

/// Add to the host scene's .commands builder in DEBUG builds.
/// Commands target the active window's overlay; no controls are inserted in the app layout.
@MainActor
public struct FeedbackCommands: Commands {
    #if DEBUG
    @FocusedValue(\.devFeedbackSession) private var session
    #endif

    public init() {}

    public var body: some Commands {
        #if DEBUG
        CommandMenu("Developer") {
            Button("Pick UI for Feedback") {
                guard let session else { return }
                if session.hasUnsavedChanges { session.showPanel() }
                else { session.startPicking() }
            }
            .keyboardShortcut("f", modifiers: [.command, .option, .shift])
            .disabled(session == nil)
            Button("Feedback History…") { session?.showPanel() }
                .disabled(session == nil)
        }
        #else
        CommandGroup(after: .help) {}
        #endif
    }
}
