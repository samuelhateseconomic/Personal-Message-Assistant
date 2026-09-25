import SwiftUI
import AssistantCore
import NativeServices

@main
struct MessageAssistantApp: App {
    @StateObject private var session: NativeSession
    @StateObject private var plans: PlanRepository
    init() {
        let session = NativeSession()
        _session = StateObject(wrappedValue: session)
        _plans = StateObject(wrappedValue: PlanRepository(isUnlocked: { session.unlocked }))
    }
    var body: some Scene {
        WindowGroup {
            WorkspaceView(session: session, plans: plans)
                .frame(minWidth: 720, minHeight: 560)
        }
        .defaultSize(width: 1000, height: 710)
    }
}

enum Destination: String, CaseIterable, Identifiable {
    case assistant = "Assistant", plan = "Plan", contacts = "Contacts"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .assistant: "text.bubble"
        case .plan: "calendar"
        case .contacts: "person.crop.rectangle"
        }
    }
}

struct WorkspaceView: View {
    @ObservedObject var session: NativeSession
    @ObservedObject var plans: PlanRepository
    @StateObject private var nativeContacts = NativeContacts()
    @State private var contactSource = "Mac Contacts"
    @State private var workspace = Workspace(requiresNativeRecipient: true)
    @State private var recipientSearch = ""
    @State private var recipientContactID: String?
    @State private var destination: Destination? = .assistant
    @State private var review: Review?
    @State private var planAddedPending = false
    @State private var showPlanSuccess = false
    @State private var notice = ""
    @State private var language = "English"

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
                    Text("Preview 0.4.0 · Saved draft plans").font(.caption).foregroundStyle(.secondary)
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
                            Text("Preview 0.4.0 · Delivery disabled")
                                .font(.caption).foregroundStyle(.secondary)
                            switch destination ?? .assistant {
                            case .assistant: assistant
                            case .plan: plan
                            case .contacts: contacts
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
        }) { snapshot in
            VStack(alignment: .leading, spacing: 18) {
                Text("Review exact plan").font(.title2)
                Text("To: \(snapshot.recipient.name)").font(.headline)
                Text("\(snapshot.recipient.kind == .phone ? "Phone" : "Email"): \(snapshot.recipient.address)").foregroundStyle(.secondary)
                Text(snapshot.message).textSelection(.enabled)
                Text(snapshot.date.formatted(date: .abbreviated, time: .shortened))
                Text(TimeZone.current.identifier).font(.caption)
                Divider()
                Text("Confirming saves an encrypted draft-only plan on this Mac. Nothing will be sent or scheduled.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Back") { review = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Confirm plan") {
                        do {
                            guard validateRecipient() else { review = nil; return }
                            try plans.confirm(snapshot, workspace: &workspace)
                            recipientContactID = nil; recipientSearch = ""; language = "English"
                            notice = "Plan saved on this Mac. The form is ready for a new plan."
                            planAddedPending = true
                        }
                        catch is WorkspaceError { notice = "The plan changed or its time passed. Review it again. Your inputs were kept." }
                        catch { notice = "Could not save the plan. Your inputs were kept. Check saved-plan storage and try again." }
                        review = nil
                    }.buttonStyle(.borderedProminent)
                }
            }.padding(28).frame(width: 450)
        }
        .alert("Plan added successfully", isPresented: $showPlanSuccess) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Your plan is saved on this Mac, and the form has been reset. Delivery remains disabled; nothing has been scheduled or sent.")
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
            if session.unlocked { workspace.simulateUnlock(); plans.refresh() } else { workspace.lock(); plans.lock() }
        }
        .onDisappear { session.lock() }
        .onChange(of: session.unlocked) { _, unlocked in
            if unlocked { workspace.simulateUnlock(); plans.refresh() }
            else {
                review = nil; planAddedPending = false; showPlanSuccess = false; workspace.lock(); plans.lock()
                nativeContacts.clear(); recipientContactID = nil; recipientSearch = ""
            }
        }
    }

    private var contactPicker: some View {
        RecipientPicker(contacts: nativeContacts, search: $recipientSearch, contactID: $recipientContactID,
                        selected: workspace.selectedRecipient, choose: { recipient in
            workspace.selectRecipient(recipient); review = nil
            notice = "Recipient changed. Choose a destination before drafting."
        }, connect: connectContacts)
    }
    private func connectContacts() {
        Task {
            guard session.unlocked else { return }
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
        VStack(alignment: .leading, spacing: 22) {
            Text("A conversation, a draft, your decision.").font(.title2)
            contactPicker
            Text("Draft for the selected contact. Conversation history and AI generation are not connected yet.")
                .font(.caption).foregroundStyle(.secondary)
            editor
            DisclosureGroup("AI assistance") {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Draft language", selection: $language) {
                        Text("English").tag("English"); Text("Vietnamese").tag("Vietnamese")
                    }
                    Button("Load example draft") {
                        guard workspace.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            notice = "Clear your edited text before loading an example. Your draft was preserved."; return
                        }
                        workspace.editMessage(language == "English" ? "What time works for you?" : "Thời gian nào phù hợp với bạn?")
                        notice = "Example only. Local Ollama is not connected yet."
                    }.disabled(!workspace.canReviewRecipient)
                }.padding(.top, 12)
            }
            Button("Review schedule") { destination = .plan }.buttonStyle(.borderedProminent)
                .disabled(!workspace.canReviewRecipient || workspace.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            DisclosureGroup("Input sources") { Text("Selected Apple Contacts recipient. No conversation history is loaded.").padding(.top, 8) }
        }
    }
    private var plan: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text("Your plan").font(.title2)
                Spacer()
                Button("New message") { workspace.newPlan(); notice = "New demo plan." }
            }
            Toggle("Pause delivery", isOn: Binding(get: { workspace.deliveryPaused }, set: { workspace.setDeliveryPaused($0) }))
            Text("No worker is connected. This switch demonstrates the control.").font(.caption).foregroundStyle(.secondary)
            Text(workspace.state.rawValue).foregroundStyle(.tint)
            contactPicker
            editor
            DatePicker("Scheduled time", selection: Binding(get: { workspace.date }, set: { workspace.editDate($0) }), displayedComponents: [.date, .hourAndMinute])
            Text("Timezone: \(TimeZone.current.identifier)").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Review exact plan") {
                    do { if validateRecipient() { review = try workspace.review() } }
                    catch { notice = "Choose a future time and a nonempty message of at most 2,000 characters." }
                }.buttonStyle(.borderedProminent).disabled(!workspace.canReviewRecipient || !plans.ready)
                Button("Cancel plan") { workspace.cancel(); notice = "Demo plan cancelled." }
            }
            Divider()
            HStack {
                Text("Saved plans").font(.headline)
                Spacer()
                Button("Refresh saved plans") { plans.refresh() }
            }
            Text("Encrypted on this Mac. These are draft-only plans; delivery is disabled.")
                .font(.caption).foregroundStyle(.secondary)
            if !plans.errorMessage.isEmpty {
                Label(plans.errorMessage, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
            }
            if plans.ready && plans.plans.isEmpty {
                Text("No saved plans yet.").foregroundStyle(.secondary)
            }
            ForEach(plans.plans) { record in
                let item = record.snapshot
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(item.recipient.name).font(.subheadline.bold())
                        Spacer()
                        Text(record.status == .cancelled ? "Cancelled" : "Draft only").font(.caption)
                    }
                    Text(item.recipient.address).font(.caption)
                    Text(item.message)
                    Text(item.date.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                    if record.status != .cancelled {
                        Button("Cancel saved plan") {
                            do { try plans.cancel(record.id); notice = "Saved plan cancelled." }
                            catch { notice = "Could not cancel this plan. Refresh saved plans and retry." }
                        }
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
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
                    await nativeContacts.load(requestPermission: true)
                }
            }.disabled(nativeContacts.loading)
            SyncedContactsView(session: session, native: nativeContacts)
        }
    }
}
