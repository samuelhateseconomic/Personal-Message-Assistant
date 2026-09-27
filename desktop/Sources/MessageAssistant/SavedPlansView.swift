import SwiftUI
import AssistantCore
import NativeServices

struct SavedPlansView: View {
    @ObservedObject var plans: PlanRepository
    @ObservedObject var metadata: ProfileSearchIndex
    let contacts: [NativeContactRow]
    @Binding var notice: String
    @Binding var filter: PlanSearch
    @Binding var selectedID: UUID?
    let edit: (StoredPlan) -> Void
    let cancel: (StoredPlan) -> Void
    private func record(_ plan: StoredPlan) -> SearchRecord {
        let person = plan.snapshot.recipient
        let profile = metadata.profiles["mac:" + person.nativeID]
        let current = contacts.first { $0.id == person.nativeID }
        return SearchRecord(fields: [person.name, person.address, plan.snapshot.message, profile?.name ?? "",
            profile?.connection ?? "", profile?.note ?? "", current?.name ?? ""] + (current?.phones ?? []) + (current?.emails ?? []),
            connection: profile?.connection ?? "", contactID: person.nativeID, status: plan.status.rawValue, date: plan.snapshot.date)
    }
    private var matches: [StoredPlan] { plans.plans.filter { filter.matches(record($0)) }.sorted { $0.snapshot.date < $1.snapshot.date } }
    private var contactChoices: [SearchChoice] {
        var seen = Set<String>()
        return plans.plans.compactMap { plan in
            let recipient = plan.snapshot.recipient
            guard seen.insert(recipient.nativeID).inserted else { return nil }
            let name = contacts.first { $0.id == recipient.nativeID }?.name ?? recipient.name
            return SearchChoice(id: recipient.nativeID, name: name)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Saved plans").font(.headline)
                Spacer()
                Button("Refresh saved plans") { plans.refresh(); metadata.refresh() }
            }
            SearchFilters(filter: $filter,
                          connections: SearchFilters.connectionChoices(plans.plans.map { metadata.profiles["mac:" + $0.snapshot.recipient.nativeID]?.connection ?? "" }),
                          contacts: contactChoices, plans: true)
            Text("\(matches.count) of \(plans.plans.count) plans · All keywords must match across the available fields.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Private contact notes are searched locally and are not shown in results. Plans remain draft-only.")
                .font(.caption).foregroundStyle(.secondary)
            if !plans.errorMessage.isEmpty { Label(plans.errorMessage, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red) }
            if !metadata.errorMessage.isEmpty { Text(metadata.errorMessage).foregroundStyle(.secondary) }
            if plans.ready && matches.isEmpty {
                Text(plans.plans.isEmpty ? "No saved plans yet." : "No matching plans. Try fewer keywords or clear a filter.").foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(matches) { record in
                        Button { selectedID = record.id } label: {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(record.snapshot.recipient.name).font(.subheadline.bold())
                                    Text(record.snapshot.message).lineLimit(1).foregroundStyle(.secondary)
                                    Text(record.snapshot.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(record.status == .cancelled ? "Cancelled" : "Saved draft").font(.caption)
                                if selectedID == record.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .background(selectedID == record.id ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.05),
                                        in: RoundedRectangle(cornerRadius: 8))
                            .accessibilityLabel("\(record.snapshot.recipient.name), \(record.status == .cancelled ? "Cancelled" : "Saved draft"), \(record.snapshot.date.formatted())")
                    }
                }
            }.frame(maxHeight: 260)
            if let selectedID, let record = plans.plans.first(where: { $0.id == selectedID }) {
                let item = record.snapshot
                Divider()
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Plan details").font(.headline)
                        Spacer()
                        Text(record.status == .cancelled ? "Cancelled" : "Saved draft").foregroundStyle(.secondary)
                    }
                    if !matches.contains(where: { $0.id == record.id }) {
                        Text("This selected plan is outside the current search results.").font(.caption).foregroundStyle(.secondary)
                    }
                    LabeledContent("Recipient", value: item.recipient.name)
                    LabeledContent(item.recipient.kind == .phone ? "Phone" : "Email", value: item.recipient.address)
                    LabeledContent("Planned time", value: formattedDate(item.date, timezone: record.timezone))
                    Text("Timezone: \(record.timezone ?? "Not recorded by the older app; displayed in this Mac’s timezone") · Revision \(record.revision)").font(.caption).foregroundStyle(.secondary)
                    Text(item.message).textSelection(.enabled).padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    Text("Saved \(record.createdAt.formatted(date: .abbreviated, time: .shortened)). Delivery is disabled.")
                        .font(.caption).foregroundStyle(.secondary)
                    if record.status != .cancelled {
                        HStack {
                            Button("Edit plan") { edit(record) }.buttonStyle(.borderedProminent)
                            Button("Cancel saved plan") { cancel(record) }
                        }
                    }
                }
            } else if !plans.plans.isEmpty {
                Text("Select a plan to see its full message and details.").foregroundStyle(.secondary)
            }
        }
    }
    private func formattedDate(_ date: Date, timezone: String?) -> String {
        let formatter = DateFormatter(); formatter.dateStyle = .medium; formatter.timeStyle = .short
        formatter.timeZone = timezone.flatMap(TimeZone.init(identifier:)) ?? .current
        return formatter.string(from: date)
    }

}
