import SwiftUI
import NativeServices
import AssistantCore

struct PlanActionReviewView: View {
    let preview: PreparedPlanAction
    let confirm: () -> Void
    let back: () -> Void
    private var title: String {
        switch preview.mutation.kind {
        case .create: "Review new plan"
        case .update: "Review plan changes"
        case .cancel: "Review plan cancellation"
        }
    }
    private var confirmation: String {
        switch preview.mutation.kind {
        case .create: "Confirm plan"
        case .update: "Save changes"
        case .cancel: "Cancel saved plan"
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(title).font(.title2)
                if let previous = preview.previous {
                    Text("Current saved plan · revision \(previous.revision)").font(.headline)
                    details(previous.snapshot, zone: previous.timezone)
                    if preview.mutation.kind == .update { Divider(); Text("Proposed replacement").font(.headline) }
                }
                if let next = preview.mutation.review { details(next, zone: preview.mutation.timezone) }
                Divider()
                Text(preview.mutation.kind == .cancel
                     ? "This marks the saved plan cancelled. It stays in your history."
                     : "Confirming saves a draft-only plan on this Mac. Nothing is scheduled or sent.")
                    .foregroundStyle(.secondary)
                Text("This review expires in two minutes. Any intervening change requires another review.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Back", action: back).keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(confirmation, action: confirm).buttonStyle(.borderedProminent)
                }
            }.padding(28)
        }.frame(width: 520, height: preview.mutation.kind == .update ? 600 : 440)
    }
    private func details(_ snapshot: Review, zone: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(snapshot.recipient.name).font(.subheadline.bold())
            Text("\(snapshot.recipient.kind == .phone ? "Phone" : "Email"): \(snapshot.recipient.address)")
            Text(snapshot.message).textSelection(.enabled)
            Text(formatted(snapshot.date, zone: zone))
            Text("Timezone: \(zone ?? "Not recorded; displayed in this Mac’s timezone")").font(.caption)
        }
    }
    private func formatted(_ date: Date, zone: String?) -> String {
        let formatter = DateFormatter(); formatter.dateStyle = .medium; formatter.timeStyle = .short
        formatter.timeZone = zone.flatMap(TimeZone.init(identifier:)) ?? .current
        return formatter.string(from: date)
    }
}
