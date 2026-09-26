import SwiftUI
import AssistantCore
import NativeServices

struct SavedPlansView: View {
    @ObservedObject var plans: PlanRepository
    @ObservedObject var metadata: ProfileSearchIndex
    let contacts: [NativeContactRow]
    @Binding var notice: String
    @State private var filter = PlanSearch()
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
            ForEach(matches) { record in
                let item = record.snapshot
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(item.recipient.name).font(.subheadline.bold())
                        Spacer()
                        Text(record.status == .cancelled ? "Cancelled" : "Saved draft").font(.caption)
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
}
