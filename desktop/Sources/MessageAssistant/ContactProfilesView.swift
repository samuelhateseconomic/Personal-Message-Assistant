import SwiftUI
import NativeServices

struct ProfileContact: Identifiable {
    let id: String
    let name: String
    var phones: [String] = []
    var emails: [String] = []
}

struct ContactProfilesView: View {
    let contacts: [ProfileContact]
    private let store = ContactProfileStore()
    @State private var profiles: [String: ContactProfile] = [:]
    @State private var search = ""
    @State private var selectedID: String?
    @State private var draft = ContactProfile(name: "")
    @State private var original = ContactProfile(name: "")
    @State private var status = ""
    @State private var saveFailed = false
    @State private var failedToLoad = false
    @State private var pendingSelection: ProfileContact?
    @State private var confirmDiscard = false
    @State private var creating = false
    @State private var pendingCreate = false
    private var selectedNative: ProfileContact? {
        guard let selectedID, selectedID.hasPrefix("mac:") else { return nil }
        return contacts.first { $0.id == selectedID }
    }
    private var isNative: Bool { selectedID?.hasPrefix("mac:") == true }
    private var dirty: Bool { draft != original }
    private var matches: [ProfileContact] {
        let local = profiles.filter { $0.key.hasPrefix("local:") }.map {
            ProfileContact(id: $0.key, name: $0.value.name)
        }
        return (contacts + local).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.filter {
            let profile = profiles[$0.id]
            return search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
                || (profile?.name.localizedCaseInsensitiveContains(search) ?? false)
                || (profile?.connection.localizedCaseInsensitiveContains(search) ?? false)
                || (profile?.phone.localizedCaseInsensitiveContains(search) ?? false)
                || (profile?.email.localizedCaseInsensitiveContains(search) ?? false)
                || $0.phones.contains { $0.localizedCaseInsensitiveContains(search) }
                || $0.emails.contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Contact profiles").font(.headline)
                Spacer()
                Button {
                    if dirty { pendingCreate = true; pendingSelection = nil; confirmDiscard = true }
                    else { beginCreate() }
                } label: { Label("New contact", systemImage: "plus") }
                .disabled(failedToLoad)
            }
            if !status.isEmpty { feedback }
            TextField("Search by name, number, email, or connection", text: $search)
                .textFieldStyle(.roundedBorder).accessibilityLabel("Search contacts")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(matches) { contact in
                        Button {
                            if dirty { pendingCreate = false; pendingSelection = contact; confirmDiscard = true }
                            else { select(contact) }
                        } label: {
                            HStack {
                                Text(profiles[contact.id]?.name ?? contact.name)
                                Spacer()
                                if contact.id.hasPrefix("local:") {
                                    Text("App only").font(.caption).foregroundStyle(.secondary)
                                }
                                if selectedID == contact.id { Image(systemName: "checkmark") }
                            }.padding(8).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        .background(selectedID == contact.id ? Color.accentColor.opacity(0.12) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                    }
                    if matches.isEmpty { Text("No matching contacts.").foregroundStyle(.secondary) }
                }
            }.frame(maxHeight: 180)
            if selectedID != nil {
                Divider()
                Text("Personal information").font(.headline)
                profileEditor
            } else {
                Text("Select a contact or choose New contact.").foregroundStyle(.secondary)
            }
            Text("Saved on this Mac in the app’s Application Support folder. These app-only details do not change Apple Contacts or go to the AI. Unsaved edits are discarded when you leave this panel or lock the app.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(isPresented: $creating, onDismiss: {
            // A closed creation form must never carry details into the next new contact.
            draft = ContactProfile(name: ""); original = draft
            selectedID = nil
        }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("New contact").font(.title2)
                    Text("Save an app-only contact on this Mac.").foregroundStyle(.secondary)
                    if saveFailed { feedback }
                    profileEditor
                }.padding(24)
            }
            .frame(width: 520, height: 600)
            .interactiveDismissDisabled(dirty)
        }
        .onAppear {
            do { profiles = try store.load(); failedToLoad = false }
            catch { failedToLoad = true; saveFailed = true; status = "Saved profiles could not be read. Saving is disabled to protect existing data." }
        }
        .confirmationDialog("Discard unsaved changes?", isPresented: $confirmDiscard) {
            Button("Discard and continue", role: .destructive) {
                if pendingCreate { beginCreate() }
                else if let contact = pendingSelection { select(contact) }
                pendingSelection = nil; pendingCreate = false
            }
            Button("Keep editing", role: .cancel) { pendingSelection = nil; pendingCreate = false }
        }
    }
    private var feedback: some View {
        Label(status, systemImage: saveFailed ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
            .font(.callout)
            .foregroundStyle(saveFailed ? Color.red : Color.green)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background((saveFailed ? Color.red : Color.green).opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel((saveFailed ? "Failure: " : "Success: ") + status)
    }
    private var profileEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
                if isNative {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("From Apple Contacts · read only").font(.subheadline.bold())
                        if let native = selectedNative {
                            Text(native.name)
                            Text("Phone numbers").font(.caption).foregroundStyle(.secondary)
                            Text(native.phones.isEmpty ? "No phone number" : native.phones.joined(separator: "\n")).textSelection(.enabled)
                            Text("Email addresses").font(.caption).foregroundStyle(.secondary)
                            Text(native.emails.isEmpty ? "No email address" : native.emails.joined(separator: "\n")).textSelection(.enabled)
                        } else {
                            Text("Contact unavailable or refreshing. Reconnect to verify its current details.")
                        }
                        Text("Edit these details in Apple Contacts, then use Connect / refresh. Changes also refresh automatically while connected. Saving below updates app-only information.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
                LabeledContent(isNative ? "App display name" : "Name") {
                    TextField("Name", text: $draft.name).textFieldStyle(.roundedBorder)
                }
                if !isNative {
                    LabeledContent("Phone number") {
                        TextField("Include country code, e.g. +1", text: $draft.phone).textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("Email") {
                        TextField("Email address", text: $draft.email).textFieldStyle(.roundedBorder)
                    }
                }
                LabeledContent("Connection type") {
                    TextField("Friend, family, partner, colleague…", text: $draft.connection).textFieldStyle(.roundedBorder)
                }
                Toggle("Include birthday", isOn: Binding(get: { draft.birthday != nil }, set: { draft.birthday = $0 ? Date() : nil }))
                if draft.birthday != nil {
                    DatePicker("Birthday", selection: Binding(get: { draft.birthday ?? Date() }, set: { draft.birthday = $0 }),
                               in: ...Date(), displayedComponents: .date)
                }
                Text("Note").font(.subheadline)
                TextEditor(text: $draft.note).frame(height: 100).padding(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator)).accessibilityLabel("Contact note")
                HStack {
                    Button(creating ? "Create contact" : "Save personal information") { save() }.buttonStyle(.borderedProminent)
                        .disabled(failedToLoad || !dirty || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button(creating ? "Cancel" : "Discard changes") {
                        if creating { resetNewContact() }
                        else { draft = original }
                        status = ""; saveFailed = false
                    }.disabled(!creating && !dirty)
                }
        }
    }
    private func resetNewContact() {
        creating = false; selectedID = nil
        draft = ContactProfile(name: ""); original = draft
    }
    private func select(_ contact: ProfileContact) {
        creating = false
        selectedID = contact.id
        draft = profiles[contact.id] ?? ContactProfile(name: contact.name)
        original = draft; status = ""; saveFailed = false
    }
    private func beginCreate() {
        creating = true; selectedID = nil; search = ""
        draft = ContactProfile(name: ""); original = draft; status = ""; saveFailed = false
    }
    private func save() {
        guard !failedToLoad, creating || selectedID != nil else { return }
        var value = draft
        value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.name.isEmpty else { return }
        do {
            let id: String
            if creating { id = try store.create(value) }
            else if let existingID = selectedID { id = existingID; try store.save(value, for: id) }
            else { return }
            profiles[id] = value
            saveFailed = false
            if creating {
                resetNewContact()
                status = "Contact created successfully."
            } else {
                draft = value; original = value
                status = "Personal information updated successfully."
            }
        } catch {
            saveFailed = true
            status = "Save failed. Your entries have been kept. Please try again."
        }
    }
}
