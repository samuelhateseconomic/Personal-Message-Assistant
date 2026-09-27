import Foundation
import CryptoKit
import NativeServices
import AssistantCore

@MainActor func runPlanActionChecks() throws {
    func check(_ value: Bool, _ label: String) { if !value { fatalError(label) } }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("plans.encrypted")
    let key = TestPlanKey()
    let store = EncryptedPlanStore(url: url, keys: key)
    var unlocked = true
    let repository = PlanRepository(store: store, isUnlocked: { unlocked })
    let actions = PlanActionCoordinator(repository: repository, isUnlocked: { unlocked })
    repository.refresh()
    var composer = Workspace(requiresNativeRecipient: true)
    composer.setRecipientAccessAvailable(true)
    composer.selectRecipient(Recipient(nativeID: "test-card", name: "Example", kind: .phone, address: "+12025550100"))
    composer.editMessage("Initial plan")
    let initial = try composer.review()
    let create = PlanMutation(operationID: initial.id, kind: .create, planID: initial.id, review: initial, timezone: "America/Los_Angeles")
    let prepared = try actions.prepare(create, workspace: composer)
    check(repository.plans.isEmpty && !FileManager.default.fileExists(atPath: url.path), "Preparing must not persist or mutate")
    try actions.confirm(prepared, workspace: &composer)
    check(repository.plans.count == 1 && repository.plans[0].revision == 1, "Native confirmation creates revision one")
    do { try actions.confirm(prepared, workspace: &composer); fatalError("Consumed preview replayed") } catch PlanStorageError.stale { }
    for _ in 0..<20 { _ = try store.apply(create) }
    check(try store.load().count == 1, "Repeated operation must have one effect")
    print("PASS proposal is non-mutating and repeated create has one durable effect")

    let original = try repository.current(initial.id)
    composer.loadForEditing(original.snapshot); composer.editMessage("Updated plan")
    let edited = try composer.review()
    let update = PlanMutation(operationID: edited.id, kind: .update, planID: original.id,
                              expectedRevision: original.revision, review: edited, timezone: "America/New_York")
    let editPreview = try actions.prepare(update, workspace: composer)
    check(try store.load()[0].snapshot.message == "Initial plan", "Edit proposal must not change existing plan")
    try actions.confirm(editPreview, workspace: &composer)
    let changed = try repository.current(original.id)
    check(changed.id == original.id && changed.revision == 2 && changed.snapshot.message == "Updated plan", "Update preserves stable ID and changes revision")
    check(changed.createdAt == original.createdAt && changed.timezone == "America/New_York", "Update preserves creation time and reviewed timezone")
    check(try store.load().count == 1, "Update cannot append duplicate plan")
    _ = try store.apply(update)
    check(try store.load()[0].revision == 2, "Update replay cannot increment revision twice")
    print("PASS reviewed update preserves identity, timezone, creation time and idempotency")

    composer.loadForEditing(changed.snapshot); composer.editMessage("Competing edit")
    let competing = try composer.review()
    let change = PlanMutation(operationID: competing.id, kind: .update, planID: changed.id,
                              expectedRevision: changed.revision, review: competing, timezone: "America/New_York")
    let stalePreview = try actions.prepare(change, workspace: composer)
    let cancellation = PlanMutation(kind: .cancel, planID: changed.id, expectedRevision: changed.revision)
    _ = try store.apply(cancellation)
    do { try actions.confirm(stalePreview, workspace: &composer); fatalError("Stale update replaced cancellation") } catch PlanStorageError.stale { }
    check(composer.message == "Competing edit", "Failed update retains composer")
    check(try store.load()[0].status == .cancelled && store.load()[0].revision == 3, "Cancel wins and old edit cannot reactivate")
    _ = try store.apply(cancellation)
    check(try store.load()[0].revision == 3, "Cancel retry is idempotent")
    print("PASS edit/cancel race rejects stale review and retains input")

    composer.newPlan(); composer.selectRecipient(initial.recipient); composer.editMessage("Another proposal")
    let later = try composer.review()
    let request = PlanMutation(kind: .create, planID: later.id, review: later, timezone: "UTC")
    let expiring = try actions.prepare(request, workspace: composer)
    do { try actions.confirm(expiring, workspace: &composer, now: expiring.expiresAt); fatalError("Expired review accepted") } catch PlanStorageError.stale { }
    let revoked = try actions.prepare(request, workspace: composer)
    unlocked = false
    do { try actions.confirm(revoked, workspace: &composer); fatalError("Locked review accepted") } catch PlanStorageError.locked { }
    actions.invalidate(); unlocked = true
    do { try actions.confirm(revoked, workspace: &composer); fatalError("Revoked review accepted after unlock") } catch PlanStorageError.stale { }
    check(composer.message == later.message, "Rejected review must retain draft")
    print("PASS expiry and lock revoke previews without mutation")
    let beforeCollision = try Data(contentsOf: url)
    let collision = PlanMutation(operationID: create.operationID, kind: .create, planID: create.planID,
                                 review: later, timezone: "UTC")
    do { _ = try store.apply(collision); fatalError("Reused operation ID accepted different payload") } catch PlanStorageError.invalid { }
    check(try Data(contentsOf: url) == beforeCollision, "Operation collision must not alter file")
    let wrongZone = PlanMutation(kind: .create, planID: later.id, review: later, timezone: "Not/AZone")
    do { _ = try actions.prepare(wrongZone, workspace: composer); fatalError("Invalid timezone was reviewed") } catch PlanStorageError.invalid { }
    print("PASS operation payload collision and invalid timezone rejection")

    // Produce a genuine legacy payload, omitting v2 fields rather than using the new encoder.
    struct LegacyPlan: Codable { let snapshot: Review; let createdAt: Date; let status: String }
    struct LegacyLedger: Codable { let version: Int; let plans: [LegacyPlan] }
    struct Envelope: Codable { let version: Int; let sealed: Data }
    let legacy = LegacyLedger(version: 1, plans: [LegacyPlan(snapshot: initial, createdAt: Date(), status: "draftOnly")])
    let sealed = try AES.GCM.seal(JSONEncoder().encode(legacy), using: key.value,
                                  authenticating: Data("MessageAssistant.plan-ledger.v1".utf8)).combined!
    let oldBytes = try JSONEncoder().encode(Envelope(version: 1, sealed: sealed))
    let legacyURL = directory.appendingPathComponent("legacy.encrypted")
    try oldBytes.write(to: legacyURL)
    let legacyStore = EncryptedPlanStore(url: legacyURL, keys: key)
    let migrated = try legacyStore.load()[0]
    check(migrated.id == initial.id && migrated.revision == 1 && migrated.timezone == nil, "Legacy defaults preserve identity without inventing timezone")
    check(try Data(contentsOf: legacyURL) == oldBytes, "Read must not migrate on disk")
    let migrationAction = PlanMutation(kind: .update, planID: migrated.id, expectedRevision: 1,
                                     review: edited, timezone: "UTC")
    _ = try legacyStore.apply(migrationAction)
    let backup = legacyURL.appendingPathExtension("schema1-backup")
    check(try Data(contentsOf: backup) == oldBytes, "Migration backup must preserve original ciphertext")
    let reopen = EncryptedPlanStore(url: legacyURL, keys: key)
    check(try reopen.load()[0].revision == 2 && reopen.load()[0].id == initial.id, "Migrated record survives reopen")
    _ = try reopen.apply(migrationAction)
    check(try Data(contentsOf: backup) == oldBytes && reopen.load().count == 1, "Repeated migration cannot overwrite backup or duplicate record")
    let restoration = directory.appendingPathComponent("restored-legacy.encrypted")
    try oldBytes.write(to: restoration)
    check(try EncryptedPlanStore(url: restoration, keys: key).load()[0].snapshot == initial, "Legacy backup restores original content")
    print("PASS version-one migration, immutable backup, reopen and restore")
    let blockedURL = directory.appendingPathComponent("blocked-migration.encrypted")
    try oldBytes.write(to: blockedURL)
    try Data("existing backup must not be overwritten".utf8).write(to: blockedURL.appendingPathExtension("schema1-backup"))
    let blockedStore = EncryptedPlanStore(url: blockedURL, keys: key)
    do { _ = try blockedStore.apply(migrationAction); fatalError("Conflicting backup overwritten") } catch PlanStorageError.unavailable { }
    check(try Data(contentsOf: blockedURL) == oldBytes, "Failed migration must preserve original store")
    print("PASS failed migration preserves original and preexisting backup")
}
