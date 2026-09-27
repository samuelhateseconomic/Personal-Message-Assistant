import Foundation
import Combine
import AssistantCore

public struct PreparedPlanAction: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let mutation: PlanMutation
    public let previous: StoredPlan?
    public let expiresAt: Date
    public let digest: String
}
/// Native review authority. Proposals alone do not write; no model-facing executor is exposed.
@MainActor public final class PlanActionCoordinator: ObservableObject {
    private let repository: PlanRepository
    private let unlocked: () -> Bool
    private var issued: [UUID: PreparedPlanAction] = [:]
    public init(repository: PlanRepository, isUnlocked: @escaping () -> Bool) {
        self.repository = repository; self.unlocked = isUnlocked
    }
    public func invalidate() { issued = [:] }
    public func prepare(_ mutation: PlanMutation, workspace: Workspace, now: Date = Date()) throws -> PreparedPlanAction {
        guard unlocked() else { throw PlanStorageError.locked }
        guard repository.ready else { throw PlanStorageError.unavailable }
        if let review = mutation.review {
            var candidate = workspace; try candidate.approve(review, now: now)
            guard let timezone = mutation.timezone, TimeZone(identifier: timezone) != nil else { throw PlanStorageError.invalid }
        } else if mutation.kind != .cancel { throw PlanStorageError.invalid }
        let previous: StoredPlan?
        if mutation.kind == .create { previous = nil }
        else {
            let current = try repository.current(mutation.planID)
            guard current.revision == mutation.expectedRevision, current.status == .draftOnly else { throw PlanStorageError.stale }
            previous = current
        }
        let preview = PreparedPlanAction(id: UUID(), mutation: mutation, previous: previous,
            expiresAt: now.addingTimeInterval(120), digest: try EncryptedPlanStore.digest(mutation))
        issued = issued.filter { $0.value.expiresAt > now }
        issued[preview.id] = preview
        return preview
    }
    /// Called only by the exact-review confirmation UI. Rechecks lock, expiry, composer, and stored revision.
    public func confirm(_ preview: PreparedPlanAction, workspace: inout Workspace, now: Date = Date()) throws {
        guard unlocked() else { throw PlanStorageError.locked }
        guard issued[preview.id] == preview, preview.expiresAt > now else { throw PlanStorageError.stale }
        try repository.execute(preview.mutation, workspace: &workspace, now: now)
        issued.removeValue(forKey: preview.id)
    }
}
