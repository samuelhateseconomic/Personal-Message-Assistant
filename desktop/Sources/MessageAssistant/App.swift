import SwiftUI
import AssistantCore
import NativeServices

@main
struct MessageAssistantApp: App {
    @StateObject private var session: NativeSession
    @StateObject private var plans: PlanRepository
    @StateObject private var planActions: PlanActionCoordinator
    @StateObject private var writingPreferences: WritingPreferencesController
    init() {
        let session = NativeSession()
        _session = StateObject(wrappedValue: session)
        _writingPreferences = StateObject(wrappedValue: WritingPreferencesController(store: WritingPreferenceStore(isUnlocked: { session.unlocked })))
        let plans = PlanRepository(isUnlocked: { session.unlocked })
        _plans = StateObject(wrappedValue: plans)
        _planActions = StateObject(wrappedValue: PlanActionCoordinator(repository: plans, isUnlocked: { session.unlocked }))
    }
    var body: some Scene {
        WindowGroup {
            WorkspaceView(session: session, plans: plans, planActions: planActions)
                .environmentObject(writingPreferences)
                .frame(minWidth: 720, minHeight: 560)
        }
        .defaultSize(width: 1000, height: 710)
    }
}

enum Destination: String, CaseIterable, Identifiable {
    case assistant = "Assistant", plan = "Plan", contacts = "Contacts", preferences = "Preferences"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .assistant: "text.bubble"
        case .plan: "calendar"
        case .contacts: "person.crop.rectangle"
        case .preferences: "slider.horizontal.3"
        }
    }
}
private struct AssistantPlanDraft {
    let intent: AssistantIntent
    let recipient: Recipient?
    let plan: StoredPlan?
}

struct WorkspaceView: View {
    @EnvironmentObject private var writingPreferences: WritingPreferencesController
    @ObservedObject var session: NativeSession
    @ObservedObject var plans: PlanRepository
    @ObservedObject var planActions: PlanActionCoordinator
    @StateObject private var nativeContacts = NativeContacts()
    @StateObject private var conversation = AssistantConversation()
    @State private var assistantContactProposal: AssistantContactProposal?
    @State private var assistantPlanDraft: AssistantPlanDraft?
    @State private var showAssistantDraftReplacement = false
    @State private var requiresExplicitAssistantTime = false
    @State private var planWorkflowID: UUID?
    @State private var contactSource = "Mac Contacts"
    @State private var workspace = Workspace(requiresNativeRecipient: true)
    @State private var recipientFilter = PlanSearch()
    @StateObject private var profileIndex = ProfileSearchIndex()
    @State private var recipientContactID: String?
    @State private var destination: Destination? = .assistant
    @State private var review: PreparedPlanAction?
    @State private var editingPlan: StoredPlan?
    @State private var pendingEdit: StoredPlan?
    @State private var composerTimezone = TimeZone.current.identifier
    @State private var successTitle = "Plan saved successfully"
    @State private var planAddedPending = false
    @State private var showPlanSuccess = false
    @State private var showingPlanComposer = false
    @State private var selectedSavedPlanID: UUID?
    @State private var savedPlanFilter = PlanSearch()
    @State private var showDraftNavigation = false
    @State private var startNewAfterDiscard = false
    @State private var composerTimeEdited = false
    @State private var notice = ""

    var body: some View {
        Group {
            if !session.unlocked {
                VStack(spacing: 18) {
                    Image(systemName: "lock").font(.largeTitle).accessibilityHidden(true)
                    Text("Workspace locked").font(.title2)
                    Text(session.status)
                        .foregroundStyle(.secondary)
                    Button(session.authenticating ? "Authenticating…" : "Unlock with macOS") { Task { await session.unlock() } }
                        .disabled(session.authenticating)
                        .buttonStyle(.borderedProminent)
                    Text("Use the system prompt. This app never collects your password.").font(.caption)
                    Text("Preview 0.10.0 · Contact save recovery").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                NavigationSplitView {
                    List(Destination.allCases, selection: $destination) { item in
                        Label(item.rawValue, systemImage: item.symbol).tag(item)
                    }
                    .navigationTitle("Message Assistant")
                    .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
                } detail: {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            Text("Preview 0.10.0 · Delivery disabled")
                                .font(.caption).foregroundStyle(.secondary)
                            if let workflow = conversation.workflow, destination != .assistant {
                                HStack {
                                    Text(workflow.contact == nil ? "Workflow: contact review, then draft plan" : "Workflow: contact saved; draft plan \(workflow.stage == .complete ? "saved" : "pending")")
                                        .font(.caption)
                                    Spacer()
                                    Button("View workflow") { destination = .assistant }
                                }
                            }
                            switch destination ?? .assistant {
                            case .assistant: assistant
                            case .plan: plan
                            case .contacts: contacts
                            case .preferences: WritingPreferencesView(preferences: writingPreferences)
                            }
                            if !notice.isEmpty {
                                Text(notice).foregroundStyle(.secondary)
                                    .accessibilityLabel("Status: \(notice)")
                            }
                        }.padding(30).frame(maxWidth: 850, alignment: .leading)
                    }
                    .navigationTitle((destination ?? .assistant).rawValue)
                    .toolbar {
                        Button { session.lock() } label: {
                            Label("Lock workspace", systemImage: "lock")
                        }
                    }
                }
            }
        }
        .sheet(item: $review, onDismiss: {
            if planAddedPending && session.unlocked { showPlanSuccess = true }
            planAddedPending = false
        }) { preview in
            PlanActionReviewView(preview: preview, confirm: { confirmPlanAction(preview) }, back: { review = nil })
        }
        .alert(successTitle, isPresented: $showPlanSuccess) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("The change is saved on this Mac. Delivery remains disabled; nothing has been scheduled or sent.")
        }
        .confirmationDialog("You have an unfinished draft", isPresented: $showDraftNavigation) {
            Button("Keep editing", role: .cancel) { pendingEdit = nil }
            if !startNewAfterDiscard {
                Button("Keep draft and return to plans") { showingPlanComposer = false }
            }
            Button("Discard draft", role: .destructive) {
                let target = pendingEdit
                resetPlanComposer()
                if let target { openPlanForEditing(target) }
                else { showingPlanComposer = startNewAfterDiscard }
                pendingEdit = nil
            }
        } message: {
            Text("Your draft has not been saved. You can continue editing or discard it explicitly.")
        }
        .confirmationDialog("Replace your unfinished plan draft?", isPresented: $showAssistantDraftReplacement) {
            Button("Keep existing draft", role: .cancel) { assistantPlanDraft = nil }
            Button("Replace with assistant proposal", role: .destructive) {
                if let value = assistantPlanDraft { applyAssistantPlan(value) }
                assistantPlanDraft = nil
            }
        } message: { Text("The existing draft has not been saved. Saved plans are unchanged until you review and confirm.") }
        .onReceive(NotificationCenter.default.publisher(for: .contactProfilesChanged)) { _ in
            if session.unlocked { profileIndex.refresh() }
        }
        .onChange(of: nativeContacts.isConnected) { _, _ in reconcileNativeContacts() }
        .onChange(of: nativeContacts.loading) { _, loading in
            if !loading { reconcileNativeContacts() }
        }
        .onChange(of: nativeContacts.rows) { _, _ in
            if nativeContacts.isConnected { reconcileNativeContacts() }
        }
        .onChange(of: destination) { _, _ in notice = "" }
        .onAppear {
            if session.unlocked { workspace.simulateUnlock(); plans.refresh(); profileIndex.refresh(); writingPreferences.refresh() } else { workspace.lock(); plans.lock(); profileIndex.clear(); writingPreferences.clear() }
        }
        .onDisappear { session.lock() }
        .onChange(of: session.unlocked) { _, unlocked in
            if unlocked { workspace.simulateUnlock(); plans.refresh(); profileIndex.refresh(); writingPreferences.refresh() }
            else {
                writingPreferences.clear()
                conversation.cancel(clear: true); assistantContactProposal = nil; assistantPlanDraft = nil
                planWorkflowID = nil
                showAssistantDraftReplacement = false; requiresExplicitAssistantTime = false
                review = nil; planAddedPending = false; showPlanSuccess = false; workspace.lock(); plans.lock(); planActions.invalidate(); profileIndex.clear()
                editingPlan = nil; pendingEdit = nil; composerTimezone = TimeZone.current.identifier
                nativeContacts.clear(); recipientContactID = nil; recipientFilter = PlanSearch()
                showingPlanComposer = false; selectedSavedPlanID = nil; savedPlanFilter = PlanSearch(); showDraftNavigation = false; composerTimeEdited = false
            }
        }
    }

    private var contactPicker: some View {
        RecipientPicker(contacts: nativeContacts, metadata: profileIndex, filter: $recipientFilter, contactID: $recipientContactID,
                        selected: workspace.selectedRecipient, hasDraft: !workspace.message.isEmpty, choose: { recipient in
            if recipient?.nativeID != conversation.workflow?.contact?.id {
                conversation.releaseWorkflowPlan(planWorkflowID); planWorkflowID = nil
            }
            workspace.selectRecipient(recipient); review = nil
            notice = "Recipient changed. Choose a destination before drafting."
        }, connect: connectContacts)
    }
    private func connectContacts() {
        Task {
            guard session.unlocked else { return }
            profileIndex.refresh()
            await nativeContacts.load(requestPermission: true)
        }
    }
    private func reconcileNativeContacts() {
        guard session.unlocked else { return }
        workspace.setRecipientAccessAvailable(nativeContacts.isConnected)
        review = nil
        guard !nativeContacts.loading else { return }
        workspace.reconcileRecipients(nativeContacts.rows.flatMap { RecipientPicker.endpoints($0) })
        if let id = recipientContactID, !nativeContacts.rows.contains(where: { $0.id == id }) {
            recipientContactID = nil
        }
    }
    private func validateRecipient() -> Bool {
        guard session.unlocked, nativeContacts.isConnected, let recipient = workspace.selectedRecipient else {
            notice = "Connect Apple Contacts and select a phone number or email first."; return false
        }
        do {
            let source = try ContactSyncService(isUnlocked: { session.unlocked }).fetch(recipient.nativeID)
            let values = source.fields.phones.map {
                Recipient(nativeID: source.id, name: source.fields.name.isEmpty ? recipient.name : source.fields.name, kind: .phone, address: $0)
            } + source.fields.emails.map {
                Recipient(nativeID: source.id, name: source.fields.name.isEmpty ? recipient.name : source.fields.name, kind: .email, address: $0)
            }
            workspace.reconcileRecipients(values)
            guard workspace.selectedRecipient != nil else {
                notice = "The destination was removed in Apple Contacts. Select the recipient again."; return false
            }
            return true
        } catch {
            workspace.setRecipientAccessAvailable(false)
            notice = "The recipient could not be verified. Reconnect Apple Contacts and try again."; return false
        }
    }
    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Message").font(.headline)
            TextEditor(text: Binding(get: { workspace.message }, set: { workspace.editMessage($0) }))
                .frame(height: 125).padding(8)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                .accessibilityLabel("Message draft")
                .disabled(!workspace.canReviewRecipient)
            Text("\(workspace.message.count) / 2,000 characters").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var assistant: some View {
        AssistantPanel(session: session, native: nativeContacts, profiles: profileIndex, plans: plans, conversation: conversation,
            connect: connectContacts, contactAction: { proposal in
                do {
                    try conversation.bindContactReview(proposal.id)
                    assistantContactProposal = proposal; contactSource = "Mac Contacts"; destination = .contacts
                } catch { notice = error.localizedDescription }
            }, planAction: handleAssistantPlan, resumePlan: { showingPlanComposer = true; destination = .plan })
    }
    private func handleAssistantPlan(_ intent: AssistantIntent, _ recipient: Recipient?, _ record: StoredPlan?) {
        if intent.action == .cancelPlan, let record {
            do {
                review = try planActions.prepare(PlanMutation(kind: .cancel, planID: record.id, expectedRevision: record.revision), workspace: workspace)
            } catch { notice = error.localizedDescription }
            return
        }
        let proposal = AssistantPlanDraft(intent: intent, recipient: recipient, plan: record)
        if hasPlanDraft { assistantPlanDraft = proposal; showAssistantDraftReplacement = true }
        else { applyAssistantPlan(proposal) }
    }
    private func applyAssistantPlan(_ proposal: AssistantPlanDraft) {
        do {
            var workflowContact: ContactSnapshot?
            let date = try proposal.intent.proposedDate()
            if let record = proposal.plan {
                let fresh = try plans.current(record.id)
                guard fresh.revision == record.revision, fresh.status == .draftOnly else { throw PlanStorageError.stale }
                workspace.loadForEditing(fresh.snapshot); editingPlan = fresh
                recipientContactID = fresh.snapshot.recipient.nativeID
                composerTimezone = fresh.timezone ?? TimeZone.current.identifier
            } else {
                guard let recipient = proposal.recipient else { throw PlanStorageError.invalid }
                if let workflow = conversation.workflow, workflow.unfinished {
                    let fresh = try ContactSyncService(isUnlocked: { session.unlocked }).fetch(recipient.nativeID)
                    _ = try workflow.continuation(for: fresh)
                    workflowContact = fresh
                }
                resetPlanComposer(); workspace.selectRecipient(recipient); recipientContactID = recipient.nativeID
                planWorkflowID = try conversation.openWorkflowPlan(recipient, fresh: workflowContact)
            }
            if let message = proposal.intent.message { workspace.editMessage(message) }
            if let date { workspace.editDate(date); composerTimezone = proposal.intent.timezone ?? composerTimezone }
            requiresExplicitAssistantTime = proposal.plan == nil && date == nil
            composerTimeEdited = date != nil; showingPlanComposer = true; destination = .plan
            notice = requiresExplicitAssistantTime ? "Choose an exact date and time before review. The displayed initial time is a placeholder." : "Assistant proposal loaded. Review the recipient, message and exact time before saving."
        } catch { notice = error.localizedDescription }
    }
    private func openPlanForEditing(_ plan: StoredPlan) {
        do {
            let current = try plans.current(plan.id)
            guard current.status == .draftOnly else { throw PlanStorageError.stale }
            workspace.loadForEditing(current.snapshot)
            editingPlan = current; recipientContactID = current.snapshot.recipient.nativeID
            recipientFilter = PlanSearch(); composerTimezone = current.timezone ?? TimeZone.current.identifier
            composerTimeEdited = false; showingPlanComposer = true; notice = ""
        } catch { notice = error.localizedDescription }
    }
    private func preparePlanAction() {
        do {
            guard !requiresExplicitAssistantTime else { notice = "Choose an exact date and time before review."; return }
            guard validateRecipient() else { return }
            let snapshot = try workspace.review()
            let mutation = PlanMutation(operationID: snapshot.id, kind: editingPlan == nil ? .create : .update,
                planID: editingPlan?.id ?? snapshot.id, expectedRevision: editingPlan?.revision,
                review: snapshot, timezone: composerTimezone)
            review = try planActions.prepare(mutation, workspace: workspace)
        } catch is WorkspaceError { notice = "Choose a future time and a nonempty message of at most 2,000 characters." }
        catch { notice = error.localizedDescription }
    }
    private func confirmPlanAction(_ preview: PreparedPlanAction) {
        do {
            if preview.mutation.kind != .cancel && !validateRecipient() { review = nil; return }
            try planActions.confirm(preview, workspace: &workspace)
            var workflowFinished = false
            if preview.mutation.kind == .create, let recipient = preview.mutation.review?.recipient {
                workflowFinished = conversation.completeWorkflowPlan(planWorkflowID, planID: preview.mutation.planID, recipient: recipient)
            }
            if preview.mutation.kind != .cancel {
                recipientContactID = nil; recipientFilter = PlanSearch(); requiresExplicitAssistantTime = false
                showingPlanComposer = false; editingPlan = nil; composerTimeEdited = false
                savedPlanFilter = PlanSearch()
                planWorkflowID = nil
            }
            selectedSavedPlanID = preview.mutation.planID
            successTitle = preview.mutation.kind == .cancel ? "Plan cancelled successfully" :
                (preview.mutation.kind == .update ? "Plan updated successfully" : "Plan added successfully")
            notice = successTitle; planAddedPending = true
            conversation.recordResult(workflowFinished ? "Contact and draft plan saved successfully. Delivery remains disabled." : successTitle)
        } catch is WorkspaceError { notice = "The draft changed or its time passed. Your inputs were kept; review again." }
        catch { notice = error.localizedDescription }
        review = nil
    }
    private var hasPlanDraft: Bool {
        recipientContactID != nil || !workspace.message.isEmpty || composerTimeEdited
    }
    private func resetPlanComposer() {
        conversation.releaseWorkflowPlan(planWorkflowID); planWorkflowID = nil
        workspace.newPlan(); workspace.selectRecipient(nil)
        editingPlan = nil; composerTimezone = TimeZone.current.identifier
        requiresExplicitAssistantTime = false
        recipientContactID = nil; recipientFilter = PlanSearch(); composerTimeEdited = false
        review = nil; notice = ""
    }
    private var plan: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text(showingPlanComposer ? (editingPlan == nil ? "Create a plan" : "Edit saved plan") : "Plans").font(.title2)
                Spacer()
                if showingPlanComposer {
                    Button("Back to plans") {
                        if hasPlanDraft { pendingEdit = nil; startNewAfterDiscard = false; showDraftNavigation = true }
                        else { showingPlanComposer = false }
                    }
                } else {
                    if hasPlanDraft { Button("Resume draft") { showingPlanComposer = true } }
                    Button("New plan", systemImage: "plus") {
                        if hasPlanDraft { pendingEdit = nil; startNewAfterDiscard = true; showDraftNavigation = true }
                        else { resetPlanComposer(); showingPlanComposer = true }
                    }.buttonStyle(.borderedProminent)
                }
            }
            if showingPlanComposer {
                Text(editingPlan == nil ? "Choose a recipient, write your message, then review the exact details before saving." : "Editing this saved plan creates a new reviewed revision. The existing plan stays unchanged until you confirm.")
                    .font(.callout).foregroundStyle(.secondary)
                contactPicker
                editor
                DatePicker("Planned time", selection: Binding(get: { workspace.date }, set: {
                    workspace.editDate($0); composerTimeEdited = true; requiresExplicitAssistantTime = false
                }), displayedComponents: [.date, .hourAndMinute])
                    .environment(\.timeZone, TimeZone(identifier: composerTimezone) ?? .current)
                Text("Timezone: \(composerTimezone)").font(.caption).foregroundStyle(.secondary)
                if requiresExplicitAssistantTime {
                    HStack {
                        Text("Choose an exact date/time before review.").font(.caption).foregroundStyle(.orange)
                        Button("Use the displayed date and time") { requiresExplicitAssistantTime = false; composerTimeEdited = true }
                    }
                }
                if !plans.errorMessage.isEmpty {
                    Label(plans.errorMessage, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
                    Button("Retry saved-plan storage") { plans.refresh() }
                }
                HStack {
                    Spacer()
                    Button("Review exact plan") { preparePlanAction() }.buttonStyle(.borderedProminent)
                        .disabled(requiresExplicitAssistantTime || !workspace.canReviewRecipient || !plans.ready || workspace.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                SavedPlansView(plans: plans, metadata: profileIndex, contacts: nativeContacts.rows, notice: $notice,
                               filter: $savedPlanFilter, selectedID: $selectedSavedPlanID,
                               edit: { record in
                    if hasPlanDraft { pendingEdit = record; startNewAfterDiscard = true; showDraftNavigation = true }
                    else { openPlanForEditing(record) }
                }, cancel: { record in
                    do {
                        review = try planActions.prepare(PlanMutation(kind: .cancel, planID: record.id,
                            expectedRevision: record.revision), workspace: workspace)
                    } catch { notice = error.localizedDescription }
                })
            }
        }
    }
    private var contacts: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Contacts").font(.title2)
            Picker("Source", selection: $contactSource) {
                Text("Demo contacts").tag("Demo contacts")
                Text("Mac Contacts · sync").tag("Mac Contacts")
            }.pickerStyle(.segmented)
            if contactSource == "Mac Contacts" {
                nativeContactsPanel
            } else {
                ContactProfilesView(contacts: workspace.contacts.map {
                    ProfileContact(id: "demo:" + $0.email, name: $0.name)
                }).id("demo-profiles")
            }
        }
    }
    private var nativeContactsPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(nativeContacts.status).foregroundStyle(.secondary)
            Button(nativeContacts.loading ? "Loading…" : "Connect / refresh Mac Contacts") {
                Task {
                    guard session.unlocked else { return }
                    profileIndex.refresh()
                    await nativeContacts.load(requestPermission: true)
                }
            }.disabled(nativeContacts.loading)
            SyncedContactsView(session: session, native: nativeContacts, plans: plans,
                initialProposal: assistantContactProposal, proposalConsumed: { assistantContactProposal = nil },
                onResult: { conversation.recordResult($0) }, onWorkflowEvent: { conversation.recordContactEvent($0) })
        }
    }
}
