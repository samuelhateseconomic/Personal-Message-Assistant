import Foundation
import AssistantCore

func check(_ condition: Bool, _ label: String) {
    guard condition else { fatalError("FAIL: \(label)") }
}
func expect(_ error: WorkspaceError, _ action: () throws -> Void) {
    do { try action(); fatalError("Expected \(error)") }
    catch let actual as WorkspaceError { check(actual == error, "Expected \(error), got \(actual)") }
    catch { fatalError("Unexpected error: \(error)") }
}

@main
struct CoreChecks {
    static func main() throws {
        var state = Workspace()
        state.editMessage("Hello")
        let original = try state.review()
        try state.approve(original)
        check(state.state == .pending, "approval")
        state.editMessage("Changed")
        check(state.state == .needsReview, "edit invalidates approval")
        expect(.staleReview) { try state.approve(original) }
        print("PASS editing invalidates approval and rejects stale preview")

        let beforeLock = try state.review()
        state.lock()
        state.editMessage("Should not change")
        check(state.message == "Changed", "locked edit rejected")
        expect(.locked) { try state.approve(beforeLock) }
        state.simulateUnlock()
        expect(.staleReview) { try state.approve(beforeLock) }
        print("PASS lock rejects approval and editing")

        let beforeContact = try state.review()
        state.select(state.contacts[1].id)
        check(state.message.isEmpty, "contact switch clears old draft")
        expect(.staleReview) { try state.approve(beforeContact) }
        print("PASS contact switch cannot carry draft")

        expect(.invalidPlan) { _ = try state.review() }
        state.editMessage("Hello")
        state.editDate(Date.distantPast)
        expect(.invalidPlan) { _ = try state.review() }
        state.editDate(Date().addingTimeInterval(3600))
        state.editMessage(String(repeating: "x", count: 2001))
        expect(.invalidPlan) { _ = try state.review() }
        state.editMessage("a\0b")
        expect(.invalidPlan) { _ = try state.review() }
        print("PASS invalid content and time cannot be approved")

        state.editMessage("Hello")
        let beforeCancel = try state.review()
        state.cancel()
        check(state.state == .cancelled, "cancelled state")
        expect(.staleReview) { try state.approve(beforeCancel) }
        print("PASS cancellation invalidates preview")
        print("5 native core checks passed")
    }
}
