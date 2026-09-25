import Foundation

public struct DemoContact: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var email: String
    public var language: String
    public init(name: String, email: String, language: String = "English") {
        self.id = UUID()
        self.name = name
        self.email = email
        self.language = language
    }
}

public enum PlanState: String, Sendable {
    case needsReview = "Needs review"
    case pending = "Pending · demo"
    case cancelled = "Cancelled"
}

public struct Review: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let revision: Int
    public let contact: DemoContact
    public let message: String
    public let date: Date
}

public enum WorkspaceError: Error, Equatable {
    case locked, invalidPlan, staleReview
}

/// In-memory prototype state only. No OS permissions, persistence, inference or delivery.
public struct Workspace: Sendable {
    public private(set) var contacts = [
        DemoContact(name: "Alex Morgan", email: "alex@example.test"),
        DemoContact(name: "Jamie Chen", email: "jamie@example.test")
    ]
    public private(set) var selectedID: UUID
    public private(set) var message = ""
    public private(set) var date = Date().addingTimeInterval(3600)
    public private(set) var revision = 0
    public private(set) var state: PlanState = .needsReview
    public private(set) var isLocked = false
    public private(set) var deliveryPaused = true

    public init() { selectedID = contacts[0].id }
    public var selected: DemoContact { contacts.first { $0.id == selectedID }! }

    private mutating func invalidate() { revision += 1; state = .needsReview }
    public mutating func select(_ id: UUID) {
        guard !isLocked, id != selectedID, contacts.contains(where: { $0.id == id }) else { return }
        selectedID = id
        message = ""
        invalidate()
    }
    public mutating func editMessage(_ value: String) {
        guard !isLocked, value != message else { return }
        message = value
        invalidate()
    }
    public mutating func editDate(_ value: Date) {
        guard !isLocked, value != date else { return }
        date = value
        invalidate()
    }
    public mutating func newPlan() {
        guard !isLocked else { return }
        message = ""
        date = Date().addingTimeInterval(3600)
        invalidate()
    }
    public func review(now: Date = Date()) throws -> Review {
        guard !isLocked else { throw WorkspaceError.locked }
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              message.count <= 2000, !message.contains("\0"), date > now else {
            throw WorkspaceError.invalidPlan
        }
        return Review(id: UUID(), revision: revision, contact: selected, message: message, date: date)
    }
    public mutating func approve(_ review: Review, now: Date = Date()) throws {
        guard !isLocked else { throw WorkspaceError.locked }
        guard review.revision == revision, review.contact == selected,
              review.message == message, review.date == date,
              state == .needsReview else { throw WorkspaceError.staleReview }
        _ = try self.review(now: now)
        state = .pending
    }
    public mutating func cancel() {
        guard !isLocked else { return }
        revision += 1
        state = .cancelled
    }
    public mutating func setDeliveryPaused(_ value: Bool) {
        guard !isLocked else { return }
        deliveryPaused = value
    }
    public mutating func lock() { isLocked = true; deliveryPaused = true; revision += 1 }
    public mutating func simulateUnlock() { isLocked = false }
    public mutating func saveContact(name: String, email: String, language: String) {
        guard !isLocked, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let index = contacts.firstIndex(where: { $0.id == selectedID }) else { return }
        contacts[index].name = name
        contacts[index].email = email
        contacts[index].language = language
        invalidate()
    }
}
