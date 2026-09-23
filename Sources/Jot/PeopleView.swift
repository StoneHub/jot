import SwiftUI
import AppKit
import JotCore

/// The voices Jot remembers. Deleting one forgets the voice; names already written into sessions stay.
struct PeopleView: View {
    @ObservedObject var service: SpeechService
    @State private var renamingID: String?
    @State private var nameDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Jot recognizes these voices in new sessions. Delete a person and their voice is forgotten.")
                .font(.callout).foregroundStyle(.secondary)
            if service.people.isEmpty {
                Text("No one yet. Name a speaker in Sessions with \"Remember this voice\" on.").foregroundStyle(.secondary)
            }
            ForEach(service.people) { person in
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
                        Button("Delete", systemImage: "trash", role: .destructive) { service.deletePerson(person.id) }
                            .labelStyle(.iconOnly).modifier(GlassButton()).help("Forget this voice")
                    }
                }.padding(14).frame(maxWidth: 820, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear { service.refreshPeople() }
    }

    private func commitRename(_ person: Person) {
        service.renamePerson(person.id, name: nameDraft); renamingID = nil
    }
}
