import Foundation
import Combine

public extension Notification.Name {
    static let contactProfilesChanged = Notification.Name("MessageAssistant.contactProfilesChanged")
}
@MainActor public final class ProfileSearchIndex: ObservableObject {
    @Published public private(set) var profiles: [String: ContactProfile] = [:]
    @Published public private(set) var errorMessage = ""
    public init() {}
    public func refresh() {
        do { profiles = try ContactProfileStore().load(); errorMessage = "" }
        catch { profiles = [:]; errorMessage = "Connection types and private notes could not be loaded. Search is limited to available contact and plan details." }
    }
    public func clear() { profiles = [:]; errorMessage = "" }
}
