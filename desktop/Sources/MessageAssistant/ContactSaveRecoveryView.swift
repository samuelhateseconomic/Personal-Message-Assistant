import SwiftUI
import NativeServices

struct ContactSaveRecoveryView: View {
    let coordinator: ContactSaveCoordinator
    @ObservedObject var native: NativeContacts
    let completed: (ContactSaveReceipt) -> Void
    @State private var pending: [ContactSaveReceipt] = []
    @State private var selected: [UUID: String] = [:]
    @State private var dismissID: UUID?
    @State private var showDismiss = false
    @State private var error = ""
    @State private var status = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !pending.isEmpty {
                Text("Contact saves needing recovery").font(.headline)
                Text("Native saves are never replayed here. New contact saves are blocked until these records are resolved or explicitly dismissed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(pending) { receipt in
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(receipt.fields.name) · \(receipt.account.name)").font(.subheadline.bold())
                    Text((receipt.fields.phones + receipt.fields.emails).joined(separator: " · ")).font(.caption)
                    Text(receipt.state == .verified ? "Apple Contacts save verified; local notes pending" : "Save outcome unconfirmed")
                    if let profile = receipt.profile {
                        Text("Pending connection: \(profile.connection)")
                        Text("Pending private note: \(profile.note)")
                    }
                    if receipt.saved == nil && receipt.originalID == nil {
                        Text("Inspect Apple Contacts, then select the exact source card. A matching name alone does not establish identity.").font(.caption)
                        Picker("Existing source card", selection: Binding(get: { selected[receipt.id] ?? "" }, set: { selected[receipt.id] = $0 })) {
                            Text("Choose a card to verify").tag("")
                            ForEach(native.rows) { row in Text("\(row.name) · \((row.phones + row.emails).joined(separator: ", "))").tag(row.id) }
                        }
                    }
                    HStack {
                        Button("Check existing card only") {
                            perform {
                                _ = try coordinator.check(receipt.id, selectedID: selected[receipt.id])
                                status = "Existing card verified. Review the pending notes before saving them."
                            }
                        }.disabled(receipt.saved == nil && receipt.originalID == nil && (selected[receipt.id] ?? "").isEmpty)
                        if receipt.state == .verified {
                            Button("Save pending local notes only") {
                                perform { let result = try coordinator.finishNotes(receipt.id); completed(result); status = "Local notes saved. No Apple Contacts write was repeated." }
                            }
                        }
                        Button("Dismiss recovery…") { dismissID = receipt.id; showDismiss = true }
                    }
                }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            if !status.isEmpty { Text(status).foregroundStyle(.green) }
            if !error.isEmpty {
                Text(error).foregroundStyle(.red)
                Button("Reload recovery") { reload() }
            }
        }
        .onAppear { reload() }
        .confirmationDialog("Dismiss this recovery record?", isPresented: $showDismiss) {
            Button("I inspected Contacts; discard pending notes", role: .destructive) {
                guard let dismissID else { return }
                perform { try coordinator.dismiss(dismissID); status = "Recovery dismissed. No contact was changed; pending notes were discarded." }
            }
            Button("Keep recovery", role: .cancel) {}
        } message: {
            Text("Inspect Apple Contacts first. Dismissal does not prove whether the save succeeded and does not undo it. Creating another card afterward could create a duplicate. Saved contacts and existing notes remain unchanged.")
        }
    }
    private func reload() {
        do { pending = try coordinator.pending(); error = "" }
        catch { self.error = error.localizedDescription }
    }
    private func perform(_ operation: () throws -> Void) {
        do { try operation(); error = ""; pending = try coordinator.pending() }
        catch { self.error = error.localizedDescription; status = "" }
    }
}
