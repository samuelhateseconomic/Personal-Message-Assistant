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
        var native = Workspace(requiresNativeRecipient: true)
        native.editMessage("Draft")
        expect(.invalidPlan) { _ = try native.review() }
        native.setRecipientAccessAvailable(true)
        expect(.invalidPlan) { _ = try native.review() }
        let recipient = Recipient(nativeID: "synthetic-native-id", name: "Example Person", kind: .phone, address: "+12025550100")
        native.selectRecipient(recipient)
        native.editMessage("Hello selected contact")
        let exact = try native.review()
        check(exact.recipient == recipient, "Review captures exact native ID and endpoint")
        try native.approve(exact)
        native.reconcileRecipients([recipient])
        check(native.state == .pending && native.message == exact.message, "Unchanged recipient must preserve draft and approval")
        print("PASS native selection required and exact endpoint captured")

        let email = Recipient(nativeID: recipient.nativeID, name: recipient.name, kind: .email, address: "example@example.test")
        native.selectRecipient(email)
        check(native.message.isEmpty && native.state == .needsReview, "Changing endpoint clears previous draft and approval")
        expect(.staleReview) { try native.approve(exact) }
        native.editMessage("Another draft")
        native.reconcileRecipients([recipient])
        check(native.selectedRecipient == nil && native.message.isEmpty, "Removed endpoint clears recipient without substituting another number")
        expect(.invalidPlan) { _ = try native.review() }
        print("PASS endpoint change and removal never silently redirect a draft")

        native.selectRecipient(recipient); native.editMessage("Keep this draft")
        let oldName = try native.review()
        var renamed = recipient; renamed.name = "Updated Example"
        native.reconcileRecipients([renamed])
        check(native.message == "Keep this draft" && native.selectedRecipient == renamed, "Rename preserves text but refreshes recipient")
        expect(.staleReview) { try native.approve(oldName) }
        let connectedReview = try native.review()
        native.setRecipientAccessAvailable(false)
        expect(.invalidPlan) { _ = try native.review() }
        expect(.staleReview) { try native.approve(connectedReview) }
        native.setRecipientAccessAvailable(true)
        expect(.staleReview) { try native.approve(connectedReview) }
        native.reconcileRecipients([])
        check(native.selectedRecipient == nil && native.message.isEmpty, "Missing contact clears selection and draft")
        print("PASS rename, permission loss and deletion invalidate stale reviews")

        native.selectRecipient(recipient); native.editMessage("Private draft")
        let privateReview = try native.review()
        native.lock()
        check(native.selectedRecipient == nil && native.message.isEmpty && !native.recipientAccessAvailable, "Lock clears native recipient and draft")
        native.setRecipientAccessAvailable(true)
        check(!native.recipientAccessAvailable, "Cannot reconnect workspace while locked")
        native.simulateUnlock()
        expect(.staleReview) { try native.approve(privateReview) }
        print("PASS lock clears native recipient data and prevents stale approval")
        var planner = Workspace(requiresNativeRecipient: true)
        planner.setRecipientAccessAvailable(true); planner.selectRecipient(recipient)
        planner.editMessage("Reviewed plan")
        let addTime = Date()
        let confirmed = try planner.review(now: addTime)
        try planner.addPlan(confirmed, now: addTime)
        check(planner.addedPlans == [confirmed], "Confirmed snapshot must be retained exactly")
        check(planner.message.isEmpty && planner.selectedRecipient == nil && planner.state == .needsReview, "Successful add resets composer")
        check(planner.date == addTime.addingTimeInterval(3600), "Successful add resets scheduled time")
        expect(.staleReview) { try planner.addPlan(confirmed, now: addTime) }
        check(planner.addedPlans.count == 1, "Double confirmation cannot duplicate a plan")
        print("PASS successful plan add preserves snapshot, resets form and rejects replay")

        planner.selectRecipient(recipient); planner.editMessage("Keep the newer edit")
        let stale = try planner.review()
        planner.editMessage("Updated text")
        let retainedTime = planner.date
        expect(.staleReview) { try planner.addPlan(stale) }
        check(planner.message == "Updated text" && planner.selectedRecipient == recipient && planner.date == retainedTime,
              "Failed confirmation must preserve current inputs")
        check(planner.addedPlans.count == 1, "Failed confirmation must not add a plan")
        let expires = try planner.review()
        expect(.invalidPlan) { try planner.addPlan(expires, now: expires.date.addingTimeInterval(1)) }
        check(planner.message == "Updated text", "Expired confirmation must preserve draft")
        print("PASS failed and expired confirmation retain draft without adding a plan")
        print("11 native core checks passed")
    }
}
