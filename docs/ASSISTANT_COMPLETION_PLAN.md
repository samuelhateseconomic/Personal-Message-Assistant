# Assistant completion plan — revised product scope

Status: approved planning baseline with implementation evidence appended below, 2026-09-26.
The initial inventory records the baseline; the latest increment describes current behavior. This plan supersedes the narrow draft-only Assistant scope and
the native-contact-deletion deferral in DESKTOP_BUILD_SPEC.md. Live message delivery remains
disabled under the user's draft-only testing instruction.

## 1. Product outcome

The Assistant is a conversational planning interface for the same contacts and plans managed
manually elsewhere in the app. It retrieves facts, asks for missing information, proposes
structured actions, and executes only the exact actions approved in the native review UI.
Writing a message is one capability, not the purpose of the entire Assistant.

Examples using synthetic contacts:
- "Find Alex, my colleague, and show the notes relevant to following up."
- "Create a contact for Jamie Chen, phone +1 202-555-0100, connection colleague."
- "Add the birthday I just supplied to Jamie's contact."
- "Change Jamie's work number, keeping the mobile number."
- "Delete this duplicate contact from the selected account."
- "Plan a birthday message for Alex tomorrow morning."
- "Show my plans for friends this week; move this one to Friday afternoon."
- "Create a contact from these details, then prepare a follow-up plan for that person."

No facts or precise times are invented to fill gaps. An unavailable feature is shown as
unavailable; example text is not presented as a functioning model or tool result.

## 2. Verified gap inventory

| Capability | Actual implementation | Work remaining |
| --- | --- | --- |
| Desktop Assistant conversation | Manual editor and example text | Conversation, progress, clarification, tool/action cards, cancellation |
| Contact retrieval | Native list + local keyword search; Python JSON resolver with sources | One native authority, typed retrieval bridge, field provenance and identity ambiguity |
| Native contact create/edit | Reviewed manual operations with pre/post checks | Reuse through assistant actions; preserve labeled values; consistent result refresh |
| Contact delete | Absent; explicitly deferred by older spec | Source-specific delete, exact review, dependent-plan handling, partial-failure recovery |
| Prompt-to-contact | Absent | Structured extraction, existing-contact lookup, duplicate/ambiguity gate, editable preview |
| Saved plan create/cancel | Native encrypted draft-only store | Shared action APIs, assistant invocation, user-readable receipts |
| Saved plan edit | Absent | Stable ID + revisioned update, stale-write rejection, renewed review, migration |
| AI-assisted planning | Not connected to native UI | Bounded tool loop and managed local model bridge |
| Messages history | Existing Python engine only | Opt-in scoped retrieval and permission/identity/readability gates in native workflow |
| Personal memory | Existing Python approved-preference system | Native read/edit/forget UX and safe bridge; no passive learning |
| Delivery | Separate legacy CLI; none from desktop | Still deferred; worker/authorization/device gates required before activation |
| Contacts sync | Local native writes and change refresh | Account/linked-card and race verification; no guarantee of atomic external conflicts |
| UI completeness | Incremental preview controls | Complete workflows, error recovery, keyboard/accessibility, Settings diagnostics |

Current evidence: 173 Python tests and 32 native check groups last passed. These do not
establish that absent integrations work. Preview 0.4.2 UI changes remain uncommitted at
this planning baseline; do not overwrite them. Existing personal contacts and CLI data
must remain local and excluded from Git.

## 3. User workflow and screen design

Assistant main area: conversation with a prompt box ("What would you like to plan or
change?"), optional selected contact/context chip, and compact suggestions such as Find
contact, Add contact, Plan follow-up, and Manage plans. Suggestions initiate real supported
workflows; unavailable ones have a clear reason instead of a simulated action.

Each turn may display:
1. Relevant facts with source and freshness, without dumping the address book.
2. A specific missing-information question or identity-choice card.
3. Editable proposal cards: contact create/edit/delete, plan create/edit/cancel.
4. Native review of exact changes and destination/account/timezone.
5. Execution result with the authoritative saved ID and a link to the affected panel.

Manual panels and Assistant use the same service methods, record IDs and review logic.
Returning from a card preserves the conversation and unsaved form. Successful actions
refresh Contacts/Plans without a manual reconnect. Failure preserves input and never
uses a success message. App/model status stays compact; diagnostics belong in Settings.

## 4. Retrieval and extraction contract

Authoritative sources:
- Apple Contacts: available source-card identity, name, labeled phones/emails, birthday,
  source account and current native snapshot.
- Local app profile: connection type, private notes and explicitly approved preferences.
- Native plan repository: saved plan ID, revision, exact endpoint/message/time, timezone,
  status and receipts. Historical plan snapshots are not overwritten by a contact rename.
- Current user message/paste: proposed new facts, attributed to user input.
- Messages history: only after the read-only scoped integration and permissions exist.

Retrieval returns structured fields, source identifiers, version/freshness, and unknown
fields. Match all keyword terms across relevant fields, then apply filters. Retrieve only
bounded candidates; require an explicit choice for ambiguous identity, same-name contacts,
multiple endpoints, conflicting birthdays, or an uncertain source card. Do not select by
model confidence alone. Exact endpoint/contact IDs are revalidated at execution.

Creating a contact from a prompt first extracts proposed fields, searches for possible
existing matches, and presents create-new versus edit-existing when appropriate. Required
creation inputs are a name and explicit destination account; phone/email/birthday are
optional unless a dependent action needs them. Relative dates/times resolve to an explicit
local date/time and IANA timezone in review; vague times prompt for clarification.

Notes, retrieved documents and message bodies are evidence, never instructions that can
approve actions, change policy, or invoke tools. A note saying "delete other contacts" must
not cause a delete. Sources are attached to retrieved facts; generated prose is marked as a
suggestion. Unknown information remains unknown. Only relevant context is sent to local
Ollama; no cloud fallback and no full-address-book prompt injection.

## 5. Shared action contract and tools

The native ActionService owns all mutation authority. Python/model output is an untrusted
proposal. Do not connect the old Python ToolRegistry directly: it exposes legacy send and
schedule writers that would bypass native review and the desktop's draft-only boundary.

Read tools: search_contacts, get_contact, search_plans, get_plan, get_preferences; later,
get_recent_messages under its separate gates. Responses are typed, bounded and sourced.

Proposal tools: propose_contact_create, propose_contact_update, propose_contact_delete,
propose_plan_create, propose_plan_update, propose_plan_cancel. These cannot mutate data.

A proposal contains an operation ID, action type, target stable ID, expected revision/source
snapshot, explicit patch, provenance, missing fields and dependencies. Native validation
resolves IDs and produces a canonical preview/digest with expiry. Only a native user gesture
can approve that preview. The model cannot mint approval or call an unrestricted execute.

States: collecting information → proposed → needs review → approved → executing → succeeded,
failed or outcome unknown. Any edit, expired/locked session, changed source or changed
canonical preview invalidates approval. Repeated execution uses an existing receipt.
Unknown outcomes are not auto-retried. Error schemas distinguish user correction, stale
review, permission loss, model unavailable, storage failure and uncertain native outcome.

Multi-step requests are dependency graphs of bounded actions. Example: create contact →
receive native ID → revalidate recipient → propose plan → review/confirm plan. If contact
creation succeeds and the next step fails, report that partial completion; do not claim a
rollback or repeat the successful creation. Retry only the unfinished action after review.

## 6. Contact deletion semantics (new scope)

Expose separate, plainly labeled actions:
- Delete an app-only contact: removes that local profile from active contacts; a local
  recoverable archive may support Undo, but only once implemented and verified.
- Delete an Apple Contacts source card: explicit account/card review; may propagate through
  that account to other devices. Do not promise Undo or recovery from this app.
- Forget private notes/preferences: distinct from deleting the native contact.

Native deletion must show the exact name, endpoints, account, affected local annotations
and related plans. Ambiguous/linked targets without a deterministic source are blocked.
Before deletion, find dependent saved plans. The review must resolve them: cancel affected
active drafts as part of the approved workflow, or block deletion until the user resolves
those plans. Never silently redirect a plan to a similarly named remaining contact.

Refetch before execute; changed cards require new review. Disable duplicate clicks. Read
back after save and distinguish absence from permission failure. If native deletion succeeds
but local cleanup fails, retain a receipt and retry cleanup only. If the outcome is unknown,
show recovery guidance, not an automatic retry. Native Contacts lacks atomic cross-process
compare-and-swap; disclose residual concurrent-writer limits and verify them on test cards.
Only single-contact deletion is in this scope; no bulk deletion or automatic deduplication.

## 7. Plan-edit semantics

Introduce stable plan IDs independent of individual review IDs, explicit revision numbers,
IANA timezone, and state/receipt records. Safely migrate encrypted version-1 files using
synthetic fixtures; preserve backups and refuse unsupported schemas or unreadable keys.
An edit targets one stored plan with expected revision, keeps it draft-only, and requires
new exact review before replacing the stored revision. A cancelled plan is not reactivated
by a retry. User confirmation after a stale contact/time check cannot approve an old snapshot.

Manual and conversational create/edit/cancel must use identical APIs. Selection and filters
must not change the action target. Save success requires verified persistence; UI reset
comes afterward. No draft-only plan is migrated into a live delivery job automatically.

## 8. Managed inference and orchestration

Use the existing local Ollama adapter and pure argument validation where reusable. Add a
managed Python child with framed, versioned private stdio; no open local HTTP control API.
Bound request/response sizes, tool results, turn count, timeouts and retries. Only allowlisted
read/proposal operations are accepted. Native writes never pass through the Python child.

Each turn carries request ID, conversation/context revision and cancellation token. Contact
switch, prompt revision, cancellation, lock or expired session rejects late output. Streaming
shows progress without blocking the interface. A model/helper failure cannot disable manual
Contacts/Plans. Logs record operational metadata, not private prompts, notes or endpoints.

## 9. Ordered implementation and exit gates

| Step | Concrete deliverable | Gate before moving on |
| --- | --- | --- |
| 1 | Shared native action types, canonical previews, IDs/revisions, error/receipt model | Manual/assistant parity fixtures; no mutation from a proposal |
| 2 | Plan schema migration and true saved-plan editing | Upgrade/restart/backup-restore/stale-edit/cancel/replay tests pass |
| 3 | Complete native contact actions including single-card delete | Create/edit/delete/permission/conflict/partial-failure fixtures; dedicated OS test-card checks |
| 4 | Native retrieval adapters with provenance and scoped keyword filters | Ambiguity, missing facts, source mapping, note-injection and endpoint tests pass |
| 5 | Managed Python/Ollama bridge and bounded planner | Version/size/deadline/cancel/malformed-output tests; no legacy sender reachable |
| 6 | Conversational Assistant with clarification/proposal/review/result cards | End-to-end supported requests complete without switching to manual forms unnecessarily |
| 7 | Multi-step planning and approved preference/context integration | Dependency/partial-success/stale-result tests; no duplicate mutations |
| 8 | Manual UI parity, Settings diagnostics, accessibility and release audit | Each advertised control works; fresh-install, key/restart, permission and keyboard/device checks |

Build in vertical slices inside this dependency order. The first assistant slice is:
search contact → explain retrieved facts → propose draft-only plan → native review →
save → show it in Plans. Do not present the full Assistant as complete until contact CRUD
and stored-plan editing also work from prompts and manual UI.

## 10. Required acceptance scenarios

- "Create Jamie …" extracts only supplied facts; possible duplicate requires a choice.
- "Edit Jamie's work number" preserves mobile number, labels and unrelated fields.
- "Delete Jamie" with multiple matches makes zero mutations until identity and account
  are selected and the exact deletion/dependencies are confirmed.
- A private note containing tool-like instructions does not trigger an action.
- A planning request can combine name + connection + note retrieval and show its sources.
- "Tomorrow morning" requests or reviews an explicit time/timezone, never hides an assumption.
- Editing one saved plan changes only its stable ID/revision; stale review is rejected.
- Twenty repeated execute requests produce at most one native side effect per operation.
- Lock, cancellation or contact switch rejects late model output and outstanding approval.
- Permission/model/Keychain failure retains input and truthfully reports partial completion.
- Contact changes refresh Assistant/Contacts/Plans; existing reviewed destinations cannot
  silently change. Missing/deleted contacts make affected plans non-actionable.
- Manual workflows work while Ollama is offline. Nothing sends under draft-only mode.
- No private data, keys, generated ledgers or contact lists enter source control.

## 11. What is decided and what still needs proof

Decided: Assistant is a planner/operator; native authority; proposal-first mutations;
scoped source-backed retrieval; single-contact delete; local notes; revisioned saved-plan
editing; manual/assistant parity; no bulk mutation or live delivery in this work.

Still needs executable proof, not an assumption: installed helper/signing and Keychain
behavior, exact Contacts account/linked-card/delete races, source-ID remapping, migration
recovery, model tool reliability and real UI accessibility. These are explicit gates in
steps 1–8, not reasons to continue adding disconnected surface controls.

Next code work: step 1 shared action contract with synthetic tests, followed by step 2
saved-plan editing/migration. Do not wire unrestricted legacy tools into the app or mutate
personal contacts as development tests. The remaining UI-only work is subordinate to these
complete workflows. No claim of full feature completion follows from compiling a screen.

## Implementation increment — preview 0.5.0

Step 1 is implemented for **plan actions only**: typed non-mutating proposals, native-issued
expiring previews with payload digests, explicit native confirmation, per-session revocation,
and durable operation receipts. Manual create/update/cancel uses the coordinator. No
model-facing mutation executor or approval-minting tool is exposed. This is not yet the
shared contract for contact deletion or an authenticated helper IPC boundary.

Step 2 now has stable plan IDs, stored revisions, reviewed timezone, before/after review,
true record updates, revision-checked cancellation, and immutable encrypted schema-1 backup
before the first schema-2 write. A legacy missing timezone stays unknown until explicit
review uses a displayed timezone. Cancelled plans cannot be reactivated by replay. Synthetic
fixtures cover migration/reopen/restore/failure, proposal non-mutation, repeated execution,
stale edit vs cancellation, lock/expiry, payload collisions and invalid timezone.

These features require actual device UI/Keychain verification before production readiness.
Native contact delete, assistant retrieval/bridge/conversation, multi-step planning and
remaining UI completion are still outstanding; the Assistant must not be described as fully
implemented. The next dependency is step 3 complete contact actions, then sourced retrieval.


## Implementation increment — preview 0.6.0

Implemented beyond the plan-editing slice:
- Single-source native deletion with expiring native review; active saved drafts block
  deletion until manually cancelled/retargeted. A store-history token and exact snapshot
  reject observed native changes. Encrypted write-ahead receipts distinguish dispatched,
  verified deleted, completed cleanup and verified still-present. Recovery never calls
  native delete. Profile conflicts preserve newer annotations. Full access is required to
  distinguish absence from an inaccessible record. External final-save races remain.
- App-only profile deletion is separate and checks the reviewed local value. Contact
  create/edit reviews now have expiry, issuer validation and session revocation.
- Direct native Ollama adapter and a conversational proposal interface. Contact create,
  update, delete, search; plan create, update, cancel, search; clarification and cancellation
  route to native sourced choices and existing editable forms/reviews. Model contact facts
  must appear in supplied input. Proposed endpoints append rather than silently replace.
- Typed contact requests never invoke the legacy Python ToolRegistry. The model receives
  only user-authored requests, not the address book, private retrieved notes or Messages.
  Native keyword retrieval shows source account/local-profile facts and freshness. Exact
  identity and destination choice remain user gestures; no confidence-based auto-selection.
- Missing plan times require a manual date edit before review; explicit parsed times carry
  IANA timezone. Invalid, past, DST-gap and repeated-hour times reject rather than normalize.
  Lock/cancel/navigation reject late model results. Success text comes from native services.

Architecture adjustment: step 5's managed Python helper is replaced for this slice by native
URLSession calls to fixed loopback Ollama with JSON schema, local model allowlist, disabled
proxies/cookies/cache, rejected redirects, a 120-second resource timeout per call and byte limits.
Inference is bounded to routing plus one action-specific extraction, with the chosen action
and target frozen in the second schema and revalidated in native code. No
Python runtime or helper IPC is needed for this proposal-only feature. A future helper for
Messages/approved memory still needs an authenticated, bounded interface; no inherited send
or schedule capability is exposed by this adjustment.

Validation: 56 native synthetic check groups pass (13 core + 43 integration). The installed
Gemma 3 passed eight live synthetic proposal scenarios: contact create/search/update/delete
and plan search/create/update/cancel. No real contacts, messages, Keychain records or saved
plans were used by those checks. Independent decoding also accepts minute-precision ISO
timestamps with seconds/offset only when they agree with the named timezone; conflicting
offsets and ambiguous DST times reject. The app launches at the locked
0.6.0 screen. Full authenticated UI and system-account CRUD remain unverified.

Remaining scope: model-informed generation using explicitly scoped retrieved notes; automatic
multi-step dependencies and partial-success continuation; native approved-memory controls;
Messages-history bridge; durable create/update contact receipts across restart; production
signing, Keychain/device migration, writable/linked-account verification, deadline/redirect
integration fixtures and accessibility QA. The current conversation supports one action at a
time, retains a bounded set of user requests, and uses the manual editor for editable review.
It is a working proposal path, not proof that every planned Assistant feature is complete.


### Device acceptance before calling the transformation complete

Use a dedicated disposable test card/account and draft-only plans, not a personal contact:
1. Unlock using macOS, connect Contacts, and verify the Assistant prompt and source cards.
2. Create a synthetic contact from a prompt. Choose an account, review, save; verify native
   Contacts and app annotations, the success message, and an empty next creation form.
3. Update its connection and add a second number. Verify the existing labeled number is
   retained; confirm each displayed change. An external edit during review must invalidate
   or surface a conflict, not silently overwrite the reviewed fields.
4. Propose a future plan. Choose its exact endpoint/time, review and save. Edit the saved
   plan and confirm its ID remains stable while the revision increases; quit/reopen.
5. Attempt to delete the test card while it has an active draft: deletion must be blocked.
   Cancel the draft through exact review, then explicitly review single-card deletion.
   Confirm only this disposable card/account is removed; cancelled plan history stays.
6. Stop inference with Cancel, navigate away, and lock during an outstanding request. No
   late result or private content should appear after locking. Manual panels work offline.
7. Check minimum window size, keyboard navigation and VoiceOver. Check each sheet's Back,
   Cancel, failure retention and success reset. Do not perform key-loss/corruption recovery
   against real data; those remain isolated-fixture and dedicated-device checks.

The coding session did not perform these authenticated OS writes. These are remaining
acceptance checks, not evidence supplied by a successful compile or a model smoke test.


## Implementation increment — preview 0.7.0

The first dependent workflow is implemented: create one contact, then prepare one draft-only
plan for the same contact. The model extracts one combined proposal; native coordination
splits it into two independently reviewed actions. An explicit duplicate choice can use an
existing card through the reviewed editor. Native save callbacks carry an operation-specific
proposal ID and the verified native snapshot; model output cannot complete a step.

A verified native contact is retained even when its local annotations fail. Recovery retries
only the local profile write, checks for newer annotations, or explicitly discards pending
notes while retaining existing notes. An uncertain native result blocks re-creation and
requires an explicit verified existing-card selection. The second step revalidates native
ID, source account and selected endpoint. Name similarity never substitutes another person.
Plan storage failure preserves the completed contact step and composer; only the unfinished
plan is retried. Completion requires the native saved-plan callback, not model text.

Progress and pending annotations are session-only, cleared on lock/end/quit. Persisted contacts
and plans remain saved. No automatic resume/replay after restart is implemented. General
multi-action dependency graphs, durable contact create/update receipts and workflow recovery,
scoped note-aware generation, Messages/approved-memory integration, and device QA remain open.
This supersedes the 0.6.0 single-action limitation only for the named two-step workflow.

Validation: 62 native synthetic check groups pass, including end-to-end injected-backend
contact creation followed by an initially failing and then successful encrypted plan save.
No real contact or plan was created by development tests. All nine live local Gemma proposal scenarios passed: the previous eight contact/plan
actions plus the combined create-contact-then-plan request. Ollama was stopped at the start
of testing; a temporary loopback server was started for synthetic validation and then stopped.
Use the normal Ollama app/server when trying the Assistant. No real-account UI write
or authenticated device acceptance test was performed in this increment.


## Implementation increment — preview 0.8.0

Scoped note-aware generation is now available after explicit native contact selection.
The user enters a purpose, selects optional connection/birthday/note fields, and sees the
exact source-labeled context before generating. Name is always shown/included; optional
fields start off. Only purpose and selected facts go to the existing fixed-loopback Ollama
adapter. IDs, account labels, destination fields, other contacts and past conversation are
excluded; private details embedded in a selected note remain part of that displayed note.
The output schema permits message text only. It cannot select identities, change times,
issue actions, approve or save anything. Notes are evidence, not action authority.

Before inference, after inference and before using the suggestion, native contact identity,
account, fields and local profile must still match the reviewed context. Missing facts,
oversized context, unavailable access, source changes or malformed output reject. Context,
prompt and model edits, navigation and locking discard in-flight/late suggestions. Results
stay editable and session-only. The user then selects a destination and opens the existing
plan editor, retaining a supplied time when available and separately reviewing the exact
plan before saving. This also works after the verified contact step of the two-step workflow.

Evidence: 68 native check groups passed (13 core + 55 integration). Two additional live
Gemma synthetic fixtures passed: use of relevant selected facts and an adversarial note
asking to inject a delete action. These are bounded test cases, not a guarantee of perfect
model grounding or injection resistance. Structural message-only output and native review
remain the action boundary. The previous nine proposal smoke scenarios were not rerun in
this increment; their last passing result is 0.7.0. Build, ad-hoc signature and locked 0.8.0
launch passed. No real contact/profile/plan was used or mutated by tests. A temporary Ollama
server was stopped afterward. No Git commit or push was made.

Still open: real authenticated UI/source-account/accessibility acceptance; durable contact
create/update receipts and workflow resume; more general dependent actions; native approved
memory; scoped Messages history; production signing and device migration/recovery. Source
labels describe supplied evidence and do not verify generated claims. This increment does
not introduce embeddings, a document corpus, automatic learning or live delivery.


## Implementation increment — preview 0.9.0

The first native approved-memory controls are available as Preferences in the sidebar.
Explicitly save a fixed tone, length and emoji style; inspect the saved value, reload, edit
or confirm Forget. Unsaved edits persist across panel navigation and clear on lock. Save
success follows write/readback verification. Stale or failed writes retain editor input.

The store uses AES-GCM, its own authenticated-data domain and a separate device-only Keychain
service. It serializes cooperating writers with a nonblocking file lock and compares the
expected record revision before each write. Forget persists an empty revised record so a
stale empty/saved view cannot recreate old memory. Corruption, unsupported versions, missing
keys and wrong keys fail without silently resetting the file. OS backups are not erased.

Use remains explicit per generation: the scoped drafting panel offers an off-by-default
“Use saved writing preferences” toggle and previews the selected style. Only fixed style
values are sent, never record IDs/timestamps. The current typed request takes precedence
over defaults. Before/after inference and before use in the plan editor, the saved record
must still match. Change/forget or lock rejects pending/late styled results. No preference
enters action routing, grants mutation authority, alters saved plans or enables delivery.

Evidence: 75 native check groups (13 core + 62 integration), build and ad-hoc signature
passed. Three live local Gemma context/style fixtures passed using synthetic data; the
nine older proposal scenarios retain their 0.7.0 results and were not rerun here. Test
preference stores used temporary files and injected keys, never real user memory or native
contacts. A temporary Ollama server was stopped after the tests. The app launches locked
as 0.9.0; authenticated Preferences/Keychain/VoiceOver acceptance still needs device testing.
No commit or push was performed.

This completes a bounded global writing-style slice of approved memory. Contact-specific
preferences, importing/reviewing legacy Python memory, learning proposals based on feedback,
durable workflow/contact-create/update recovery, general dependent actions, scoped Messages
history and production signing/device recovery remain outstanding. No automatic learning
or live messaging is claimed by this increment.


## Implementation increment — preview 0.10.0

Durable native-contact create/update receipts are now integrated into the manual editor and
Assistant routes. A separate encrypted journal is verified on disk before native dispatch;
verified native snapshots and pending app-only annotations survive restart. The existing
native review remains the authority and can still expire or reject stale records. Known
pre-write failures close the receipt without claiming a save. Post-dispatch uncertainty or
receipt-write failure retains a pending marker and blocks another native save.

Contacts now exposes recovery: check an existing exact source card without writing, save
pending local notes only, or explicitly dismiss the record after inspecting Contacts. No
recovery method calls native create/update. For creation with no durable native ID, the user
must choose an existing source card and its full fields/account must match the reviewed
values. An existing update can never be rebound to another ID. Changed native records,
changed target notes or changed app-only link sources reject cleanup; identical prior local
writes are accepted on retry. Explicit dismissal preserves contacts/current notes, discards
pending annotations and makes no claim about whether the native operation succeeded.

A related stale-edit gap was closed: local annotations are checked against the snapshot
loaded at editor entry before native dispatch. Current-session Assistant recovery now uses
the same durable receipts. Completing recovery can advance its matching in-memory workflow,
but workflow proposals, dependencies and unsaved plan composer contents still clear on lock
or restart. This is contact-save recovery, not full durable workflow resumption.

Evidence: 83 native check groups passed (13 core + 70 integration). Eight new groups cover
restart/replay, unknown create readback, exact update targets, stale annotations, corrupt
local storage, locked/key-failure guards, app-only source linking and receipt failure just
after successful native writing. All contacts/keys/stores were fake or isolated fixtures;
no personal contacts or Messages data were used. Build, ad-hoc signature and locked 0.10.0
launch passed. Model paths did not change; live Gemma results remain those recorded for
0.9.0. No commit or push was made.

Remaining: real-account/authenticated UI acceptance, full durable workflow/plan-composer
resumption, richer dependent actions and approved-memory feedback, scoped Messages history,
production signing, device migration and accessibility QA. Contacts has no cross-process
atomic compare-and-swap; external final-write races remain. An explicit recovery dismissal
can allow a later duplicate creation if the user has not checked the native address book.


## Git publication checkpoint — Preview 0.10.0

This checkpoint groups the native app transformation increments from 0.5.0 through 0.10.0:
reviewed plan actions and editing, contact deletion, local AI proposals and scoped drafting,
the contact-to-plan workflow, approved writing preferences, and durable contact-save recovery.
Earlier “no commit or push” notes describe the state at each implementation increment.

Final pre-publication validation: native build and all 83 check groups passed; ad-hoc bundle
signature and diff checks passed. Real contacts, contact imports, built app bundles, runtime
ledgers and keys are excluded from the commit. Synthetic fixtures remain in source control.
This is a development milestone, not a production release or completion of the remaining
Step 7/Step 8 work. Delivery stays disabled in the desktop app.
