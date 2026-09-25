import Foundation
import NativeServices

@MainActor
final class FakeAuth: Authenticator {
    var isAvailable = true
    var calls = 0
    var invalidated = false
    var continuation: CheckedContinuation<Bool, any Error>?
    func available() -> Bool { isAvailable }
    func authenticate() async throws -> Bool {
        calls += 1
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func invalidate() { invalidated = true }
    func finish(_ result: Bool) { continuation?.resume(returning: result); continuation = nil }
}

@main
struct Checks {
    @MainActor static func main() async {
        func check(_ condition: Bool, _ message: String) {
            guard condition else { fatalError(message) }
        }
        let unavailable = FakeAuth(); unavailable.isAvailable = false
        let unavailableSession = NativeSession(makeAuthenticator: { unavailable })
        await unavailableSession.unlock()
        check(!unavailableSession.unlocked && unavailable.calls == 0, "Unavailable authentication must not unlock")
        print("PASS unavailable authentication remains locked")

        let auth = FakeAuth()
        let session = NativeSession(makeAuthenticator: { auth })
        let attempt = Task { await session.unlock() }
        while auth.continuation == nil { await Task.yield() }
        await session.unlock()
        check(auth.calls == 1, "Repeated unlock must not start a second prompt")
        session.lock()
        check(auth.invalidated, "Lock invalidates authentication")
        auth.finish(true)
        await attempt.value
        check(!session.unlocked, "Late success after lock must be discarded")
        print("PASS duplicate prompt prevention and stale success rejection")

        let denied = FakeAuth()
        let deniedSession = NativeSession(makeAuthenticator: { denied })
        let denyTask = Task { await deniedSession.unlock() }
        while denied.continuation == nil { await Task.yield() }
        denied.finish(false)
        await denyTask.value
        check(!deniedSession.unlocked && !deniedSession.authenticating, "Rejected authentication must remain locked")
        print("PASS rejected authentication remains locked")

        let success = FakeAuth()
        let successSession = NativeSession(makeAuthenticator: { success })
        let successTask = Task { await successSession.unlock() }
        while success.continuation == nil { await Task.yield() }
        success.finish(true)
        await successTask.value
        check(successSession.unlocked, "Successful authentication unlocks")
        successSession.lock()
        check(!successSession.unlocked, "Explicit lock clears session")
        print("PASS success and explicit session locking")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ContactProfileStore(url: directory.appendingPathComponent("profiles.json"))
        do {
            check(try store.load().isEmpty, "Missing profile file starts empty")
            let first = ContactProfile(name: "Example Person", connection: "Friend", birthday: Date(timeIntervalSince1970: 946684800), note: "Synthetic note", phone: "+1 202-555-0100", email: "example@example.test")
            try store.save(first, for: "test-one")
            try store.save(ContactProfile(name: "Second Example"), for: "test-two")
            let loaded = try store.load()
            check(loaded["test-one"] == first && loaded.count == 2, "Round trip preserves fields and other profiles")
            let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
            check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Saved file must be owner-only")
            print("PASS profile persistence, isolated identities and file permissions")
            let legacyData = Data(#"{"name":"Legacy Example","connection":"Friend","note":"Kept"}"#.utf8)
            let legacy = try JSONDecoder().decode(ContactProfile.self, from: legacyData)
            check(legacy.phone.isEmpty && legacy.email.isEmpty && legacy.note == "Kept", "Existing profiles must migrate without losing information")
            print("PASS older profiles load with empty optional phone/email fields")
            let createdID = try store.create(ContactProfile(name: "  New Example  ", connection: "Friend", note: "Synthetic"))
            let anotherID = try store.create(ContactProfile(name: "New Example"))
            let reopened = try ContactProfileStore(url: store.url).load()
            check(createdID.hasPrefix("local:") && createdID != anotherID, "New contacts need distinct stable local identities")
            check(reopened[createdID]?.name == "New Example" && reopened[createdID]?.connection == "Friend", "Created contact must persist and trim its name")
            check(reopened["test-one"] == first, "Creating a contact must preserve existing profiles")
            var blankRejected = false
            do { _ = try store.create(ContactProfile(name: " \n ")) } catch { blankRejected = true }
            check(blankRejected, "Blank contact names must be rejected")
            check(try store.load().count == 4, "Invalid creation must not add a record")
            print("PASS local creation, restart persistence, duplicate names and blank-name rejection")
            let damaged = Data("invalid JSON".utf8)
            try damaged.write(to: store.url)
            var rejected = false
            do { try store.save(first, for: "test-one") } catch { rejected = true }
            check(rejected, "Unreadable existing profiles must reject saving")
            let retained = try Data(contentsOf: store.url)
            check(retained == damaged, "Unreadable data must remain intact")
            print("PASS unreadable profiles are not overwritten")
        } catch { fatalError("Profile storage check failed") }
        do { try runContactSyncChecks() } catch { fatalError("Contact sync checks failed") }
        do { try runPlanStorageChecks() } catch { fatalError("Plan storage checks failed") }
        print("19 native integration checks passed; no system prompt or real contacts used")
    }
}
