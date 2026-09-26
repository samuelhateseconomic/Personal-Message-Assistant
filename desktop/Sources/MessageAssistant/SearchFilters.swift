import SwiftUI
import AssistantCore

struct SearchChoice: Identifiable { let id: String; let name: String }
struct SearchFilters: View {
    @Binding var filter: PlanSearch
    var connections: [SearchChoice]
    var contacts: [SearchChoice] = []
    var plans = false
    @State private var showing = false
    private var count: Int { filter.connections.count + filter.contacts.count + filter.statuses.count + (filter.dateScope == .all ? 0 : 1) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField(plans ? "Search plans, names, connections or notes" : "Search names, numbers, connections or notes", text: $filter.query)
                    .textFieldStyle(.roundedBorder).accessibilityLabel(plans ? "Search saved plans" : "Search recipients")
                Button { showing.toggle() } label: {
                    Label(count == 0 ? "Filter" : "Filter (\(count))", systemImage: "line.3.horizontal.decrease.circle")
                }
                .popover(isPresented: $showing) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Filters").font(.headline)
                            if plans {
                                Text("Plan status").font(.subheadline.bold())
                                selection("Saved draft", id: "draftOnly", values: $filter.statuses)
                                selection("Cancelled", id: "cancelled", values: $filter.statuses)
                                Picker("Planned date", selection: $filter.dateScope) {
                                    ForEach(PlanSearch.DateScope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                                }
                                if filter.dateScope == .custom {
                                    DatePicker("From", selection: $filter.start, displayedComponents: .date)
                                    DatePicker("Through", selection: $filter.end, displayedComponents: .date)
                                    if Calendar.current.startOfDay(for: filter.start) > Calendar.current.startOfDay(for: filter.end) { Text("End date must be on or after the start date.").foregroundStyle(.red) }
                                }
                                Text("Dates use this Mac’s timezone. Next 7 days includes today.").font(.caption).foregroundStyle(.secondary)
                            }
                            Text("Connection type").font(.subheadline.bold())
                            if connections.isEmpty { Text("No connection types added yet.").foregroundStyle(.secondary) }
                            ForEach(connections) { item in selection(item.name, id: item.id, values: $filter.connections) }
                            if plans {
                                Text("Contact").font(.subheadline.bold())
                                ForEach(contacts) { item in selection(item.name, id: item.id, values: $filter.contacts) }
                            }
                            Button("Done") { showing = false }.keyboardShortcut(.defaultAction)
                        }.padding(20)
                    }.frame(width: 310, height: 420)
                }
                if count > 0 || !filter.query.isEmpty {
                    Button("Clear all") { filter = PlanSearch() }
                }
            }
            if count > 0 {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(filter.connections.sorted(), id: \.self) { value in
                            chip(connections.first { $0.id == value }?.name ?? value) { filter.connections.remove(value) }
                        }
                        ForEach(filter.contacts.sorted(), id: \.self) { value in
                            chip(contacts.first { $0.id == value }?.name ?? "Unavailable contact") { filter.contacts.remove(value) }
                        }
                        ForEach(filter.statuses.sorted(), id: \.self) { value in
                            chip(value == "draftOnly" ? "Saved draft" : "Cancelled") { filter.statuses.remove(value) }
                        }
                        if filter.dateScope != .all { chip(filter.dateScope.rawValue) { filter.dateScope = .all } }
                    }
                }
            }
        }
    }
    private func selection(_ label: String, id: String, values: Binding<Set<String>>) -> some View {
        Toggle(label, isOn: Binding(get: { values.wrappedValue.contains(id) }, set: { on in
            if on { values.wrappedValue.insert(id) } else { values.wrappedValue.remove(id) }
        }))
    }
    private func chip(_ label: String, remove: @escaping () -> Void) -> some View {
        Button(action: remove) { Label(label, systemImage: "xmark.circle.fill").font(.caption) }
            .buttonStyle(.bordered).accessibilityLabel("Remove filter: \(label)")
    }
    static func connectionChoices(_ values: [String]) -> [SearchChoice] {
        var seen = Set<String>()
        return values.compactMap { value in
            let id = PlanSearch.normalized(value)
            guard !id.isEmpty, seen.insert(id).inserted else { return nil }
            return SearchChoice(id: id, name: value.trimmingCharacters(in: .whitespacesAndNewlines))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
