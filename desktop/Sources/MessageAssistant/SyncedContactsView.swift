import SwiftUI
import NativeServices

/// Native fields live in Apple Contacts; assistant annotations remain local.
struct SyncedContactsView: View {
    @ObservedObject var session: NativeSession
    @ObservedObject var native: NativeContacts
    @State private var service: ContactSyncService?
    @State private var accounts: [ContactAccount] = []
    @State private var search = ""
    @State private var showEditor = false
    @State private var base: ContactSnapshot?
    @State private var draft = ContactFields()
    @State private var accountID = ""
    @State private var connection = ""
    @State private var note = ""
    @State private var localSource: String?
    @State private var localProfiles: [String: ContactProfile] = [:]
    @State private var review: ContactSaveReview?
    @State private var status = ""
    @State private var error = ""
    @State private var editorError = ""
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
            service = ContactSyncService(isUnlocked: { session.unlocked })
            refreshAccounts()
        }
        .onChange(of: native.loading) { _, loading in if !loading { refreshAccounts() } }
        .onChange(of: session.unlocked) { _, unlocked in
            if !unlocked { showEditor = false; clearEditor(); localProfiles = [:]; accounts = []; service = nil }
        }
        .sheet(isPresented: $showEditor, onDismiss: { clearEditor() }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(review == nil ? (base == nil ? "New contact" : "Edit contact") : "Review Apple Contacts save").font(.title2)
                    if !editorError.isEmpty {
                        Label(editorError, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
                    }
                    if let current = conflictCurrent { conflictPanel(current) }
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
                        guard let id = base?.id else { return }; edit(id)
                    }.help("Discard this edit and load the current Apple Contacts record")
                }
                Spacer()
                Button("Review save") { prepareReview() }.buttonStyle(.borderedProminent)
                    .disabled(uncertain || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (base == nil && accountID.isEmpty))
            }
            if uncertain { Text("Close this form and inspect Apple Contacts before starting another save.").font(.caption) }
        }.textFieldStyle(.roundedBorder)
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
        base = nil; draft = ContactFields(); accountID = ""; connection = ""; note = ""; localSource = nil
        review = nil; editorError = ""; uncertain = false; savedNative = nil
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
            clearEditor(); base = record; draft = record.fields; accountID = record.accountID
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
            guard let saved = try service?.commit(snapshot) else { return }
            savedNative = saved; review = nil
            saveAnnotations()
        } catch let error as ContactSyncError {
            review = nil; editorError = error.localizedDescription
            if case .uncertain = error { uncertain = true }
        } catch {
            review = nil; uncertain = true
            editorError = "Apple Contacts did not confirm the save. Your entries are kept. Check permission, account writability, and the contact in Apple Contacts before trying again."
        }
    }
    private func saveAnnotations() {
        guard session.unlocked, let saved = savedNative else { return }
        do {
            let value = ContactProfile(name: saved.fields.name, connection: connection, note: note)
            try profiles.saveLinked(value, nativeID: saved.id, replacing: localSource)
            status = "Contact saved successfully to Apple Contacts and this app."
            showEditor = false
            Task { await native.load(requestPermission: false) }
        } catch { editorError = ContactSyncError.verifiedWritePendingLocal.localizedDescription }
    }
}
