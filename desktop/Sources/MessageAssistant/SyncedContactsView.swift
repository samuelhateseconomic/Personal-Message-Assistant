import SwiftUI
import NativeServices

/// Native fields live in Apple Contacts; assistant annotations remain local.
struct SyncedContactsView: View {
    @ObservedObject var session: NativeSession
    @ObservedObject var native: NativeContacts
    @ObservedObject var plans: PlanRepository
    var initialProposal: AssistantContactProposal? = nil
    var proposalConsumed: () -> Void = {}
    var onResult: (String) -> Void = { _ in }
    var onWorkflowEvent: (ContactWorkflowEvent) -> Void = { _ in }
    @State private var activeProposalID: UUID?
    @State private var service: ContactSyncService?
    @State private var saveCoordinator: ContactSaveCoordinator?
    @State private var saveReceiptID: UUID?
    @State private var recoveryRevision = UUID()
    @State private var deletionService: ContactDeletionService?
    @State private var deleteReview: ContactDeletionReview?
    @State private var pendingDeletes: [ContactDeletionReceipt] = []
    @State private var accounts: [ContactAccount] = []
    @State private var search = ""
    @State private var showEditor = false
    @State private var base: ContactSnapshot?
    @State private var draft = ContactFields()
    @State private var accountID = ""
    @State private var connection = ""
    @State private var note = ""
    @State private var originalProfile: ContactProfile?
    @State private var sourceProfile: ContactProfile?
    @State private var localSource: String?
    @State private var localProfiles: [String: ContactProfile] = [:]
    @State private var review: ContactSaveReview?
    @State private var status = ""
    @State private var error = ""
    @State private var editorError = ""
    @State private var editorNotice = ""
    @State private var uncertain = false
    @State private var conflictFields: [String] = []
    @State private var conflictCurrent: ContactSnapshot?
    @State private var conflictChoices: [String: Bool] = [:]
    @State private var conflictEdited = ContactFields()
    @State private var savedNative: ContactSnapshot?
    private let profiles = ContactProfileStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button("New contact in Apple Contacts", systemImage: "plus") { begin() }
                    .buttonStyle(.borderedProminent).disabled(accounts.isEmpty)
                Menu("Add app-only contact…") {
                    ForEach(localProfiles.keys.filter { $0.hasPrefix("local:") }.sorted(), id: \.self) { id in
                        Button(localProfiles[id]?.name ?? "Contact") { begin(localID: id) }
                    }
                }.disabled(accounts.isEmpty || !localProfiles.keys.contains { $0.hasPrefix("local:") })
            }
            Text("Native names, numbers, email and birthday save to the chosen Contacts account. Connection type and notes stay in this app. Account syncing to your other devices is managed by macOS.")
                .font(.caption).foregroundStyle(.secondary)
            if !status.isEmpty { Label(status, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            if !error.isEmpty { Label(error, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red) }
            if let saveCoordinator {
                ContactSaveRecoveryView(coordinator: saveCoordinator, native: native) { receipt in
                    if let proposal = receipt.proposalID, let saved = receipt.saved {
                        onWorkflowEvent(.verified(proposal, saved)); onWorkflowEvent(.annotationsSaved(proposal))
                    }
                    onResult("Recovered local contact notes successfully.")
                    Task { await native.load(requestPermission: false) }
                }.id(recoveryRevision)
            }
            ForEach(pendingDeletes) { receipt in
                HStack {
                    Text("\(receipt.name) · \(receipt.account.name) · \(receipt.state == .deleted ? "local cleanup pending" : "deletion unconfirmed")")
                    Spacer()
                    Button(receipt.state == .deleted ? "Retry local cleanup" : "Check result") { recoverDelete(receipt.id) }
                }.font(.callout)
            }
            TextField("Search name, phone or email", text: $search).textFieldStyle(.roundedBorder)
            LazyVStack(alignment: .leading) {
                ForEach(native.rows.filter { row in
                    search.isEmpty || ([row.name] + row.phones + row.emails).contains { $0.localizedCaseInsensitiveContains(search) }
                }) { row in
                    Button { edit(row.id) } label: {
                        HStack { Text(row.name); Spacer(); Image(systemName: "pencil") }.padding(.vertical, 6)
                    }.buttonStyle(.plain)
                    Divider()
                }
            }
        }
        .onAppear {
            let nativeService = ContactSyncService(isUnlocked: { session.unlocked })
            service = nativeService
            saveCoordinator = ContactSaveCoordinator(contacts: nativeService, isUnlocked: { session.unlocked })
            deletionService = ContactDeletionService(plans: plans, isUnlocked: { session.unlocked })
            refreshAccounts()
            refreshDeletions()
            receiveProposal()
        }
        .onChange(of: initialProposal?.id) { _, _ in receiveProposal() }
        .onChange(of: native.loading) { _, loading in if !loading { refreshAccounts() } }
        .onChange(of: session.unlocked) { _, unlocked in
            if !unlocked {
                saveCoordinator = nil; saveReceiptID = nil
                service?.invalidate()
                deletionService?.invalidate(); deletionService = nil; pendingDeletes = []
                showEditor = false; clearEditor(); localProfiles = [:]; accounts = []; service = nil
            }
        }
        .sheet(isPresented: $showEditor, onDismiss: { clearEditor() }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(deleteReview != nil ? "Review contact deletion" : (review == nil ? (base == nil ? "New contact" : "Edit contact") : "Review Apple Contacts save")).font(.title2)
                    if !editorError.isEmpty {
                        Label(editorError, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
                    }
                    if !editorNotice.isEmpty { Text(editorNotice).font(.caption).foregroundStyle(.secondary) }
                    if let deleteReview { deletionPanel(deleteReview) }
                    else if let current = conflictCurrent { conflictPanel(current) }
                    else if let review { reviewPanel(review) }
                    else if savedNative != nil {
                        Text("Apple Contacts has been saved. Your local connection type and notes still need saving.")
                        Button("Retry local notes only") { saveAnnotations() }.buttonStyle(.borderedProminent)
                        Button("Close") { showEditor = false }
                    } else { editor }
                }.padding(24)
            }.frame(width: 560, height: 660)
                .interactiveDismissDisabled()
        }
    }
    private var editor: some View {
        VStack(alignment: .leading, spacing: 14) {
            if base == nil {
                Picker("Destination account", selection: $accountID) {
                    Text("Choose an account").tag("")
                    ForEach(accounts) { Text($0.name).tag($0.id) }
                }
                Text("The selected account must allow new contacts. Apple Contacts will reject read-only accounts.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Account: \(accounts.first { $0.id == base?.accountID }?.name ?? "Unavailable")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TextField("First name", text: $draft.givenName)
            TextField("Last name", text: $draft.familyName)
            Text("Phone numbers · one per line, include country code").font(.caption)
            TextEditor(text: Binding(get: { draft.phones.joined(separator: "\n") }, set: { draft.phones = $0.components(separatedBy: "\n") }))
                .frame(height: 55).border(.separator).accessibilityLabel("Phone numbers")
            Text("Email addresses · one per line").font(.caption)
            TextEditor(text: Binding(get: { draft.emails.joined(separator: "\n") }, set: { draft.emails = $0.components(separatedBy: "\n") }))
                .frame(height: 55).border(.separator).accessibilityLabel("Email addresses")
            Toggle("Include birthday", isOn: Binding(get: { draft.birthday != nil }, set: {
                draft.birthday = $0 ? Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: Date()) : nil
            }))
            if let birthday = draft.birthday {
                Text("Birthday: \(birthday.month ?? 1)/\(birthday.day ?? 1)\(birthday.year.map { "/\($0)" } ?? " (year not provided)")").font(.caption)
                DatePicker("Change birthday", selection: Binding(get: {
                    Calendar(identifier: .gregorian).date(from: draft.birthday ?? DateComponents()) ?? Date()
                }, set: { draft.birthday = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: $0) }),
                           in: ...Date(), displayedComponents: .date)
            }
            Divider()
            Text("Only in this app").font(.headline)
            TextField("Connection type", text: $connection)
            TextEditor(text: $note).frame(height: 65).border(.separator).accessibilityLabel("Private contact notes")
            HStack {
                Button("Cancel") { showEditor = false }.keyboardShortcut(.cancelAction)
                if base != nil {
                    Button("Reload current contact") {
                        guard let id = base?.id else { return }
                        let proposal = activeProposalID; edit(id); activeProposalID = proposal
                    }.help("Discard this edit and load the current Apple Contacts record")
                }
                Spacer()
                Button("Review save") { prepareReview() }.buttonStyle(.borderedProminent)
                    .disabled(uncertain || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (base == nil && accountID.isEmpty))
            }
            if uncertain { Text("Close this form and use Contact saves needing recovery. No native save will be repeated.").font(.caption) }
            if let base {
                Divider()
                Button("Review deletion from Apple Contacts…", role: .destructive) { prepareDelete(base.id) }
                    .disabled(uncertain)
            }
        }.textFieldStyle(.roundedBorder)
    }
    private func deletionPanel(_ value: ContactDeletionReview) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(value.target.snapshot.fields.name).font(.headline)
            Text("Account: \(value.account.name)")
            Text(value.target.snapshot.fields.phones.joined(separator: "\n"))
            Text(value.target.snapshot.fields.emails.joined(separator: "\n"))
            if let profile = value.profile {
                Text("Local connection to remove: \(profile.connection.isEmpty ? "None" : profile.connection)")
                Text("Local note to remove: \(profile.note.isEmpty ? "None" : profile.note)")
            }
            Text("No active saved drafts refer to this card. Cancelled plans keep their historical snapshots.")
            Text("This deletes the entire source card, including fields not displayed here, and its saved local annotations. It may sync to other devices through this account. This app cannot undo it. Unsaved form edits are not included.")
            Text("Review expires in two minutes. Contacts changes require a new review; concurrent external writes can still race the final save.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Back") { deleteReview = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Delete this contact", role: .destructive) { confirmDelete(value) }.buttonStyle(.borderedProminent)
            }
        }
    }
    private func prepareDelete(_ id: String) {
        do { deleteReview = try deletionService?.prepare(id); editorError = "" }
        catch { editorError = deletionMessage(error) }
    }
    private func confirmDelete(_ value: ContactDeletionReview) {
        do {
            guard let deletionService else { return }
            try deletionService.confirm(value)
            status = "Contact deleted successfully from Apple Contacts and local annotations removed."
            onResult(status)
            showEditor = false
        } catch {
            deleteReview = nil; editorError = deletionMessage(error)
            if let value = error as? ContactDeletionError, value == .interrupted || value == .cleanup { uncertain = true }
        }
        refreshDeletions()
        Task { await native.load(requestPermission: false) }
    }
    private func refreshDeletions() {
        do { pendingDeletes = try deletionService?.pending() ?? [] }
        catch { self.error = deletionMessage(error) }
    }
    private func recoverDelete(_ id: UUID) {
        do {
            guard let deletionService else { return }
            let result = try deletionService.recover(id)
            status = result == .complete ? "Deletion verified and local cleanup completed."
                : "The contact is still present. Nothing was retried; open it for a fresh review if you still want to delete it."
            onResult(status)
            error = ""
        } catch { self.error = deletionMessage(error) }
        refreshDeletions()
        Task { await native.load(requestPermission: false) }
    }
    private func deletionMessage(_ value: any Error) -> String {
        if let value = value as? ContactDeletionError { return value.localizedDescription }
        if let value = value as? ContactSyncError { return value.localizedDescription }
        if let value = value as? PlanStorageError { return value.localizedDescription }
        return ContactDeletionError.storage.localizedDescription
    }
    private func receiveProposal() {
        guard let proposal = initialProposal, service != nil else { return }
        defer { proposalConsumed() }
        do {
            if let target = proposal.target {
                guard try service?.fetch(target.id) == target else { throw ContactSyncError.changed }
                edit(target.id)
                guard base != nil else { return }
                if proposal.intent.action == .deleteContact { prepareDelete(target.id); return }
            } else { begin() }
            draft = try proposal.intent.applying(to: draft)
            if let value = proposal.intent.connection { connection = value }
            if let value = proposal.intent.note { note = value }
            activeProposalID = proposal.id
            editorNotice = "Proposal from your request. Existing numbers are preserved; edit lines here if you intend to replace or remove one. Review all details before saving."
        } catch { self.error = (error as? LocalizedError)?.errorDescription ?? "The proposal could not be opened. Retrieve the contact again." }
    }
    private func reviewPanel(_ snapshot: ContactSaveReview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(snapshot.base == nil ? "Create in \(snapshot.account.name)" : "Update in \(snapshot.account.name)").font(.headline)
            Text(snapshot.fields.name)
            Text(snapshot.fields.phones.isEmpty ? "No phone numbers" : snapshot.fields.phones.joined(separator: "\n"))
            Text(snapshot.fields.emails.isEmpty ? "No email addresses" : snapshot.fields.emails.joined(separator: "\n"))
            if let birthday = snapshot.fields.birthday {
                Text("Birthday: \(birthday.month ?? 1)/\(birthday.day ?? 1)\(birthday.year.map { "/\($0)" } ?? " (no year)")")
            } else { Text("No birthday") }
            Text("Changed fields: \(snapshot.changedFields.isEmpty ? "None; local annotations only" : snapshot.changedFields.joined(separator: ", "))").font(.caption)
            Text("Connection: \(connection.isEmpty ? "None" : connection)")
            Text("Private note: \(note.isEmpty ? "None" : note)")
            Text("All listed numbers and emails will be saved. Removed lines are removed from this card. Notes and connection stay local. Concurrent edits are rechecked before saving; Apple does not provide an atomic conflict guarantee.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Review expires in two minutes.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Back") { review = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save to Apple Contacts") { commit(snapshot) }.buttonStyle(.borderedProminent)
            }
        }
    }
    private func fieldText(_ fields: ContactFields, _ key: String) -> String {
        switch key {
        case "First name": fields.givenName
        case "Last name": fields.familyName
        case "Phone numbers": fields.phones.joined(separator: "\n")
        case "Email addresses": fields.emails.joined(separator: "\n")
        default: fields.birthday.map { "\($0.month ?? 1)/\($0.day ?? 1) · year \($0.year.map(String.init) ?? "not provided")" } ?? "No birthday"
        }
    }
    private func conflictPanel(_ current: ContactSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Resolve conflicting edits").font(.headline)
            ForEach(conflictFields, id: \.self) { key in
                Text(key).font(.subheadline.bold())
                Text("Your edit: \(fieldText(conflictEdited, key))")
                Text("Apple Contacts: \(fieldText(current.fields, key))")
                HStack {
                    Button(conflictChoices[key] == true ? "✓ Keep my edit" : "Keep my edit") { conflictChoices[key] = true }
                    Button(conflictChoices[key] == false ? "✓ Use Apple Contacts" : "Use Apple Contacts") { conflictChoices[key] = false }
                }
            }
            HStack {
                Button("Back to editing") { conflictCurrent = nil; editorError = "" }
                Button("Apply choices and review") { resolveConflict(current) }
                    .disabled(conflictFields.contains { conflictChoices[$0] == nil })
            }
        }
    }
    private func resolveConflict(_ current: ContactSnapshot) {
        guard let old = base, current.accountID == old.accountID else {
            editorError = "The source account changed. Close and reopen this contact."; return
        }
        var resolvedBase = old.fields
        var edited = conflictEdited
        for key in conflictFields {
            // Treat an explicit choice as a new edit against the displayed native value.
            switch key {
            case "First name":
                resolvedBase.givenName = current.fields.givenName
                if conflictChoices[key] == false { edited.givenName = current.fields.givenName }
            case "Last name":
                resolvedBase.familyName = current.fields.familyName
                if conflictChoices[key] == false { edited.familyName = current.fields.familyName }
            case "Phone numbers":
                resolvedBase.phones = current.fields.phones
                if conflictChoices[key] == false { edited.phones = current.fields.phones }
            case "Email addresses":
                resolvedBase.emails = current.fields.emails
                if conflictChoices[key] == false { edited.emails = current.fields.emails }
            default:
                resolvedBase.birthday = current.fields.birthday
                if conflictChoices[key] == false { edited.birthday = current.fields.birthday }
            }
        }
        do {
            draft = try ContactSyncService.merge(base: resolvedBase, edited: edited, current: current.fields)
            base = current; conflictCurrent = nil; editorError = ""
            prepareReview()
        } catch { editorError = "Additional fields changed. Return to editing and review again." }
    }
    private func clearEditor() {
        saveReceiptID = nil; recoveryRevision = UUID(); originalProfile = nil; sourceProfile = nil
        base = nil; draft = ContactFields(); accountID = ""; connection = ""; note = ""; localSource = nil; activeProposalID = nil
        review = nil; deleteReview = nil; editorError = ""; editorNotice = ""; uncertain = false; savedNative = nil
        conflictCurrent = nil; conflictFields = []; conflictChoices = [:]; conflictEdited = ContactFields()
    }
    private func refreshAccounts() {
        do {
            localProfiles = try profiles.load()
            if !native.rows.isEmpty || native.status.hasPrefix("Contacts connection active") {
                accounts = try service?.accounts() ?? []
            } else { accounts = [] }
            error = ""
        } catch { self.error = "Could not load account or local profile information. Connect or refresh and try again."; accounts = [] }
    }
    private func begin(localID: String? = nil) {
        clearEditor(); status = ""; localSource = localID
        if let localID, let profile = localProfiles[localID] {
            sourceProfile = profile
            draft.givenName = profile.name; draft.phones = profile.phone.isEmpty ? [] : [profile.phone]
            draft.emails = profile.email.isEmpty ? [] : [profile.email]
            draft.birthday = profile.birthday.map { Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: $0) }
            connection = profile.connection; note = profile.note
        }
        showEditor = true
    }
    private func edit(_ id: String) {
        do {
            guard let record = try service?.fetch(id) else { return }
            let local = try profiles.load()["mac:" + id]
            clearEditor(); originalProfile = local; base = record; draft = record.fields; accountID = record.accountID
            connection = local?.connection ?? ""; note = local?.note ?? ""
            showEditor = true; status = ""
        } catch { self.error = "Could not open this source contact. Refresh the connection or edit it in Apple Contacts." }
    }
    private func prepareReview() {
        do {
            _ = try profiles.load() // Never write natively if the local profile store is already unreadable.
            var value = draft
            value.givenName = value.givenName.trimmingCharacters(in: .whitespacesAndNewlines)
            value.familyName = value.familyName.trimmingCharacters(in: .whitespacesAndNewlines)
            value.phones = value.phones.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            value.emails = value.emails.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            review = try service?.review(base: base, edited: value, accountID: accountID)
            editorError = ""
        } catch ContactSyncError.conflict(let fields) {
            do {
                guard let base, let current = try service?.fetch(base.id) else { return }
                conflictFields = fields; conflictCurrent = current; conflictEdited = draft; conflictChoices = [:]
                editorError = "Choose which value to keep for each conflict."
            } catch { editorError = "Could not reload the conflicting contact. Refresh and try again." }
        } catch let error as ContactSyncError { editorError = error.localizedDescription }
        catch { editorError = "Could not prepare the save. Check contact access and local storage, then try again." }
    }
    private func commit(_ snapshot: ContactSaveReview) {
        do {
            guard let saveCoordinator else { return }
            if let id = activeProposalID {
                onWorkflowEvent(.attempting(id, ContactProfile(name: snapshot.fields.name, connection: connection, note: note), originalProfile, localSource))
            }
            let receipt = try saveCoordinator.commit(snapshot,
                profile: ContactProfile(name: snapshot.fields.name, connection: connection, note: note),
                expectedProfile: originalProfile, localSource: localSource, expectedSource: sourceProfile, proposalID: activeProposalID)
            guard let saved = receipt.saved else { throw ContactSaveRecoveryError.uncertain }
            saveReceiptID = receipt.id; recoveryRevision = UUID()
            if let id = activeProposalID { onWorkflowEvent(.verified(id, saved)) }
            savedNative = saved; review = nil
            saveAnnotations()
        } catch let error as ContactSaveRecoveryError {
            review = nil; recoveryRevision = UUID(); editorError = error.localizedDescription
            uncertain = error == .storage || error == .uncertain
            if let id = activeProposalID { onWorkflowEvent(.failed(id, uncertain: uncertain)) }
        } catch let error as ContactSyncError {
            review = nil; editorError = error.localizedDescription
            if case .uncertain = error { uncertain = true }
            if let id = activeProposalID { onWorkflowEvent(.failed(id, uncertain: uncertain)) }
        } catch {
            review = nil; uncertain = true
            if let id = activeProposalID { onWorkflowEvent(.failed(id, uncertain: true)) }
            editorError = "Apple Contacts did not confirm the save. Your entries are kept. Check permission, account writability, and the contact in Apple Contacts before trying again."
        }
    }
    private func saveAnnotations() {
        guard session.unlocked, savedNative != nil, let saveReceiptID, let saveCoordinator else { return }
        do {
            _ = try saveCoordinator.finishNotes(saveReceiptID)
            recoveryRevision = UUID()
            status = "Contact saved successfully to Apple Contacts and this app."
            onResult(status)
            if let id = activeProposalID { onWorkflowEvent(.annotationsSaved(id)) }
            showEditor = false
            Task { await native.load(requestPermission: false) }
        } catch { editorError = ContactSyncError.verifiedWritePendingLocal.localizedDescription }
    }
}
