import SwiftUI
import AssistantCore
import NativeServices

struct AssistantPanel: View {
    @ObservedObject var session: NativeSession
    @ObservedObject var native: NativeContacts
    @ObservedObject var profiles: ProfileSearchIndex
    @ObservedObject var plans: PlanRepository
    @ObservedObject var conversation: AssistantConversation
    let connect: () -> Void
    let contactAction: (AssistantContactProposal) -> Void
    let planAction: (AssistantIntent, Recipient?, StoredPlan?) -> Void
    let resumePlan: () -> Void
    @State private var prompt = ""
    @State private var model = "gemma3:12b"
    @State private var matches: [NativeContactRow] = []
    @State private var planMatches: [StoredPlan] = []
    @State private var evidence: AssistantContactEvidence?
    @State private var endpoint = ""
    @State private var status = ""
    @State private var localQuery = ""
    @State private var localLookup = false
    @State private var endWorkflow = false
    @State private var discardNotes = false
    private var intent: AssistantIntent? {
        guard let workflow = conversation.workflow else { return conversation.intent }
        switch workflow.stage {
        case .contactProposal, .contactReview, .contactUnknown: return workflow.contactIntent
        case .planReady, .planEditing:
            var result = workflow.planIntent; result.query = workflow.contact?.fields.name; return result
        case .annotationsPending, .complete: return nil
        }
    }
    private var mayOpenContact: Bool {
        guard let workflow = conversation.workflow else { return true }
        return workflow.stage == .contactProposal || workflow.stage == .contactReview
    }
    private var recipients: [Recipient] {
        guard let evidence else { return [] }
        let fields = evidence.snapshot.fields
        return fields.phones.map { Recipient(nativeID: evidence.id, name: fields.name, kind: .phone, address: $0) }
            + fields.emails.map { Recipient(nativeID: evidence.id, name: fields.name, kind: .email, address: $0) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("What would you like to plan or change?").font(.title2)
            Text("Find contacts, prepare contact changes, or create and edit saved plans. Every change needs your review; delivery is disabled.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Label(native.isConnected ? "Apple Contacts connected" : "Apple Contacts disconnected", systemImage: "person.crop.circle")
                Spacer()
                Button(native.isConnected ? "Refresh" : "Connect Apple Contacts", action: connect).disabled(native.loading)
            }.font(.caption)
            if let workflow = conversation.workflow { workflowPanel(workflow) }
            if !conversation.requests.isEmpty {
                DisclosureGroup("Recent requests · cleared when locked") {
                    ForEach(Array(conversation.requests.enumerated()), id: \.offset) { _, text in Text(text).font(.callout).padding(.vertical, 4) }
                    Button("Start a new conversation") {
                        if conversation.workflow?.unfinished == true { endWorkflow = true }
                        else { conversation.cancel(clear: true); clearResults(); prompt = "" }
                    }
                }
            }
            TextEditor(text: $prompt).frame(height: 90).padding(6)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                .accessibilityLabel("Assistant request")
            HStack {
                Button("Ask assistant") { localLookup = false; clearResults(); conversation.ask(prompt, model: model) }
                    .buttonStyle(.borderedProminent).disabled(conversation.busy || conversation.workflow?.unfinished == true || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if conversation.busy {
                    ProgressView().controlSize(.small)
                    Text("Preparing a proposal…").font(.caption)
                    Button("Cancel") { conversation.cancel(); clearResults() }
                }
            }
            DisclosureGroup("Local model and keyword lookup") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Local model", selection: $model) {
                        ForEach(OllamaAssistantPlanner.models, id: \.self) { Text($0).tag($0) }
                    }.disabled(conversation.busy)
                    Text("Typed requests go to Ollama on this Mac. Contact lookup runs locally. The optional context preview lets you explicitly include selected facts when generating a message. No cloud fallback.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("Search name + connection + note keywords", text: $localQuery).textFieldStyle(.roundedBorder)
                    Button("Look up contacts without AI") {
                        conversation.stopInferenceForNavigation(); clearResults(); localLookup = true
                        lookupContacts(localQuery)
                    }.disabled(!native.isConnected || localQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(.top, 10)
            }
            if !conversation.error.isEmpty { Label(conversation.error, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
            if !conversation.outcome.isEmpty { Label(conversation.outcome, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            if !profiles.errorMessage.isEmpty { Text(profiles.errorMessage).foregroundStyle(.orange).font(.caption) }
            if let intent, intent.action == .clarify {
                Text("More information needed · no changes made").font(.headline)
                Text(intent.question ?? "Describe one action, the contact, and any exact date/time or details to use.")
            }
            if !status.isEmpty { Text(status).font(.callout).foregroundStyle(.secondary) }
            if !matches.isEmpty {
                Text(intent?.action == .createContact ? "Possible existing contacts" : "Choose the exact contact").font(.headline)
                ForEach(matches.prefix(20)) { row in
                    Button { selectContact(row.id) } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(row.name)
                                Text((row.phones + row.emails).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(); Image(systemName: evidence?.id == row.id ? "checkmark.circle.fill" : "chevron.right")
                        }.padding(10).contentShape(Rectangle())
                    }.buttonStyle(.plain).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            if let evidence { evidenceCard(evidence) }
            if let intent, intent.action == .createContact {
                Text("Proposed new contact · facts from your input").font(.headline)
                Text([intent.givenName, intent.familyName].compactMap { $0 }.joined(separator: " "))
                Text(((intent.phones ?? []) + (intent.emails ?? [])).joined(separator: " · "))
                if let connection = intent.connection { Text("Connection: \(connection)") }
                if let birthday = intent.birthday { Text("Birthday: \(birthday)") }
                if let note = intent.note { Text("Note: \(note)") }
                Button(matches.isEmpty ? "Open editable contact proposal" : "Create a separate contact anyway…") {
                    contactAction(AssistantContactProposal(intent: intent, target: nil))
                }.disabled(!mayOpenContact || !native.isConnected || [intent.givenName, intent.familyName].compactMap { $0 }.joined().isEmpty)
                Text("Choose the destination account in the editor, then review before saving.").font(.caption).foregroundStyle(.secondary)
            }
            if !planMatches.isEmpty {
                Text("Saved plans · choose one").font(.headline)
                ForEach(planMatches.prefix(20)) { plan in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(plan.snapshot.recipient.name) · revision \(plan.revision)").font(.headline)
                        Text(plan.snapshot.message)
                        Text("\(plan.snapshot.date.formatted()) · \(plan.status == .cancelled ? "Cancelled" : "Draft only")").font(.caption)
                        Text("Source: encrypted saved-plan record; display time uses this Mac’s timezone.").font(.caption).foregroundStyle(.secondary)
                        if let intent, intent.action == .updatePlan || intent.action == .cancelPlan {
                            Button(intent.action == .cancelPlan ? "Review cancellation" : "Open editable plan proposal") {
                                planAction(intent, nil, plan)
                            }.disabled(plan.status == .cancelled)
                        }
                    }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .onAppear { loadIntent() }
        .onChange(of: conversation.intent) { _, _ in loadIntent() }
        .onChange(of: conversation.workflow?.stage) { _, _ in loadIntent() }
        .onChange(of: native.rows) { _, _ in
            if conversation.workflow != nil { loadIntent() }
            else { clearResults(); status = "Contacts changed. Repeat lookup to use current records." }
        }
        .onChange(of: profiles.profiles) { _, _ in clearResults(); status = "Local contact details changed. Repeat lookup to use current facts." }
        .onChange(of: native.isConnected) { _, connected in
            if !connected { conversation.stopInferenceForNavigation(); clearResults() }
            else { loadIntent() }
        }
        .onChange(of: session.unlocked) { _, unlocked in if !unlocked { conversation.cancel(clear: true); prompt = ""; localQuery = ""; clearResults() } }
        .onDisappear { conversation.stopInferenceForNavigation() }
        .confirmationDialog("End this workflow?", isPresented: $endWorkflow) {
            Button("End workflow; keep saved changes", role: .destructive) { conversation.cancel(clear: true); clearResults(); prompt = "" }
            Button("Keep working", role: .cancel) { }
        } message: { Text("Saved changes stay saved. Workflow tracking and pending notes will be discarded. An opened plan draft remains available in Plans.") }
        .confirmationDialog("Discard the pending local notes?", isPresented: $discardNotes) {
            Button("Keep existing notes and continue", role: .destructive) {
                do {
                    let recovery = ContactSaveCoordinator(contacts: ContactSyncService(isUnlocked: { session.unlocked }), isUnlocked: { session.unlocked })
                    if let receipt = try recovery.pending().first(where: { $0.proposalID == conversation.workflow?.contactProposalID }) { try recovery.dismiss(receipt.id) }
                    conversation.discardPendingAnnotations()
                } catch { status = error.localizedDescription }
            }
            Button("Keep pending notes", role: .cancel) { }
        } message: { Text("The native contact remains saved. Existing saved notes will not be changed.") }
    }
    private func loadIntent() {
            clearResults(); localLookup = false
            guard let value = intent else { return }
            if let workflow = conversation.workflow, workflow.stage == .planReady || workflow.stage == .planEditing {
                guard native.isConnected, let contact = workflow.contact else { status = "Connect or refresh Apple Contacts to verify the saved workflow contact."; return }
                selectContact(contact.id)
                return
            }
            if [.searchPlans, .updatePlan, .cancelPlan].contains(value.action) {
                plans.refresh()
                guard plans.ready else { status = plans.errorMessage; return }
                if value.action != .searchPlans && (value.query ?? "").isEmpty { status = "Enter recipient or message keywords to identify the saved plan."; return }
                planMatches = AssistantRetrieval.plans(query: value.query ?? "", records: plans.plans, profiles: profiles.profiles)
                status = planMatches.isEmpty ? "No saved plans match these keywords." : (planMatches.count > 20 ? "More than 20 matches. Narrow the keywords before choosing." : "")
                if planMatches.count > 20 { planMatches = [] }
            } else if value.action == .createContact {
                let name = [value.givenName, value.familyName].compactMap { $0 }.joined(separator: " ")
                lookupContacts(name)
                // Exact endpoint matches are also possible duplicates, even when the name differs.
                for row in native.rows where !matches.contains(where: { $0.id == row.id }) {
                    if row.phones.contains(where: { old in (value.phones ?? []).contains { $0.filter(\.isNumber) == old.filter(\.isNumber) } }) || row.emails.contains(where: { old in (value.emails ?? []).contains { $0.lowercased() == old.lowercased() } }) {
                        matches.append(row)
                    }
                }
                status = matches.isEmpty ? "No matching name or endpoint found in the currently loaded contacts. The native editor will recheck access." : "Review these possible duplicates before creating a separate card."
            } else if value.action != .clarify { lookupContacts(value.query ?? "") }
    }
    private func workflowPanel(_ workflow: AssistantWorkflow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Contact → draft plan").font(.headline)
            Label(workflow.contact == nil ? "1. Review the contact" : "1. Contact saved", systemImage: workflow.contact == nil ? "1.circle" : "checkmark.circle.fill")
            Label(workflow.stage == .complete ? "2. Draft plan saved" : "2. Review the draft plan", systemImage: workflow.stage == .complete ? "checkmark.circle.fill" : "2.circle")
            if workflow.stage == .contactUnknown {
                Text("The contact save is unconfirmed. Refresh Contacts, inspect the matching source card below, then explicitly use it. The app will not repeat the save.").foregroundStyle(.orange)
            }
            if workflow.stage == .annotationsPending {
                Text("The contact is saved; local annotations still need attention.").foregroundStyle(.orange)
                if let profile = workflow.pendingProfile {
                    Text("Connection to save: \(profile.connection)"); Text("Note to save: \(profile.note)")
                    Button("Save these local notes only") {
                        do {
                            let recovery = ContactSaveCoordinator(contacts: ContactSyncService(isUnlocked: { session.unlocked }), isUnlocked: { session.unlocked })
                            guard let receipt = try recovery.pending().first(where: { $0.proposalID == workflow.contactProposalID }) else { throw ContactSaveRecoveryError.missing }
                            _ = try recovery.finishNotes(receipt.id)
                            if let proposal = receipt.proposalID { conversation.annotationsSaved(proposal) }
                        } catch { status = error.localizedDescription }
                    }
                    Button("Continue without saving these notes…") { discardNotes = true }
                }
            }
            if workflow.stage == .planReady { Text("Choose an endpoint below. The plan stays separate until you review and confirm it.") }
            if workflow.stage == .planEditing { Button("Resume the plan draft", action: resumePlan) }
            Text("Workflow progress stays in this unlocked session. Locking clears pending steps; saved changes remain.").font(.caption).foregroundStyle(.secondary)
            Button(workflow.unfinished ? "End workflow…" : "Start a new request") {
                if workflow.unfinished { endWorkflow = true }
                else { conversation.cancel(clear: true); clearResults(); prompt = "" }
            }
        }.padding(14).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
    private func clearResults() { matches = []; planMatches = []; evidence = nil; endpoint = ""; status = "" }
    private func lookupContacts(_ query: String) {
        guard native.isConnected else { status = "Connect Apple Contacts to retrieve or change contacts."; return }
        matches = AssistantRetrieval.contacts(query: query, rows: native.rows, profiles: profiles.profiles)
        if matches.count > 20 { matches = []; status = "More than 20 contacts match. Add name, connection or note keywords." }
        else if matches.isEmpty { status = "No contact matches every keyword. Try fewer keywords or open Contacts to create one." }
    }
    private func selectContact(_ id: String) {
        evidence = nil
        do {
            let service = ContactSyncService(isUnlocked: { session.unlocked })
            let fresh = try service.fetch(id)
            if let workflow = conversation.workflow, workflow.stage == .planReady || workflow.stage == .planEditing {
                _ = try workflow.continuation(for: fresh)
            }
            guard let account = try service.accounts().first(where: { $0.id == fresh.accountID }) else { throw ContactSyncError.account }
            evidence = AssistantContactEvidence(snapshot: fresh, account: account, profile: try ContactProfileStore().load()["mac:" + id])
            endpoint = ""; status = ""
        } catch { status = "This source card could not be verified. Refresh Contacts and choose it again."; evidence = nil }
    }
    private func evidenceCard(_ value: AssistantContactEvidence) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(value.snapshot.fields.name).font(.headline)
            Text("Apple Contacts · \(value.account.name) · checked \(value.fetchedAt.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
            Text((value.snapshot.fields.phones + value.snapshot.fields.emails).joined(separator: "\n"))
            if let birthday = value.snapshot.fields.birthday { Text("Birthday: \(birthday.month ?? 0)/\(birthday.day ?? 0) · \(birthday.year.map(String.init) ?? "year unknown")") }
            else { Text("Birthday: unknown").foregroundStyle(.secondary) }
            if let profile = value.profile {
                Text("Local profile · connection: \(profile.connection.isEmpty ? "unknown" : profile.connection)")
                Text("Local private note: \(profile.note.isEmpty ? "none" : profile.note)")
            }
            if let intent, !localLookup || conversation.workflow?.stage == .contactUnknown {
                if conversation.workflow?.stage == .contactUnknown {
                    Button("Use this verified contact without repeating the save") {
                        do {
                            let recovery = ContactSaveCoordinator(contacts: ContactSyncService(isUnlocked: { session.unlocked }), isUnlocked: { session.unlocked })
                            guard let receipt = try recovery.pending().first(where: { $0.proposalID == conversation.workflow?.contactProposalID }) else { throw ContactSaveRecoveryError.missing }
                            let checked = try recovery.check(receipt.id, selectedID: value.id)
                            guard let verified = checked.saved else { throw ContactSaveRecoveryError.uncertain }
                            try conversation.resolveUncertainContact(verified)
                        }
                        catch { status = error.localizedDescription }
                    }
                } else if intent.action == .updateContact || intent.action == .deleteContact || intent.action == .createContact {
                    Button(intent.action == .deleteContact ? "Review exact contact deletion…" : "Open editable contact proposal") {
                        var edit = intent
                        if intent.action == .createContact { edit.action = .updateContact }
                        contactAction(AssistantContactProposal(intent: edit, target: value.snapshot))
                    }.disabled(!mayOpenContact)
                } else if intent.action == .createPlan {
                    Text("Suggested message · generated, not sent").font(.subheadline)
                    Text(intent.message ?? "Enter the message in the plan editor.")
                    Picker("Exact destination", selection: $endpoint) {
                        Text("Choose a phone number or email").tag("")
                        ForEach(recipients) { Text($0.address).tag($0.id) }
                    }
                    Button("Open editable plan proposal") {
                        guard let recipient = recipients.first(where: { $0.id == endpoint }) else { return }
                        planAction(intent, recipient, nil)
                    }.disabled(endpoint.isEmpty)
                }
            }
            if (localLookup || intent?.action == .searchContacts || intent?.action == .createPlan),
               conversation.workflow == nil || conversation.workflow?.stage == .planReady {
                ScopedDraftView(session: session, evidence: value, model: model, baseIntent: intent, openPlan: planAction)
                    .id(value.id)
            }
        }.padding(14).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}
