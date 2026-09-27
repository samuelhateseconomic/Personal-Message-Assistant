import Foundation
import NativeServices

@MainActor final class ReceiptFailureBackend: ContactSyncBackend {
    let fake = FakeContactBackend()
    var afterWrite: () -> Void = {}
    func accounts() throws -> [ContactAccount] { try fake.accounts() }
    func fetch(_ id: String) throws -> ContactSnapshot { try fake.fetch(id) }
    func create(_ fields: ContactFields, accountID: String) throws -> ContactSnapshot {
        let saved = try fake.create(fields, accountID: accountID); afterWrite(); return saved
    }
    func update(_ snapshot: ContactSnapshot, fields: ContactFields) throws -> ContactSnapshot {
        let saved = try fake.update(snapshot, fields: fields); afterWrite(); return saved
    }
}

@MainActor func runContactSaveRecoveryChecks() throws {
    func check(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let keys = TestPlanKey(); let backend = FakeContactBackend(); let gate = PreferenceGate()
    let profileStore = ContactProfileStore(url: directory.appendingPathComponent("profiles.json"))
    let journal = ContactSaveJournal(url: directory.appendingPathComponent("saves.encrypted"), keys: keys)
    let service = ContactSyncService(backend: backend, isUnlocked: { gate.unlocked })
    func coordinator(_ contacts: ContactSyncService? = nil) -> ContactSaveCoordinator {
        ContactSaveCoordinator(contacts: contacts ?? service, profiles: profileStore, journal: journal, isUnlocked: { gate.unlocked })
    }
    func commit(_ coordinator: ContactSaveCoordinator, _ review: ContactSaveReview, expected: ContactProfile? = nil) throws -> ContactSaveReceipt {
        try coordinator.commit(review, profile: ContactProfile(name: review.fields.name, connection: "colleague", note: "Synthetic pending note"), expectedProfile: expected, localSource: nil, expectedSource: nil, proposalID: nil)
    }
    let first = coordinator()
    let review = try service.review(base: nil, edited: backend.fields, accountID: "test-account")
    let receipt = try commit(first, review)
    check(try backend.writes == 1 && receipt.state == .verified && (try profileStore.load()).isEmpty, "Native write must persist verified receipt before local notes")
    let cipher = try Data(contentsOf: journal.url)
    check(!String(decoding: cipher, as: UTF8.self).contains("Synthetic pending note"), "Pending notes must be encrypted")
    check((try FileManager.default.attributesOfItem(atPath: journal.url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Receipt must be owner-only")
    let restartedService = ContactSyncService(backend: backend, isUnlocked: { gate.unlocked })
    let restarted = coordinator(restartedService)
    check(try restarted.pending().map(\.id) == [review.id], "Recovery must survive restart")
    do { _ = try commit(restarted, review); fatalError("Receipt replay dispatched another write") } catch ContactSaveRecoveryError.uncertain {}
    let another = try restartedService.review(base: nil, edited: backend.fields, accountID: "test-account")
    do { _ = try commit(restarted, another); fatalError("Pending receipt did not block new save") } catch ContactSaveRecoveryError.pending {}
    _ = try restarted.finishNotes(receipt.id)
    check(try backend.writes == 1 && (try profileStore.load())["mac:new-test-contact"]?.note == "Synthetic pending note", "Recovery must save only local notes")
    check(try restarted.pending().isEmpty, "Finished recovery must leave no pending receipt")
    print("PASS encrypted save receipt survives restart, blocks replay/new saves and finishes only notes")

    backend.failFetchAfterWrite = true
    let failedReview = try restartedService.review(base: nil, edited: backend.fields, accountID: "test-account")
    do { _ = try commit(restarted, failedReview); fatalError("Unconfirmed create reported success") } catch ContactSaveRecoveryError.uncertain {}
    let writes = backend.writes
    let uncertain = coordinator(ContactSyncService(backend: backend, isUnlocked: { gate.unlocked }))
    do { _ = try uncertain.check(failedReview.id); fatalError("Unknown create guessed an ID") } catch ContactSaveRecoveryError.uncertain {}
    do { _ = try uncertain.check(failedReview.id, selectedID: "new-test-contact"); fatalError("Unavailable read treated as proof") } catch ContactSyncError.unavailable {}
    backend.failFetchAfterWrite = false
    backend.fields.givenName = "External rename"
    do { _ = try uncertain.check(failedReview.id, selectedID: "new-test-contact"); fatalError("Changed fields accepted") } catch ContactSaveRecoveryError.changed {}
    backend.fields = failedReview.fields
    let checked = try uncertain.check(failedReview.id, selectedID: "new-test-contact")
    check(checked.state == .verified && backend.writes == writes, "Explicit selection must verify by readback without another create")
    // This synthetic card already has identical notes from the prior operation: cleanup is idempotent.
    _ = try uncertain.finishNotes(failedReview.id)
    check(backend.writes == writes, "Uncertain recovery repeated native write")
    print("PASS uncertain create needs explicit verified card and never repeats native creation")

    let updateService = ContactSyncService(backend: backend, isUnlocked: { gate.unlocked })
    let updateCoordinator = coordinator(updateService)
    let base = try updateService.fetch("new-test-contact")
    var edited = base.fields; edited.familyName = "Updated"
    let updateReview = try updateService.review(base: base, edited: edited, accountID: "test-account")
    let prior = try profileStore.load()["mac:new-test-contact"]
    let update = try commit(updateCoordinator, updateReview, expected: prior)
    do { _ = try updateCoordinator.check(update.id, selectedID: "same-name-other-card"); fatalError("Update rebound to other ID") } catch ContactSaveRecoveryError.changed {}
    let newer = ContactProfile(name: "Example", note: "Newer annotations to preserve")
    try profileStore.save(newer, for: "mac:new-test-contact")
    do { _ = try updateCoordinator.finishNotes(update.id); fatalError("Newer local notes overwritten") } catch ContactSaveRecoveryError.changed {}
    check(try profileStore.load()["mac:new-test-contact"] == newer, "Recovery must preserve conflicting notes")
    let beforeDismiss = backend.writes
    try updateCoordinator.dismiss(update.id)
    check(try updateCoordinator.pending().isEmpty && backend.writes == beforeDismiss, "Explicit dismissal must change only receipt state")
    print("PASS update recovery binds original ID and preserves newer notes; dismissal never writes Contacts")

    let pendingReview = try updateService.review(base: nil, edited: backend.fields, accountID: "test-account")
    let pending = try commit(updateCoordinator, pendingReview)
    let count = backend.writes
    try Data("bad profile data".utf8).write(to: profileStore.url)
    do { _ = try updateCoordinator.finishNotes(pending.id); fatalError("Corrupt notes replaced") } catch ContactSaveRecoveryError.storage {}
    check(try String(contentsOf: profileStore.url, encoding: .utf8) == "bad profile data", "Corrupt notes must remain intact")
    // Repair only this isolated synthetic fixture, then retry cleanup.
    try Data("{}".utf8).write(to: profileStore.url)
    _ = try updateCoordinator.finishNotes(pending.id)
    check(backend.writes == count, "Local storage retry repeated native write")
    print("PASS local storage failure retains receipt and retries annotations only")

    let lockedReview = try updateService.review(base: nil, edited: backend.fields, accountID: "test-account")
    gate.unlocked = false
    do { _ = try updateCoordinator.pending(); fatalError("Locked recovery read accepted") } catch ContactSyncError.locked {}
    do { _ = try commit(updateCoordinator, lockedReview); fatalError("Locked save accepted") } catch ContactSyncError.locked {}
    gate.unlocked = true; keys.unavailable = true
    let original = try Data(contentsOf: journal.url)
    do { _ = try commit(updateCoordinator, lockedReview); fatalError("Missing receipt key permitted native write") } catch ContactSaveRecoveryError.storage {}
    check(try backend.writes == count && (try Data(contentsOf: journal.url)) == original, "Key failure must preserve receipt and stop native write")
    keys.unavailable = false
    try Data("bad receipt".utf8).write(to: journal.url)
    do { _ = try commit(updateCoordinator, lockedReview); fatalError("Corrupt receipt replaced") } catch ContactSaveRecoveryError.storage {}
    check(backend.writes == count, "Corrupt receipt allowed native write")
    try original.write(to: journal.url)
    print("PASS lock, receipt key loss and corruption block saves before native dispatch")

    let staleBase = try updateService.fetch("new-test-contact")
    let staleReview = try updateService.review(base: staleBase, edited: staleBase.fields, accountID: "test-account")
    do { _ = try commit(updateCoordinator, staleReview, expected: nil); fatalError("Stale annotation baseline permitted save") } catch ContactSaveRecoveryError.changed {}
    let current = try profileStore.load()["mac:new-test-contact"]
    backend.fields.givenName = "Changed before dispatch"
    do { _ = try commit(updateCoordinator, staleReview, expected: current); fatalError("Stale native source permitted save") } catch ContactSyncError.changed {}
    check(try updateCoordinator.pending().isEmpty && backend.writes == count, "Known pre-write failure must not leave uncertain recovery")
    print("PASS stale annotation baseline and native preflight reject without writes or unresolved receipts")

    let linkedDirectory = directory.appendingPathComponent("linked")
    let linkedProfiles = ContactProfileStore(url: linkedDirectory.appendingPathComponent("profiles.json"))
    let source = ContactProfile(name: "Example", connection: "colleague", note: "Original local note")
    try linkedProfiles.save(source, for: "local:source")
    let linkedBackend = FakeContactBackend()
    let linkedService = ContactSyncService(backend: linkedBackend, isUnlocked: { true })
    let linkedCoordinator = ContactSaveCoordinator(contacts: linkedService, profiles: linkedProfiles,
        journal: ContactSaveJournal(url: linkedDirectory.appendingPathComponent("receipts.encrypted"), keys: TestPlanKey()), isUnlocked: { true })
    let linkedReview = try linkedService.review(base: nil, edited: linkedBackend.fields, accountID: "test-account")
    let linked = try linkedCoordinator.commit(linkedReview, profile: source, expectedProfile: nil, localSource: "local:source", expectedSource: source, proposalID: nil)
    let changedSource = ContactProfile(name: "Example", note: "New local edit")
    try linkedProfiles.save(changedSource, for: "local:source")
    do { _ = try linkedCoordinator.finishNotes(linked.id); fatalError("Changed app-only source removed") } catch ContactSaveRecoveryError.changed {}
    check(try linkedProfiles.load()["local:source"] == changedSource, "Pending link must preserve a newer source profile")
    try linkedProfiles.save(source, for: "local:source")
    _ = try linkedCoordinator.finishNotes(linked.id)
    let linkedValues = try linkedProfiles.load()
    check(linkedValues["local:source"] == nil && linkedValues["mac:new-test-contact"] == source && linkedBackend.writes == 1, "Recovery must link the unchanged source exactly once")
    print("PASS app-only linking recovery preserves newer source notes and removes only the reviewed source")

    let faultDirectory = directory.appendingPathComponent("fault")
    let faultKeys = TestPlanKey(); let faultBackend = ReceiptFailureBackend()
    let faultService = ContactSyncService(backend: faultBackend, isUnlocked: { true })
    let faultJournal = ContactSaveJournal(url: faultDirectory.appendingPathComponent("receipts.encrypted"), keys: faultKeys)
    let faultProfiles = ContactProfileStore(url: faultDirectory.appendingPathComponent("profiles.json"))
    let faultCoordinator = ContactSaveCoordinator(contacts: faultService, profiles: faultProfiles, journal: faultJournal, isUnlocked: { true })
    let faultReview = try faultService.review(base: nil, edited: faultBackend.fake.fields, accountID: "test-account")
    faultBackend.afterWrite = { faultKeys.unavailable = true }
    do { _ = try commit(faultCoordinator, faultReview); fatalError("Post-native receipt failure falsely succeeded") } catch ContactSaveRecoveryError.storage {}
    faultKeys.unavailable = false
    let recoveredCoordinator = ContactSaveCoordinator(contacts: ContactSyncService(backend: faultBackend, isUnlocked: { true }), profiles: faultProfiles, journal: faultJournal, isUnlocked: { true })
    check(try recoveredCoordinator.pending().first?.state == .dispatched, "Write-ahead marker must survive loss of the verified receipt")
    _ = try recoveredCoordinator.check(faultReview.id, selectedID: "new-test-contact")
    _ = try recoveredCoordinator.finishNotes(faultReview.id)
    check(faultBackend.fake.writes == 1, "Receipt failure recovery must not repeat an already successful native write")
    print("PASS receipt failure after native success recovers from write-ahead marker without replay")
}
