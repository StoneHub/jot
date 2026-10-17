import SwiftUI

/// A setting's explanation behind a small (i). Resting the pointer on it opens a popover; a click or Space keeps it open until clicked again, for keyboard and VoiceOver use.
struct InfoButton: View {
    let title: String
    let detail: String
    @State private var showing = false
    @State private var pinned = false
    @State private var hover: Task<Void, Never>?
    var body: some View {
        Button { pinned.toggle(); showing = pinned } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(showing ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("About \(title)")
        .accessibilityHint(detail)
        .onHover { inside in
            hover?.cancel()
            if inside {
                hover = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    if !Task.isCancelled { showing = true }
                }
            } else if !pinned { showing = false }
        }
        .onChange(of: showing) { _, shown in if !shown { pinned = false } }
        .onDisappear { hover?.cancel() }
        .popover(isPresented: $showing) {
            Text(detail).font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 260, alignment: .leading)
                .padding(12)
        }
    }
}
