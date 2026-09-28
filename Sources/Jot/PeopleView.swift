import SwiftUI
import AppKit
import JotCore

/// The voices Jot remembers. Deleting one forgets the voice; names already written into sessions stay.
struct PeopleView: View {
    @ObservedObject var speakers: SpeakerRecognizer
    @State private var renamingID: String?
    @State private var nameDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if speakers.people.isEmpty && speakers.userVoice == nil {
                Text("No one yet. Name a speaker in Live or Sessions, and Jot remembers the voice once the session's speaker pass has run. Jot learns your own voice from your dictations.").foregroundStyle(.secondary)
            }
            if let you = speakers.userVoice {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(UserVoice.label).font(.headline)
                        Text(you.trusted
                             ? "Your voice, learned from \(you.sampleCount) session\(you.sampleCount == 1 ? "" : "s") of dictation"
                             : "Learning your voice: \(Int(you.heldSeconds)) of \(Int(UserVoice.minimumHeldSeconds)) seconds of dictation heard")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Forget", systemImage: "trash", role: .destructive) { speakers.forgetUserVoice() }
                        .labelStyle(.iconOnly).modifier(GlassButton()).help("Forget your voice. Jot learns it again from your next dictations.")
                }.padding(14).frame(maxWidth: 820, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            }
            ForEach(speakers.people) { person in
                HStack(spacing: 10) {
                    if renamingID == person.id {
                        TextField("Name", text: $nameDraft).textFieldStyle(.roundedBorder).frame(maxWidth: 280).onSubmit { commitRename(person) }
                        Button("Save") { commitRename(person) }.modifier(PrimaryGlassButton())
                        Button("Cancel") { renamingID = nil }.modifier(GlassButton())
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(person.name).font(.headline)
                            Text("\(person.sampleCount) voice sample\(person.sampleCount == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Rename", systemImage: "pencil") { nameDraft = person.name; renamingID = person.id }
                            .labelStyle(.iconOnly).modifier(GlassButton()).help("Rename this person")
                        Button("Delete", systemImage: "trash", role: .destructive) { speakers.deletePerson(person.id) }
                            .labelStyle(.iconOnly).modifier(GlassButton()).help("Forget this voice")
                    }
                }.padding(14).frame(maxWidth: 820, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear { speakers.refreshPeople() }
    }

    private func commitRename(_ person: Person) {
        speakers.renamePerson(person.id, name: nameDraft); renamingID = nil
    }
}
