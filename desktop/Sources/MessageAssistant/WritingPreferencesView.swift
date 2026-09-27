import SwiftUI
import NativeServices

struct WritingPreferencesView: View {
    @ObservedObject var preferences: WritingPreferencesController
    @State private var confirmForget = false
    @State private var confirmReload = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Writing preferences").font(.title2)
            Text("Save the style you want the assistant to remember. Only choices you explicitly save become memory. Nothing is learned automatically from messages, contacts or edits.")
                .foregroundStyle(.secondary)
            if let record = preferences.record, let style = record.style {
                Label("Saved by you", systemImage: "checkmark.circle").font(.headline)
                Text(style.summary)
                Text("Updated \(record.updatedAt.formatted()) · encrypted on this Mac").font(.caption).foregroundStyle(.secondary)
            } else if preferences.ready { Text("No saved writing preferences.").foregroundStyle(.secondary) }
            Picker("Tone", selection: $preferences.edited.tone) {
                ForEach(WritingStyle.Tone.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            Picker("Length", selection: $preferences.edited.length) {
                Text("Brief · 1–2 sentences").tag(WritingStyle.Length.brief)
                Text("Standard · up to 4 sentences").tag(WritingStyle.Length.standard)
            }
            Picker("Emoji", selection: $preferences.edited.emoji) {
                Text("None").tag(WritingStyle.Emoji.none)
                Text("Light · at most one").tag(WritingStyle.Emoji.light)
            }
            Text("To save: \(preferences.edited.summary)").font(.callout)
            HStack {
                Button("Save these preferences") { preferences.save() }
                    .buttonStyle(.borderedProminent).disabled(!preferences.ready || !preferences.dirty)
                Button("Reload saved preferences") {
                    if preferences.dirty { confirmReload = true } else { preferences.refresh() }
                }
                Button("Forget saved preferences…", role: .destructive) { confirmForget = true }
                    .disabled(!preferences.ready || preferences.record?.style == nil)
            }
            if !preferences.status.isEmpty {
                Label(preferences.status, systemImage: preferences.failed ? "exclamationmark.circle" : "checkmark.circle")
                    .foregroundStyle(preferences.failed ? .red : .green)
            }
            Text("In Assistant’s context preview, turn on “Use saved writing preferences” for a draft. They affect wording only; they cannot select contacts, approve changes, or send messages. Saved plans and existing messages do not change when you edit or forget a preference.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog("Forget saved writing preferences?", isPresented: $confirmForget) {
            Button("Forget preferences", role: .destructive) { preferences.forget() }
            Button("Keep preferences", role: .cancel) {}
        } message: { Text("This removes the saved style and resets the controls. Contacts and plans stay unchanged.") }
        .confirmationDialog("Replace your unsaved preference edits?", isPresented: $confirmReload) {
            Button("Reload saved preferences", role: .destructive) { preferences.refresh() }
            Button("Keep editing", role: .cancel) {}
        }
    }
}
