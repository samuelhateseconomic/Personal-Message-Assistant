import Foundation
import NativeServices
import AssistantCore

@MainActor final class WorkflowPlanner: AssistantPlanning {
    let value: AssistantIntent
    var calls = 0
    init(_ value: AssistantIntent) { self.value = value }
    func propose(userInput: String, model: String, now: Date, timezone: String) async throws -> AssistantIntent {
        calls += 1; return value
    }
}
@MainActor func runAssistantWorkflowChecks() async throws {
    func check(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
    var combined = AssistantIntent(action: .createContactThenPlan)
    combined.givenName = "Jamie"; combined.familyName = "Chen"; combined.phones = ["+12025550100"]
    combined.connection = "colleague"; combined.note = "Conference"
    combined.message = "Hello"; combined.localDateTime = "2035-10-15T14:00"; combined.timezone = "America/Los_Angeles"
    let input = "Create Jamie Chen, phone +12025550100, connection colleague, note Conference, then plan Hello for 2035-10-15 at 14:00"
    let encoded = try JSONEncoder().encode(combined)
    check(try AssistantIntent.decode(encoded, userInput: input) == combined, "Combined extraction must validate all supplied facts")
    do { _ = try AssistantIntent.decode(encoded, userInput: "Create Jamie then plan"); fatalError("Invented combined contact facts accepted") } catch AssistantFailure.ungrounded { }
    let split = try AssistantWorkflow(combined)
    check(split.contactIntent.action == .createContact && split.contactIntent.message == nil && split.planIntent.action == .createPlan,
          "Only contact fields may enter the first editor")
    check(split.planIntent.message == "Hello" && split.planIntent.phones == nil && split.contact == nil, "No identity may be invented for the second step")
    print("PASS combined intent grounding and non-mutating dependency split")

    let fake = WorkflowPlanner(combined)
    let conversation = AssistantConversation(planner: fake)
    conversation.ask(input, model: "gemma3:12b")
    while conversation.busy { await Task.yield() }
    check(conversation.workflow?.stage == .contactProposal && conversation.intent?.action == .createContact, "Conversation must expose only the first proposal")
    conversation.ask("Start another request", model: "gemma3:12b")
    check(fake.calls == 1 && !conversation.error.isEmpty, "An unfinished workflow must not be silently replaced")
    let proposal = UUID(); try conversation.bindContactReview(proposal)
    let profile = ContactProfile(name: "Jamie Chen", connection: "colleague", note: "Conference")
    conversation.recordContactEvent(.attempting(proposal, profile, nil, nil))
    do { try conversation.bindContactReview(UUID()); fatalError("Unknown native outcome permitted another save") } catch AssistantFailure.workflowPending { }
    conversation.recordContactEvent(.failed(proposal, uncertain: false))
    check(conversation.workflow?.stage == .contactReview, "Known no-write failure should retain the first review step")
    conversation.recordContactEvent(.attempting(proposal, profile, nil, nil))
    conversation.recordContactEvent(.failed(proposal, uncertain: true))
    check(conversation.workflow?.stage == .contactUnknown, "Uncertain native result must block a retry")
    print("PASS pending workflow cannot be replaced and unknown native saves cannot be replayed")

    let backend = FakeContactBackend()
    let contacts = ContactSyncService(backend: backend, isUnlocked: { true })
    let save = try contacts.review(base: nil, edited: combined.applying(to: ContactFields()), accountID: "test-account")
    let saved = try contacts.commit(save)
    conversation.recordContactEvent(.verified(UUID(), saved))
    check(conversation.workflow?.contact == nil, "Foreign native callback linked a contact")
    conversation.recordContactEvent(.verified(proposal, saved))
    for _ in 0..<20 { conversation.recordContactEvent(.verified(proposal, saved)) }
    check(conversation.workflow?.stage == .annotationsPending && backend.writes == 1, "Verified contact must persist as a completed native step")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let profiles = ContactProfileStore(url: directory.appendingPathComponent("profiles.json"))
    try Data("damaged JSON".utf8).write(to: profiles.url)
    do { try conversation.retryWorkflowAnnotations(profiles: profiles, contacts: contacts); fatalError("Damaged annotations replaced") } catch { }
    check(conversation.workflow?.stage == .annotationsPending && backend.writes == 1, "Local failure must not repeat native creation")
    try Data("{}".utf8).write(to: profiles.url)
    let newer = ContactProfile(name: "Jamie Chen", note: "Newer independent note")
    try profiles.save(newer, for: "mac:" + saved.id)
    do { try conversation.retryWorkflowAnnotations(profiles: profiles, contacts: contacts); fatalError("Newer annotations overwritten by recovery") } catch ContactSyncError.changed { }
    check(try profiles.load()["mac:" + saved.id] == newer, "Profile conflict must preserve newer data")
    try profiles.remove("mac:" + saved.id, expected: newer)
    let lockedContacts = ContactSyncService(backend: backend, isUnlocked: { false })
    do { try conversation.retryWorkflowAnnotations(profiles: profiles, contacts: lockedContacts); fatalError("Locked cleanup was accepted") } catch ContactSyncError.locked { }
    try conversation.retryWorkflowAnnotations(profiles: profiles, contacts: contacts)
    check(try profiles.load()["mac:" + saved.id] == profile && conversation.workflow?.stage == .planReady && backend.writes == 1,
          "Local-only recovery must retain verified native identity and advance once")
    print("PASS partial contact success retries local notes only; repeated callbacks have one effect")

    guard let workflow = conversation.workflow else { fatalError("Missing workflow") }
    let wrong = ContactSnapshot(id: "same-name-different-card", accountID: saved.accountID, fields: saved.fields)
    do { _ = try workflow.continuation(for: wrong); fatalError("Same-name substitution accepted") } catch AssistantFailure.workflowTarget { }
    let moved = ContactSnapshot(id: saved.id, accountID: "different-account", fields: saved.fields)
    do { _ = try workflow.continuation(for: moved); fatalError("Moved account accepted") } catch AssistantFailure.workflowTarget { }
    let staleEndpoint = Recipient(nativeID: saved.id, name: saved.fields.name, kind: .phone, address: "+12025550199")
    do { _ = try conversation.openWorkflowPlan(staleEndpoint, fresh: saved); fatalError("Missing endpoint accepted") } catch AssistantFailure.workflowTarget { }
    let recipient = Recipient(nativeID: saved.id, name: saved.fields.name, kind: .phone, address: saved.fields.phones[0])
    let workflowID = try conversation.openWorkflowPlan(recipient, fresh: saved)
    check(conversation.workflow?.stage == .planEditing, "Verified exact destination should open the second editor")
    print("PASS second step binds verified native ID/account and rejects removed endpoints")

    let key = TestPlanKey()
    let ledger = EncryptedPlanStore(url: directory.appendingPathComponent("plans.encrypted"), keys: key)
    let plans = PlanRepository(store: ledger, isUnlocked: { true }); plans.refresh()
    let coordinator = PlanActionCoordinator(repository: plans, isUnlocked: { true })
    var composer = Workspace(requiresNativeRecipient: true)
    composer.setRecipientAccessAvailable(true); composer.selectRecipient(recipient); composer.editMessage("Hello")
    let review = try composer.review()
    let mutation = PlanMutation(kind: .create, planID: review.id, review: review, timezone: "UTC")
    let preview = try coordinator.prepare(mutation, workspace: composer)
    key.unavailable = true
    do { try coordinator.confirm(preview, workspace: &composer); fatalError("Plan save ignored failed key access") } catch { }
    check(conversation.workflow?.stage == .planEditing && backend.writes == 1 && composer.message == "Hello", "Second-step failure must preserve first step and composer")
    key.unavailable = false
    try coordinator.confirm(preview, workspace: &composer)
    check(!conversation.completeWorkflowPlan(UUID(), planID: review.id, recipient: recipient), "Foreign plan completion accepted")
    check(conversation.completeWorkflowPlan(workflowID, planID: review.id, recipient: recipient), "Native confirmed plan must complete workflow")
    check(!conversation.completeWorkflowPlan(workflowID, planID: review.id, recipient: recipient), "Completion replay advanced twice")
    check(try ledger.load().count == 1 && backend.writes == 1 && conversation.workflow?.savedPlanID == review.id, "Two-step retry duplicated a native effect")
    print("PASS failed second step retries only plan persistence and completes from native confirmation")

    var unknown = try AssistantWorkflow(combined)
    let unknownID = UUID(); try unknown.bindContactReview(unknownID)
    unknown.attemptingContact(unknownID, profile: profile, expected: nil, replacing: nil)
    try unknown.useExistingAfterUncertain(saved)
    check(unknown.contact?.id == saved.id && unknown.stage == .annotationsPending, "Explicit uncertain-outcome resolution must reuse the selected record")
    unknown.discardPendingAnnotations()
    check(unknown.stage == .planReady && unknown.pendingProfile == nil, "Explicitly discarding unsaved notes must preserve the native step")
    conversation.cancel(clear: true)
    conversation.recordContactEvent(.verified(proposal, saved))
    conversation.recordContactEvent(.annotationsSaved(proposal))
    check(conversation.workflow == nil && conversation.intent == nil && !conversation.completeWorkflowPlan(workflowID, planID: review.id, recipient: recipient), "Lock/end must reject late workflow completions")
    check(try ledger.load().count == 1 && backend.writes == 1, "Ending workflow must not roll back saved changes")
    print("PASS explicit uncertain-save resolution, note discard and lock/end preserve saved changes")
}
