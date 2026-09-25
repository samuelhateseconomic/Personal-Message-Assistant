import SwiftUI
import AssistantCore

@main
struct MessageAssistantApp: App {
    var body: some Scene {
        WindowGroup {
            WorkspaceView()
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
    @State private var workspace = Workspace()
    @State private var destination: Destination? = .assistant
    @State private var review: Review?
    @State private var notice = ""
    @State private var language = "English"
    @State private var contactName = ""
    @State private var contactEmail = ""
    @State private var contactLanguage = "English"
    @State private var contactConflict = false
    @State private var showContactReview = false

    var body: some View {
        Group {
            if workspace.isLocked {
                VStack(spacing: 18) {
                    Image(systemName: "lock").font(.largeTitle).accessibilityHidden(true)
                    Text("Workspace locked").font(.title2)
                    Text("Native authentication will be connected in the next milestone.")
                        .foregroundStyle(.secondary)
                    Button("Simulate successful unlock") { workspace.simulateUnlock() }
                        .buttonStyle(.borderedProminent)
                    Text("Demo only · No password is requested").font(.caption)
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
                            Text("Native prototype · Synthetic data only")
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
                        Button { review = nil; showContactReview = false; workspace.lock() } label: {
                            Label("Lock demo", systemImage: "lock")
                        }
                    }
                }
            }
        }
        .sheet(item: $review) { snapshot in
            VStack(alignment: .leading, spacing: 18) {
                Text("Review exact plan").font(.title2)
                Text("To: \(snapshot.contact.name)").font(.headline)
                Text("Synthetic endpoint · No real recipient").foregroundStyle(.secondary)
                Text(snapshot.message).textSelection(.enabled)
                Text(snapshot.date.formatted(date: .abbreviated, time: .shortened))
                Text(TimeZone.current.identifier).font(.caption)
                Divider()
                Text("Approving changes only this demo. Nothing will be sent or scheduled.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Back") { review = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Approve demo plan") {
                        do { try workspace.approve(snapshot); notice = "Demo plan approved. Any edit requires a new review." }
                        catch { notice = "The plan changed or its time passed. Review it again." }
                        review = nil
                    }.buttonStyle(.borderedProminent)
                }
            }.padding(28).frame(width: 450)
        }
        .sheet(isPresented: $showContactReview) {
            VStack(alignment: .leading, spacing: 18) {
                Text(contactConflict ? "Resolve contact conflict" : "Review contact update").font(.title2)
                Text("Your edit: \(contactName) · \(contactEmail)")
                if contactConflict {
                    Text("Incoming value: alex.updated@example.test")
                    Button("Use incoming email in demo") {
                        contactEmail = "alex.updated@example.test"
                        saveDemoContact()
                    }
                }
                Text("This changes synthetic data only. Mac Contacts is not connected.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Cancel") { showContactReview = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Save my edit in demo") { saveDemoContact() }.buttonStyle(.borderedProminent)
                }
            }.padding(28).frame(width: 480)
        }
        .onChange(of: destination) { _, _ in notice = ""; loadContact() }
        .onAppear { loadContact() }
    }

    private var contactPicker: some View {
        Picker("Contact", selection: Binding(get: { workspace.selectedID }, set: {
            workspace.select($0); loadContact(); notice = "Contact changed; the previous draft was cleared in this prototype."
        })) {
            ForEach(workspace.contacts) { Text($0.name).tag($0.id) }
        }.pickerStyle(.menu)
    }
    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Message").font(.headline)
            TextEditor(text: Binding(get: { workspace.message }, set: { workspace.editMessage($0) }))
                .frame(height: 125).padding(8)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                .accessibilityLabel("Message draft")
            Text("\(workspace.message.count) / 2,000 characters").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var assistant: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("A conversation, a draft, your decision.").font(.title2)
            contactPicker
            Text("Would you like to catch up this weekend?")
                .padding(18).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            Text("Synthetic incoming message").font(.caption).foregroundStyle(.secondary)
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
                    }
                }.padding(.top, 12)
            }
            Button("Review schedule") { destination = .plan }.buttonStyle(.borderedProminent)
                .disabled(workspace.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            DisclosureGroup("Input sources") { Text("One synthetic message. No private history is loaded.").padding(.top, 8) }
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
                    do { review = try workspace.review() }
                    catch { notice = "Choose a future time and a nonempty message of at most 2,000 characters." }
                }.buttonStyle(.borderedProminent)
                Button("Cancel plan") { workspace.cancel(); notice = "Demo plan cancelled." }
            }
        }
    }
    private var contacts: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Contacts").font(.title2)
            contactPicker
            Text("Demo address book").foregroundStyle(.secondary)
            VStack(alignment: .leading) {
                TextField("Name", text: $contactName)
                TextField("Email", text: $contactEmail)
            }.textFieldStyle(.roundedBorder)
            HStack {
                Button("Review contact save") { showContactReview = true }.buttonStyle(.borderedProminent)
                    .disabled(contactName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Simulate competing edit") { contactConflict = true; notice = "A synthetic incoming email edit will be shown at review." }
            }
            Divider()
            Text("App preferences").font(.headline)
            Picker("Preferred language", selection: $contactLanguage) {
                Text("English").tag("English"); Text("Vietnamese").tag("Vietnamese")
            }
            Text("Changes are included in the demo save. Native Contacts sync and preference persistence are next milestones.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func loadContact() {
        contactName = workspace.selected.name; contactEmail = workspace.selected.email
        contactLanguage = workspace.selected.language; contactConflict = false
    }
    private func saveDemoContact() {
        workspace.saveContact(name: contactName, email: contactEmail, language: contactLanguage)
        contactConflict = false; showContactReview = false
        notice = "Synthetic contact updated for this session only."
    }
}
