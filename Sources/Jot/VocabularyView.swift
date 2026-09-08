import SwiftUI
import JotCore

struct VocabularyView: View {
    @ObservedObject var service: SpeechService
    @State private var draft = VocabularyEntry()
    @State private var editing = false
    @State private var error: String?
    @State private var sample = ""
    @State private var removed: VocabularyEntry?

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Your spellings, every time you dictate. Original transcripts stay unchanged.")
                    .font(.callout).foregroundStyle(.secondary)

                if let loadError = service.vocabularyLoadError {
                    Text(loadError).foregroundStyle(.red).textSelection(.enabled)

                }
                editor.id("vocabulary-editor")
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Try your vocabulary").font(.headline)

                    TextField("Enter a phrase to check", text: $sample, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(1...4)
                        .accessibilityLabel("Vocabulary preview input")

                    Text(sample.isEmpty ? "Saved, enabled entries will be applied here." : service.vocabulary.applying(to: sample))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel("Vocabulary preview result")
                        .accessibilityValue(sample.isEmpty ? "Saved, enabled entries will be applied here." : service.vocabulary.applying(to: sample))

                }
                Divider()
                HStack {
                    Text("Saved vocabulary").font(.headline)

                    Spacer()
                    if let removed {
                        Button("Undo remove") {
                            perform { try service.saveVocabularyEntry(removed); self.removed = nil }
                        }
                    }
                }
                if service.vocabulary.entries.isEmpty {
                    Text("Add a name, project, or phrase above. Leave “Heard as” empty to fix capitalization only.")
                        .font(.callout).foregroundStyle(.secondary)

                }
                ForEach(service.vocabulary.entries) { entry in
                    VocabularyRow(entry: entry, edit: {
                        draft = entry; editing = true; error = nil
                        withAnimation { proxy.scrollTo("vocabulary-editor", anchor: .top) }
                    }, toggle: { enabled in
                        var updated = entry; updated.enabled = enabled
                        perform {
                            try service.saveVocabularyEntry(updated)
                            if draft.id == entry.id { draft.enabled = enabled }
                        }
                    }, remove: {
                        perform {
                            try service.removeVocabularyEntry(entry.id); removed = entry
                            if draft.id == entry.id { resetEditor() }
                        }
                    })
                }
                Text("Matches whole words and phrases, ignoring capitalization. Longer phrases win at the same position. Applies to your next dictation; this does not train the speech model.")
                    .font(.caption).foregroundStyle(.secondary)

            }.frame(maxWidth: .infinity, alignment: .leading)
        }
            .modifier(GlassButton())

        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editing ? "Edit entry" : "Add a word or phrase").font(.headline)

            VStack(alignment: .leading, spacing: 5) {
                Text("Preferred spelling").font(.caption).foregroundStyle(.secondary)

                TextField("For example, SwiftUI", text: $draft.preferred)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Preferred spelling")

            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Heard as (optional)").font(.caption).foregroundStyle(.secondary)

                TextField("For example, swift you eye", text: $draft.heard)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Heard as")

            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)

            }
            HStack {
                if editing {
                    Button("Cancel") { resetEditor() }

                }
                Spacer()
                Button(editing ? "Save changes" : "Add entry") {
                    perform { try service.saveVocabularyEntry(draft); resetEditor() }
                }.disabled(draft.preferred.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || service.vocabularyLoadError != nil)

            }
        }
    }

    private func resetEditor() { draft = VocabularyEntry(); editing = false; error = nil }
    private func perform(_ action: () throws -> Void) {
        do { try action(); error = nil }
        catch { self.error = error.localizedDescription }
    }
}

private struct VocabularyRow: View {
    let entry: VocabularyEntry
    let edit: () -> Void
    let toggle: (Bool) -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.preferred).font(.headline).textSelection(.enabled)

                    Text(entry.heard.isEmpty ? "Capitalization only" : "Heard as: \(entry.heard)")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)

                }
                Spacer()
                Toggle("Enabled", isOn: Binding(get: { entry.enabled }, set: toggle))
                    .toggleStyle(.switch).labelsHidden().accessibilityLabel("Enable vocabulary entry")

            }
            HStack {
                Button("Edit", action: edit)

                Spacer()
                Button("Remove", role: .destructive, action: remove)

            }
        }.padding(14).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))

    }
}
