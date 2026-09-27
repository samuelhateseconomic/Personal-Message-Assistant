import Foundation
import CryptoKit
import NativeServices

@MainActor final class PreferenceGate { var unlocked = true }
@MainActor func runWritingPreferenceChecks() async throws {
    func check(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("preferences.encrypted")
    let keys = TestPlanKey(); let gate = PreferenceGate()
    let store = WritingPreferenceStore(url: url, keys: keys, isUnlocked: { gate.unlocked })
    check(try store.load() == nil && keys.createRequests == 0, "Reading empty preferences must not create a key or preference")
    var style = WritingStyle(); style.tone = .professional; style.length = .standard
    let first = try store.save(style, expected: nil)
    let reopened = WritingPreferenceStore(url: url, keys: keys, isUnlocked: { gate.unlocked })
    check(try reopened.load() == first && first.style == style, "Explicit style must survive restart")
    let bytes = try Data(contentsOf: url)
    check(!String(decoding: bytes, as: UTF8.self).contains("professional"), "Preference plaintext leaked to disk")
    check((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Preference ciphertext must be owner-only")
    print("PASS explicit preference save, encrypted restart persistence and owner-only storage")

    var revised = style; revised.tone = .warm
    let second = try reopened.save(revised, expected: first)
    do { _ = try store.save(style, expected: first); fatalError("Stale preferences overwrote newer choices") } catch WritingPreferenceError.stale {}
    let forgotten = try reopened.save(nil, expected: second)
    check(try reopened.load()?.style == nil && forgotten.revision != second.revision, "Forget must remove active style and advance revision")
    do { _ = try store.save(style, expected: nil); fatalError("Old empty view resurrected forgotten memory") } catch WritingPreferenceError.stale {}
    do { _ = try store.save(style, expected: second); fatalError("Old saved view resurrected forgotten memory") } catch WritingPreferenceError.stale {}
    print("PASS stale write rejection and revisioned forget prevents preference resurrection")

    let before = try Data(contentsOf: url)
    gate.unlocked = false
    do { _ = try store.load(); fatalError("Locked preference read accepted") } catch WritingPreferenceError.locked {}
    do { _ = try store.save(style, expected: forgotten); fatalError("Locked preference write accepted") } catch WritingPreferenceError.locked {}
    gate.unlocked = true; keys.unavailable = true
    do { _ = try store.save(style, expected: forgotten); fatalError("Missing key replaced preferences") } catch WritingPreferenceError.unavailable {}
    check(try Data(contentsOf: url) == before, "Key failure must preserve encrypted memory")
    keys.unavailable = false
    let wrongKey = WritingPreferenceStore(url: url, keys: TestPlanKey(), isUnlocked: { true })
    do { _ = try wrongKey.load(); fatalError("Wrong key accepted") } catch WritingPreferenceError.unavailable {}
    print("PASS locked reads/writes and missing/wrong keys fail without replacing saved memory")

    let corrupt = Data("damaged preference fixture".utf8)
    try corrupt.write(to: url)
    do { _ = try store.save(style, expected: forgotten); fatalError("Corrupt memory overwritten") } catch WritingPreferenceError.unavailable {}
    check(try Data(contentsOf: url) == corrupt, "Corrupt bytes must be retained")
    let ledger = try JSONSerialization.data(withJSONObject: ["version": 999, "record": ["revision": UUID().uuidString, "updatedAt": 0, "style": ["tone": "warm", "length": "brief", "emoji": "none"]]])
    let future = try AES.GCM.seal(ledger, using: keys.value, authenticating: Data("MessageAssistant.writing-preferences.v1".utf8)).combined!
    try future.write(to: url)
    do { _ = try store.save(style, expected: nil); fatalError("Unsupported memory schema overwritten") } catch WritingPreferenceError.unavailable {}
    check(try Data(contentsOf: url) == future, "Future schema must be retained")
    try before.write(to: url)
    print("PASS corrupt and unsupported preference files preserved instead of reset")

    let editor = WritingPreferencesController(store: store)
    editor.refresh(); editor.edited = style; editor.save()
    check(!editor.failed && editor.record?.style == style && editor.status.contains("successfully"), "Save must report verified success")
    let baseline = editor.record!
    _ = try store.save(revised, expected: baseline)
    editor.edited.emoji = .light; editor.save()
    check(editor.failed && editor.edited.emoji == .light && editor.record == baseline, "Stale failure must retain unsaved edits")
    editor.refresh(); editor.forget()
    check(!editor.failed && editor.record?.style == nil && editor.status.contains("forgotten"), "Forget must report success only after persistence")
    editor.clear(); editor.save()
    check(editor.record == nil && !editor.ready && editor.status.isEmpty, "Lock clears memory UI and prevents reuse")
    print("PASS preferences controller reports verified outcomes, preserves failures and clears on lock")

    let approved = try store.save(style, expected: store.load())
    let context = try ScopedDraftContext(evidence: syntheticDraftEvidence(), selection: [], writingPreference: approved)
    let recorder = PlannerTransportRecorder()
    let response = try JSONSerialization.data(withJSONObject: ["done": true, "message": ["role": "assistant", "content": "{\"message\":\"Hello Jamie.\"}"]])
    let planner = OllamaAssistantPlanner(transport: { request in await recorder.record(request); return response })
    _ = try await planner.draft(purpose: "Say hello", context: context, model: "gemma3:12b")
    let body = try JSONSerialization.jsonObject(with: (await recorder.requests)[0].httpBody!) as! [String: Any]
    let messages = body["messages"] as! [[String: String]]
    let input = try JSONSerialization.jsonObject(with: Data(messages[1]["content"]!.utf8)) as! [String: Any]
    let included = input["writing_preferences"] as! [String: String]
    check(included == ["tone": "professional", "length": "standard", "emoji": "none"], "Only approved fixed style choices may enter inference")
    check(!messages[1]["content"]!.contains(approved.revision.uuidString) && body["tools"] == nil, "Memory revision and mutation tools must never enter inference")
    do { _ = try JSONDecoder().decode(WritingStyle.self, from: Data("{\"tone\":\"delete_contacts\",\"length\":\"brief\",\"emoji\":\"none\"}".utf8)); fatalError("Arbitrary style instructions accepted") } catch {}
    let forgottenAgain = try store.save(nil, expected: approved)
    do { _ = try ScopedDraftContext(evidence: syntheticDraftEvidence(), selection: [], writingPreference: forgottenAgain); fatalError("Forgotten style supplied as memory") } catch AssistantFailure.insufficientContext {}
    print("PASS only explicitly selected fixed style enters inference; no identity, tools or forgotten memory")

    let live = try store.save(style, expected: forgottenAgain)
    let delayed = DelayedDraftGenerator(); let draft = ScopedDraftSession(generator: delayed)
    let controller = WritingPreferencesController(store: store); controller.refresh()
    let pending = try ScopedDraftContext(evidence: syntheticDraftEvidence(), selection: [], writingPreference: live)
    draft.generate(purpose: "Hello", context: pending, model: "gemma3:12b", verify: { try controller.validate(live) })
    while delayed.continuation == nil { await Task.yield() }
    controller.forget(); delayed.finish("Obsolete style suggestion")
    while draft.busy { await Task.yield() }
    check(draft.message.isEmpty && draft.error.contains("preferences changed"), "Forgotten style must invalidate in-flight completion")
    print("PASS forgetting preferences during inference rejects the late styled result")
}
