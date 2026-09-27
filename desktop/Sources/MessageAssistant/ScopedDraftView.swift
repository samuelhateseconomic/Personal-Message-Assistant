import SwiftUI
import AssistantCore
import NativeServices

struct ScopedDraftView: View {
    @EnvironmentObject private var preferences: WritingPreferencesController
    @State private var useWritingPreferences = false
    @ObservedObject var session: NativeSession
    let evidence: AssistantContactEvidence
    let model: String
    let baseIntent: AssistantIntent?
    let openPlan: (AssistantIntent, Recipient?, StoredPlan?) -> Void
    @StateObject private var draft = ScopedDraftSession()
    @State private var selection: Set<DraftContextField> = []
    @State private var purpose = ""
    @State private var editedMessage = ""
    @State private var endpoint = ""
    @State private var error = ""
    private var context: ScopedDraftContext? { try? ScopedDraftContext(evidence: evidence, selection: selection, writingPreference: useWritingPreferences ? preferences.record : nil) }
    private var recipients: [Recipient] {
        let fields = evidence.snapshot.fields
        return fields.phones.map { Recipient(nativeID: evidence.id, name: fields.name, kind: .phone, address: $0) }
            + fields.emails.map { Recipient(nativeID: evidence.id, name: fields.name, kind: .email, address: $0) }
    }
    var body: some View {
        DisclosureGroup("Write a message using selected contact facts") {
            VStack(alignment: .leading, spacing: 12) {
                TextField("What should this message do?", text: $purpose, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(2...4)
                    .accessibilityLabel("Purpose for the suggested message")
                Text("Choose facts to share with Ollama on this Mac. The contact’s name is included. Private notes are off by default.")
                    .font(.caption).foregroundStyle(.secondary)
                if evidence.profile?.connection.isEmpty == false { fieldToggle("Connection type", .connection) }
                if evidence.snapshot.fields.birthday?.month != nil && evidence.snapshot.fields.birthday?.day != nil { fieldToggle("Birthday", .birthday) }
                if evidence.profile?.note.isEmpty == false { fieldToggle("Private note", .note) }
                if preferences.ready, let style = preferences.record?.style {
                    Toggle("Use saved writing preferences", isOn: $useWritingPreferences)
                    Text("Saved by you · \(style.summary)").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(preferences.ready ? "Save a writing style in Preferences to use it here." : "Saved style unavailable. You can generate without it or reload in Preferences.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let context {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Context sent with your request").font(.subheadline.bold())
                        if let style = context.writingPreference?.style {
                            Text("Writing style · saved by you").font(.caption).foregroundStyle(.secondary)
                            Text(style.summary).font(.callout)
                        }
                        ForEach(context.facts, id: \.field) { fact in
                            Text("\(fact.field.capitalized) · \(fact.source)").font(.caption).foregroundStyle(.secondary)
                            Text(fact.value).font(.callout).textSelection(.enabled)
                        }
                    }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    HStack {
                        Button("Generate with this context") {
                            error = ""
                            draft.generate(purpose: purpose, context: context, model: model) { try verify(context) }
                        }.disabled(draft.busy || !session.unlocked || purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || purpose.count > 2000)
                        if draft.busy {
                            ProgressView().controlSize(.small)
                            Button("Cancel generation") { draft.invalidate() }
                        }
                    }
                } else { Text("A selected fact is missing or too long. Deselect it or edit the contact, then refresh.").foregroundStyle(.orange) }
                if !draft.error.isEmpty { Text(draft.error).foregroundStyle(.red) }
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
                if !draft.message.isEmpty {
                    Text("Suggested message · review and edit").font(.headline)
                    TextEditor(text: $editedMessage).frame(height: 90).padding(6)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                        .accessibilityLabel("Editable context-based message suggestion")
                    Text("Sources above show what was supplied, not verification of every generated claim. Check the wording before using it.")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("Exact destination", selection: $endpoint) {
                        Text("Choose a phone number or email").tag("")
                        ForEach(recipients) { Text($0.address).tag($0.id) }
                    }
                    if recipients.isEmpty { Text("Add a phone number or email in Contacts before creating a plan.").font(.caption) }
                    Button("Use this message in the plan editor") {
                        do {
                            guard let context, let recipient = recipients.first(where: { $0.id == endpoint }) else { return }
                            try verify(context)
                            var proposal = baseIntent?.action == .createPlan ? baseIntent! : AssistantIntent(action: .createPlan)
                            proposal.message = editedMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                            proposal.query = evidence.snapshot.fields.name
                            openPlan(proposal, recipient, nil)
                        } catch { self.error = "The source changed or is unavailable. Refresh the contact and generate again."; draft.invalidate() }
                    }.disabled(endpoint.isEmpty || editedMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || editedMessage.count > 2000)
                }
                Text("This generates a suggestion only. Choose the date and review the exact plan before saving. Delivery remains disabled.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.top, 10)
        }
        .onChange(of: draft.message) { _, value in editedMessage = value }
        .onChange(of: purpose) { _, _ in invalidate() }
        .onChange(of: selection) { _, _ in invalidate() }
        .onChange(of: useWritingPreferences) { _, _ in invalidate() }
        .onChange(of: preferences.record) { _, _ in useWritingPreferences = false; invalidate() }
        .onChange(of: preferences.ready) { _, _ in useWritingPreferences = false; invalidate() }
        .onChange(of: model) { _, _ in invalidate() }
        .onChange(of: evidence) { _, _ in selection = []; endpoint = ""; invalidate() }
        .onChange(of: session.unlocked) { _, unlocked in if !unlocked { purpose = ""; selection = []; invalidate() } }
        .onReceive(NotificationCenter.default.publisher(for: .contactProfilesChanged)) { _ in invalidate() }
        .onDisappear { invalidate() }
    }
    private func fieldToggle(_ title: String, _ field: DraftContextField) -> some View {
        Toggle(title, isOn: Binding(get: { selection.contains(field) }, set: { included in
            if included { selection.insert(field) } else { selection.remove(field) }
        }))
    }
    private func invalidate() { draft.invalidate(); editedMessage = ""; error = "" }
    private func verify(_ context: ScopedDraftContext) throws {
        guard session.unlocked else { throw ContactSyncError.locked }
        if let expected = context.writingPreference { try preferences.validate(expected) }
        let fresh = try ContactSyncService(isUnlocked: { session.unlocked }).fetch(evidence.id)
        try context.validate(snapshot: fresh, profile: ContactProfileStore().load()["mac:" + evidence.id])
    }
}
