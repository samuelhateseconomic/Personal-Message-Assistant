import Foundation
import AssistantCore

public enum ContactWorkflowEvent: Sendable {
    case attempting(UUID, ContactProfile, ContactProfile?, String?)
    case failed(UUID, uncertain: Bool)
    case verified(UUID, ContactSnapshot)
    case annotationsSaved(UUID)
}

/// Session-only coordination, never approval or mutation authority. Native callbacks alone
/// advance completed steps. Lock discards this state; persisted contacts/plans stay saved.
public struct AssistantWorkflow: Equatable, Sendable, Identifiable {
    public enum Stage: String, Sendable {
        case contactProposal, contactReview, contactUnknown, annotationsPending, planReady, planEditing, complete
    }
    public let id: UUID
    public let contactIntent: AssistantIntent
    public let planIntent: AssistantIntent
    public private(set) var stage: Stage = .contactProposal
    public private(set) var contactProposalID: UUID?
    public private(set) var contact: ContactSnapshot?
    public private(set) var pendingProfile: ContactProfile?
    public private(set) var expectedProfile: ContactProfile?
    public private(set) var localSource: String?
    public private(set) var savedPlanID: UUID?
    public var unfinished: Bool { stage != .complete }
    public init(_ combined: AssistantIntent) throws {
        guard combined.action == .createContactThenPlan,
              ![combined.givenName, combined.familyName].compactMap({ $0 }).joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AssistantFailure.invalidResponse
        }
        id = UUID()
        var first = combined; first.action = .createContact
        first.message = nil; first.localDateTime = nil; first.timezone = nil
        contactIntent = first
        var second = AssistantIntent(action: .createPlan)
        second.message = combined.message; second.localDateTime = combined.localDateTime; second.timezone = combined.timezone
        planIntent = second
    }
    public mutating func bindContactReview(_ proposal: UUID) throws {
        guard stage == .contactProposal || stage == .contactReview else { throw AssistantFailure.workflowPending }
        contactProposalID = proposal; stage = .contactReview
    }
    public mutating func attemptingContact(_ proposal: UUID, profile: ContactProfile, expected: ContactProfile?, replacing: String?) {
        guard contactProposalID == proposal, stage == .contactReview else { return }
        pendingProfile = profile; expectedProfile = expected; localSource = replacing
        stage = .contactUnknown
    }
    public mutating func contactFailed(_ proposal: UUID, uncertain: Bool) {
        guard contactProposalID == proposal, stage == .contactUnknown else { return }
        if !uncertain { stage = .contactReview }
    }
    public mutating func verifiedContact(_ proposal: UUID, snapshot: ContactSnapshot) {
        guard contactProposalID == proposal, stage == .contactUnknown, !snapshot.id.isEmpty else { return }
        contact = snapshot; stage = .annotationsPending
    }
    /// An explicit user selection resolves an uncertain native outcome without another save.
    public mutating func useExistingAfterUncertain(_ snapshot: ContactSnapshot) throws {
        guard stage == .contactUnknown, !snapshot.id.isEmpty else { throw AssistantFailure.workflowPending }
        contact = snapshot; stage = .annotationsPending
    }
    public mutating func annotationsSaved(_ proposal: UUID) {
        guard contactProposalID == proposal, stage == .annotationsPending else { return }
        stage = .planReady; pendingProfile = nil; expectedProfile = nil; localSource = nil
    }
    public mutating func discardPendingAnnotations() {
        guard stage == .annotationsPending else { return }
        stage = .planReady; pendingProfile = nil; expectedProfile = nil; localSource = nil
    }
    public func continuation(for fresh: ContactSnapshot) throws -> AssistantIntent {
        guard stage == .planReady || stage == .planEditing,
              let contact, fresh.id == contact.id, fresh.accountID == contact.accountID else { throw AssistantFailure.workflowTarget }
        var result = planIntent; result.query = fresh.fields.name
        return result
    }
    public mutating func planOpened(for recipient: Recipient, fresh: ContactSnapshot) throws {
        guard stage == .planReady || stage == .planEditing, recipient.nativeID == contact?.id else { throw AssistantFailure.workflowTarget }
        _ = try continuation(for: fresh)
        let endpoints = recipient.kind == .phone ? fresh.fields.phones : fresh.fields.emails
        guard endpoints.contains(recipient.address) else { throw AssistantFailure.workflowTarget }
        stage = .planEditing
    }
    public mutating func releasePlan() { if stage == .planEditing { stage = .planReady } }
    public mutating func planSaved(_ id: UUID, recipient: Recipient) -> Bool {
        guard stage == .planEditing, recipient.nativeID == contact?.id else { return false }
        savedPlanID = id; stage = .complete; return true
    }
}
