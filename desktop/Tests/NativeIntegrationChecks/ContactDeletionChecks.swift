import Foundation
import NativeServices
import AssistantCore

@MainActor final class FakeDeletionBackend: ContactDeletionBackend {
    var fields = ContactFields()
    var token = Data([1])
    var present = true
    var deletes = 0
    var denyReadback = false
    var rejectDelete = false
    var afterDelete: (() throws -> Void)?
    init() { fields.givenName = "Synthetic Delete Example"; fields.phones = ["+12025550100"] }
    func accounts() throws -> [ContactAccount] { [ContactAccount(id: "test-account", name: "Test account")] }
    func deletionTarget(_ id: String) throws -> ContactDeletionTarget {
        guard present, id == "test-card" else { throw ContactSyncError.unavailable }
        return ContactDeletionTarget(snapshot: ContactSnapshot(id: id, accountID: "test-account", fields: fields), changeToken: token)
    }
    func delete(_ target: ContactDeletionTarget) throws {
        deletes += 1
        if rejectDelete { throw ContactSyncError.access }
        guard try deletionTarget(target.snapshot.id) == target else { throw ContactSyncError.changed }
        present = false; try afterDelete?()
    }
    func isAbsent(_ id: String) throws -> Bool {
        if denyReadback { throw ContactSyncError.access }
        return !present
    }
}
@MainActor final class DeletionFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let key = TestPlanKey()
    let backend = FakeDeletionBackend()
    var unlocked = true
    var profiles: ContactProfileStore { ContactProfileStore(url: directory.appendingPathComponent("profiles.json")) }
    var ledger: EncryptedPlanStore { EncryptedPlanStore(url: directory.appendingPathComponent("plans.encrypted"), keys: key) }
    var journal: ContactDeletionJournal { ContactDeletionJournal(url: directory.appendingPathComponent("deletions.encrypted"), keys: key) }
    lazy var repository = PlanRepository(store: ledger, isUnlocked: { self.unlocked })
    lazy var service = makeService()
    func makeService() -> ContactDeletionService {
        ContactDeletionService(backend: backend, profiles: profiles, journal: journal, plans: repository, isUnlocked: { self.unlocked })
    }
    init() { repository.refresh() }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}
@MainActor func runContactDeletionChecks() throws {
    func check(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
    do {
        let f = DeletionFixture(); defer { f.cleanup() }
        try f.profiles.save(ContactProfile(name: "Synthetic Delete Example", note: "Secret synthetic annotation"), for: "mac:test-card")
        try f.profiles.save(ContactProfile(name: "Unrelated"), for: "mac:other-card")
        let review = try f.service.prepare("test-card")
        check(f.backend.deletes == 0 && !FileManager.default.fileExists(atPath: f.journal.url.path), "Proposal wrote data")
        try f.service.confirm(review)
        for _ in 0..<20 {
            do { try f.service.confirm(review); fatalError("Delete replay accepted") } catch ContactDeletionError.invalidReview { }
        }
        check(f.backend.deletes == 1 && !f.backend.present, "Native delete must happen once")
        let loaded = try f.profiles.load()
        check(loaded["mac:test-card"] == nil && loaded["mac:other-card"] != nil, "Cleanup must affect exact annotations only")
        check(try f.service.pending().isEmpty, "Completed deletion should not need recovery")
        let bytes = try Data(contentsOf: f.journal.url)
        check(!String(decoding: bytes, as: UTF8.self).contains("Synthetic Delete Example"), "Receipt leaked plaintext")
        print("PASS contact delete proposal, exact cleanup, encrypted receipt and twenty replay rejections")
    }
    do {
        let f = DeletionFixture(); defer { f.cleanup() }
        let preview = try f.service.prepare("test-card")
        var composer = Workspace(requiresNativeRecipient: true)
        composer.setRecipientAccessAvailable(true)
        composer.selectRecipient(Recipient(nativeID: "test-card", name: "Example", kind: .phone, address: "+12025550100"))
        composer.editMessage("Synthetic future draft")
        let plan = try composer.review()
        _ = try f.ledger.add(plan)
        do { try f.service.confirm(preview); fatalError("New dependency ignored") } catch ContactDeletionError.dependentPlans { }
        do { _ = try f.service.prepare("test-card"); fatalError("Dependent delete prepared") } catch ContactDeletionError.dependentPlans { }
        check(f.backend.deletes == 0, "Dependency must prevent native mutation")
        _ = try f.ledger.cancel(plan.id)
        try f.service.confirm(preview)
        check(try f.ledger.load()[0].status == .cancelled, "Deletion changed plan history")
        print("PASS new saved-plan dependencies block deletion; cancelled history retained")
    }
    do {
        let f = DeletionFixture(); defer { f.cleanup() }
        let preview = try f.service.prepare("test-card")
        f.backend.token = Data([2])
        do { try f.service.confirm(preview); fatalError("Store change ignored") } catch ContactSyncError.changed { }
        let newer = try f.service.prepare("test-card")
        try f.profiles.save(ContactProfile(name: "Example", note: "Changed since review"), for: "mac:test-card")
        do { try f.service.confirm(newer); fatalError("Annotation change ignored") } catch ContactSyncError.changed { }
        check(f.backend.deletes == 0, "Changed target or notes must not be deleted")
        print("PASS native change-token and local annotation conflicts invalidate deletion")
    }
    do {
        let f = DeletionFixture(); defer { f.cleanup() }
        let preview = try f.service.prepare("test-card")
        do { try f.service.confirm(preview, now: preview.expiresAt); fatalError("Expired delete accepted") } catch ContactDeletionError.invalidReview { }
        f.unlocked = false
        do { try f.service.confirm(preview); fatalError("Locked delete accepted") } catch ContactSyncError.locked { }
        f.service.invalidate(); f.unlocked = true
        do { try f.service.confirm(preview); fatalError("Revoked delete accepted") } catch ContactDeletionError.invalidReview { }
        let other = f.makeService()
        let newReview = try f.service.prepare("test-card")
        do { try other.confirm(newReview); fatalError("Foreign review accepted") } catch ContactDeletionError.invalidReview { }
        check(f.backend.deletes == 0, "Invalid approvals caused native mutation")
        print("PASS locked, expired, revoked and foreign contact deletion reviews rejected")
    }
    do {
        let f = DeletionFixture(); defer { f.cleanup() }
        let preview = try f.service.prepare("test-card")
        f.backend.denyReadback = true
        do { try f.service.confirm(preview); fatalError("Readback failure reported success") } catch ContactDeletionError.interrupted { }
        let restarted = f.makeService()
        check(try restarted.pending().first?.state == .dispatched, "Interrupted receipt must survive restart")
        do { _ = try restarted.recover(preview.id); fatalError("Permission denial treated as absence") } catch ContactSyncError.access { }
        check(f.backend.deletes == 1, "Recovery replayed native deletion")
        f.backend.denyReadback = false
        check(try restarted.recover(preview.id) == .complete, "Absent target did not recover")
        check(try restarted.recover(preview.id) == .complete && f.backend.deletes == 1, "Recovery not idempotent")
        print("PASS interrupted delete recovers across restart without replay; denied reads are not absence")
    }
    do {
        let f = DeletionFixture(); defer { f.cleanup() }
        let profile = ContactProfile(name: "Example", note: "Preserve until cleanup")
        try f.profiles.save(profile, for: "mac:test-card")
        let original = try Data(contentsOf: f.profiles.url)
        let preview = try f.service.prepare("test-card")
        f.backend.afterDelete = { try Data("damaged JSON".utf8).write(to: f.profiles.url) }
        do { try f.service.confirm(preview); fatalError("Cleanup failure hidden") } catch ContactDeletionError.cleanup { }
        let restarted = f.makeService()
        check(try restarted.pending().first?.state == .deleted, "Verified native success receipt missing")
        try original.write(to: f.profiles.url)
        check(try restarted.recover(preview.id) == .complete && f.backend.deletes == 1, "Cleanup retry touched native store")
        print("PASS native success plus failed local cleanup recovers by cleanup only")
    }
    do {
        let f = DeletionFixture(); defer { f.cleanup() }
        let preview = try f.service.prepare("test-card")
        f.key.unavailable = true
        do { try f.service.confirm(preview); fatalError("Delete proceeded without durable receipt") } catch { }
        check(f.backend.deletes == 0, "Receipt write failure dispatched native delete")
        f.key.unavailable = false
        try Data("damaged receipt".utf8).write(to: f.journal.url)
        do { _ = try f.service.prepare("test-card"); fatalError("Unreadable journal overwritten") } catch { }
        check(try Data(contentsOf: f.journal.url) == Data("damaged receipt".utf8), "Damaged receipt replaced")
        print("PASS Keychain/journal failure blocks deletion without replacing unreadable data")
    }
    do {
        let f = DeletionFixture(); defer { f.cleanup() }
        f.backend.rejectDelete = true
        let preview = try f.service.prepare("test-card")
        do { try f.service.confirm(preview); fatalError("Rejected native deletion reported success") } catch ContactDeletionError.interrupted { }
        check(try f.makeService().recover(preview.id) == .notDeleted && f.backend.deletes == 1, "Existing card must require fresh review")
        check(f.backend.present, "Read-only recovery deleted contact")
        print("PASS rejected native delete recovery reports present and never retries automatically")
    }
}
