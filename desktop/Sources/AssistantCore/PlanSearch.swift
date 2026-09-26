import Foundation

public struct SearchRecord: Sendable {
    public var fields: [String]
    public var connection: String
    public var contactID: String
    public var status: String
    public var date: Date?
    public init(fields: [String], connection: String = "", contactID: String, status: String = "", date: Date? = nil) {
        self.fields = fields; self.connection = connection; self.contactID = contactID; self.status = status; self.date = date
    }
}
public struct PlanSearch: Sendable {
    public enum DateScope: String, CaseIterable, Sendable { case all = "Any date", today = "Today", nextWeek = "Next 7 days", custom = "Custom range" }
    public var query = ""
    public var connections = Set<String>()
    public var contacts = Set<String>()
    public var statuses = Set<String>()
    public var dateScope: DateScope = .all
    public var start = Date()
    public var end = Date()
    public init() {}
    public static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    public static func matchesKeywords(_ query: String, fields: [String]) -> Bool {
        let terms = normalized(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let searchable = fields.map(normalized)
        return terms.allSatisfy { term in
            let digits = term.filter(\.isNumber)
            let phoneLike = digits.count >= 3 && term.allSatisfy { $0.isNumber || "+-().".contains($0) }
            return searchable.contains { $0.contains(term) || (phoneLike && $0.filter(\.isNumber).contains(digits)) }
        }
    }
    public func matches(_ record: SearchRecord, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard Self.matchesKeywords(query, fields: record.fields),
              connections.isEmpty || connections.contains(Self.normalized(record.connection)),
              contacts.isEmpty || contacts.contains(record.contactID),
              statuses.isEmpty || statuses.contains(record.status) else { return false }
        guard dateScope != .all else { return true }
        guard let date = record.date else { return false }
        let lower: Date
        let upper: Date?
        switch dateScope {
        case .all: return true
        case .today:
            lower = calendar.startOfDay(for: now); upper = calendar.date(byAdding: .day, value: 1, to: lower)
        case .nextWeek:
            lower = calendar.startOfDay(for: now); upper = calendar.date(byAdding: .day, value: 7, to: lower)
        case .custom:
            lower = calendar.startOfDay(for: start)
            guard lower <= calendar.startOfDay(for: end) else { return false }
            upper = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end))
        }
        guard let upper else { return false }
        return date >= lower && date < upper
    }
}
