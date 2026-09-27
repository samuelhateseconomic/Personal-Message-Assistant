import Foundation

/// A request, never an approval. The native coordinator validates and reviews it before execution.
public struct PlanMutation: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case create, update, cancel }
    public let operationID: UUID
    public let kind: Kind
    public let planID: UUID
    public let expectedRevision: Int?
    public let review: Review?
    public let timezone: String?
    public init(operationID: UUID = UUID(), kind: Kind, planID: UUID, expectedRevision: Int? = nil,
                review: Review? = nil, timezone: String? = nil) {
        self.operationID = operationID; self.kind = kind; self.planID = planID
        self.expectedRevision = expectedRevision; self.review = review; self.timezone = timezone
    }
}
