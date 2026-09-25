import Foundation
import CryptoKit
import NativeServices
import AssistantCore

@MainActor final class TestPlanKey: PlanKeyProvider {
    let value = SymmetricKey(size: .bits256)
    var unavailable = false
    var createRequests = 0
    func key(createIfMissing: Bool) throws -> SymmetricKey {
        if createIfMissing { createRequests += 1 }
        if unavailable { throw PlanStorageError.unavailable }
        return value
    }
}
@MainActor func runPlanStorageChecks() throws {
    func check(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("plans.encrypted")
    let key = TestPlanKey()
    let store = EncryptedPlanStore(url: url, keys: key)
    var unlocked = true
    let repo = PlanRepository(store: store, isUnlocked: { unlocked })
    repo.refresh()
    check(repo.ready && repo.plans.isEmpty && key.createRequests == 0, "Empty read must not create a key")
    var workspace = Workspace(requiresNativeRecipient: true)
    workspace.setRecipientAccessAvailable(true)
    workspace.selectRecipient(Recipient(nativeID: "synthetic-recipient", name: "Example", kind: .phone, address: "+12025550100"))
    workspace.editMessage("Synthetic secret draft for storage check")
    let review = try workspace.review()
    try repo.confirm(review, workspace: &workspace)
    check(workspace.message.isEmpty && repo.plans.count == 1, "Save must persist and reset composer")
    let bytes = try Data(contentsOf: url)
    check(!String(decoding: bytes, as: UTF8.self).contains(review.message), "Plaintext message must not appear on disk")
    let reopened = PlanRepository(store: EncryptedPlanStore(url: url, keys: key), isUnlocked: { true })
    reopened.refresh()
    check(reopened.plans == repo.plans, "Plans must survive repository restart")
    let permission = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
    check(permission?.intValue == 0o600, "Encrypted plan file permissions must be owner-only")
    print("PASS encrypted persistence, restart and file permissions")

    _ = try store.add(review)
    check(try store.load().count == 1, "Duplicate confirmation cannot duplicate storage")
    try repo.cancel(review.id)
    _ = try store.add(review)
    check(try store.load().first?.status == .cancelled, "Retry cannot reactivate cancelled plan")
    print("PASS idempotent add and durable cancellation")

    unlocked = false
    repo.lock()
    check(repo.plans.isEmpty && !repo.ready, "Lock clears in-memory saved plans")
    do { try repo.cancel(review.id); fatalError("Locked cancellation was accepted") } catch PlanStorageError.locked { }
    repo.refresh()
    check(!repo.ready && repo.plans.isEmpty, "Locked refresh cannot load plans")
    unlocked = true; repo.refresh()
    check(repo.ready && repo.plans.count == 1, "Unlock can restore saved plans")
    print("PASS locked repository denies mutations and reading")

    workspace.selectRecipient(review.recipient); workspace.editMessage("Preserve this input on failure")
    let pending = try workspace.review()
    key.unavailable = true
    let beforeFailure = try Data(contentsOf: url)
    do { try repo.confirm(pending, workspace: &workspace); fatalError("Missing key saved a plan") } catch { }
    check(workspace.message == pending.message && workspace.selectedRecipient == pending.recipient, "Storage failure must preserve composer")
    check(try Data(contentsOf: url) == beforeFailure, "Missing key must not replace encrypted data")
    let requests = key.createRequests
    repo.refresh()
    check(!repo.ready && key.createRequests == requests, "Existing encrypted file must never generate a replacement key")
    key.unavailable = false
    print("PASS key loss fails closed and preserves draft and file")

    var damaged = try JSONSerialization.jsonObject(with: beforeFailure) as! [String: Any]
    var sealed = Data(base64Encoded: damaged["sealed"] as! String)!
    sealed[sealed.count - 1] ^= 1
    damaged["sealed"] = sealed.base64EncodedString()
    let tampered = try JSONSerialization.data(withJSONObject: damaged)
    try tampered.write(to: url)
    do { _ = try store.add(pending); fatalError("Tampered file accepted") } catch { }
    check(try Data(contentsOf: url) == tampered, "Unreadable encrypted data must remain untouched")
    damaged["version"] = 99
    let future = try JSONSerialization.data(withJSONObject: damaged)
    try future.write(to: url)
    do { _ = try store.add(pending); fatalError("Future schema overwritten") } catch PlanStorageError.version { }
    check(try Data(contentsOf: url) == future, "Future schema must remain untouched")
    print("PASS authenticated corruption detection and unknown schema rejection")

    let restoreURL = directory.appendingPathComponent("restored.encrypted")
    try beforeFailure.write(to: restoreURL)
    let restored = EncryptedPlanStore(url: restoreURL, keys: key)
    check(try restored.load().first?.snapshot == review, "Ciphertext copy restores with original key")
    let wrongKey = EncryptedPlanStore(url: restoreURL, keys: TestPlanKey())
    do { _ = try wrongKey.load(); fatalError("Wrong key decrypted plans") } catch { }
    check(try Data(contentsOf: restoreURL) == beforeFailure, "Wrong key must not alter saved data")
    print("PASS copy restore and wrong-key rejection")
}
