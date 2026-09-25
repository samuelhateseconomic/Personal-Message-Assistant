import Foundation
import NativeServices

@MainActor final class FakeContactBackend: ContactSyncBackend {
    var fields = ContactFields()
    var writes = 0
    var failFetchAfterWrite = false
    init() { fields.givenName = "Example"; fields.phones = ["+12025550100"] }
    func accounts() throws -> [ContactAccount] { [ContactAccount(id: "test-account", name: "Synthetic account")] }
    func fetch(_ id: String) throws -> ContactSnapshot {
        if failFetchAfterWrite && writes > 0 { throw ContactSyncError.unavailable }
        return ContactSnapshot(id: id, accountID: "test-account", fields: fields)
    }
    func create(_ value: ContactFields, accountID: String) throws -> ContactSnapshot {
        writes += 1; fields = value
        return ContactSnapshot(id: "new-test-contact", accountID: accountID, fields: fields)
    }
    func update(_ snapshot: ContactSnapshot, fields value: ContactFields) throws -> ContactSnapshot {
        writes += 1; fields = value
        return ContactSnapshot(id: snapshot.id, accountID: snapshot.accountID, fields: fields)
    }
}
@MainActor func runContactSyncChecks() throws {
    func check(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
    let backend = FakeContactBackend()
    var unlocked = true
    let service = ContactSyncService(backend: backend, isUnlocked: { unlocked })
    let base = try service.fetch("test-contact")
    var edited = base.fields; edited.givenName = "Edited Example"
    backend.fields.emails = ["example@example.test"]
    let review = try service.review(base: base, edited: edited, accountID: "test-account")
    check(review.fields.givenName == edited.givenName && review.fields.emails == backend.fields.emails, "Disjoint edits must merge")
    backend.fields.givenName = "External edit"
    do { _ = try service.commit(review); fatalError("Stale review was accepted") }
    catch ContactSyncError.changed { }
    check(backend.writes == 0, "Stale review must not write")
    do { _ = try service.review(base: base, edited: edited, accountID: "test-account"); fatalError("Conflict was overwritten") }
    catch ContactSyncError.conflict(let fields) { check(fields == ["First name"], "Conflict field must be named") }
    print("PASS disjoint merge, named conflict and stale-review rejection")

    let fresh = try service.fetch("test-contact")
    let accepted = try service.review(base: fresh, edited: edited, accountID: "test-account")
    unlocked = false
    do { _ = try service.commit(accepted); fatalError("Locked save was accepted") }
    catch ContactSyncError.locked { }
    unlocked = true
    _ = try service.commit(accepted)
    check(backend.writes == 1, "Reviewed update must save once")
    do { _ = try service.commit(accepted); fatalError("Review was replayed") }
    catch ContactSyncError.uncertain { }
    check(backend.writes == 1, "Duplicate save must not execute")
    print("PASS locked save rejection, verified update and replay prevention")

    let create = try service.review(base: nil, edited: edited, accountID: "test-account")
    let result = try service.commit(create)
    check(result.id == "new-test-contact", "Create must return its native identity")
    do { _ = try service.review(base: nil, edited: edited, accountID: ""); fatalError("Missing account was accepted") }
    catch ContactSyncError.account { }
    print("PASS explicit-account creation and returned identity")

    let uncertainBackend = FakeContactBackend(); uncertainBackend.failFetchAfterWrite = true
    let uncertainService = ContactSyncService(backend: uncertainBackend, isUnlocked: { true })
    let pending = try uncertainService.review(base: nil, edited: edited, accountID: "test-account")
    do { _ = try uncertainService.commit(pending); fatalError("Unverified write reported success") } catch { }
    do { _ = try uncertainService.commit(pending); fatalError("Uncertain create replayed") }
    catch ContactSyncError.uncertain { }
    check(uncertainBackend.writes == 1, "Uncertain creation must not duplicate")
    print("PASS uncertain creation is not repeated")

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ContactProfileStore(url: directory.appendingPathComponent("profiles.json"))
    let profile = ContactProfile(name: "Example", connection: "Friend", note: "Synthetic note")
    let local = try store.create(profile)
    try store.saveLinked(profile, nativeID: "native-test", replacing: local)
    let linked = try store.load()
    check(linked[local] == nil && linked["mac:native-test"] == profile, "Moving to native must retain private annotations and remove duplicate local profile")
    print("PASS app-only profile links to native identity without losing annotations")
}
