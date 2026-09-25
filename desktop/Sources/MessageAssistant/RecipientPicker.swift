import SwiftUI
import AssistantCore
import NativeServices

struct RecipientPicker: View {
    @ObservedObject var contacts: NativeContacts
    @Binding var search: String
    @Binding var contactID: String?
    let selected: Recipient?
    let choose: (Recipient?) -> Void
    let connect: () -> Void

    private var current: NativeContactRow? { contacts.rows.first { $0.id == contactID } }
    static func endpoints(_ row: NativeContactRow) -> [Recipient] {
        let values = row.phones.map { Recipient(nativeID: row.id, name: row.name, kind: .phone, address: $0) }
            + row.emails.map { Recipient(nativeID: row.id, name: row.name, kind: .email, address: $0) }
        var seen = Set<String>()
        return values.filter { !$0.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert($0.id).inserted }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recipient · Apple Contacts").font(.headline)
                Spacer()
                Button(contacts.loading ? "Connecting…" : (contacts.isConnected ? "Refresh contacts" : "Connect Apple Contacts"), action: connect)
                    .disabled(contacts.loading)
            }
            if contacts.isConnected {
                TextField("Search recipient by name, phone or email", text: $search).textFieldStyle(.roundedBorder)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(contacts.rows.filter { row in
                            search.isEmpty || ([row.name] + row.phones + row.emails).contains { $0.localizedCaseInsensitiveContains(search) }
                        }) { row in
                            Button {
                                guard contactID != row.id else { return }
                                contactID = row.id
                                let choices = Self.endpoints(row)
                                choose(choices.count == 1 ? choices[0] : nil)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(row.name)
                                        Text(row.phones.first ?? row.emails.first ?? "No phone or email")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if contactID == row.id { Image(systemName: "checkmark") }
                                }.padding(6).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            .background(contactID == row.id ? Color.accentColor.opacity(0.1) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }.frame(height: 125)
                if let current {
                    let endpoints = Self.endpoints(current)
                    Text(current.name).font(.subheadline.bold())
                    if endpoints.isEmpty {
                        Text("This contact has no phone number or email. Add one in Contacts before reviewing a plan.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Send to", selection: Binding(get: { selected?.id ?? "" }, set: { id in
                            choose(endpoints.first { $0.id == id })
                        })) {
                            Text("Choose a number or email").tag("")
                            ForEach(endpoints) { Text("\($0.kind == .phone ? "Phone" : "Email"): \($0.address)").tag($0.id) }
                        }
                    }
                } else { Text("Select a contact to start a draft.").foregroundStyle(.secondary) }
                if let selected {
                    Text("Selected: \(selected.name) · \(selected.address)").font(.caption).textSelection(.enabled)
                }
            } else {
                Text(contacts.status).font(.caption).foregroundStyle(.secondary)
            }
            Text("Assistant and Plan share this recipient. Changing the contact or destination clears the previous draft and approval.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
