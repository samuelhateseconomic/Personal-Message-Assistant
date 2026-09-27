# Native desktop integration preview

SwiftUI app for the V1 specification in ../docs/DESKTOP_BUILD_SPEC.md. Requires macOS
14+ and a compatible Swift 6 toolchain. No third-party Swift dependencies.

## Current build: Preview 0.10.0 · Contact save recovery

Contacts opens the Mac Contacts panel by default. Choose Connect / refresh and complete
the system permission prompt yourself. The app does not request access until Connect.

- Search native names, phone numbers and email addresses. System change notifications refresh the list.
- Choose New contact in Apple Contacts, select an account, enter first/last name, numbers,
  emails and optional birthday, then review and explicitly save. Blank names are rejected.
- Select an existing source card to edit the same fields. Existing labels and unrelated
  contact properties are preserved; edited number/email lines retain labels by position.
  The review shows all resulting numbers/emails, including removals. Names are separated
  into first/last name to avoid silently flattening an existing structured name.
- Conflicts show your value and the current native value with a choice for each field.
  Non-overlapping changes merge. Another edit after review invalidates that review.
- Use Add app-only contact to move an existing local profile into an explicitly selected
  account. Its connection type and private note are linked to the returned native ID.
- Connection type and assistant notes stay local. Native notes are not read or changed.
  The app does not implement its own cloud sync; the chosen account handles device syncing.
- Confirmed saves show success and reset/close the creation form. Failures retain entries.
  A failed verification is marked uncertain and its save request is not replayed. Inspect
  Apple Contacts before starting another operation. If native save succeeds but local
  annotations fail, Retry local notes only cannot create another native contact.
- Source records are fetched without unifying linked cards. A native update requires one
  exact record and one container; unavailable or ambiguous targets are rejected. Read-only
  accounts are rejected by the OS; the public container API does not expose writability.

The Contacts save API uses last-writer-wins for concurrent changes. This preview performs
three-way merge, a second pre-save check, and post-save verification; those are **not an
atomic compare-and-swap**. An external write can still race the final check/save. See
[Apple's CNSaveRequest documentation](https://developer.apple.com/documentation/contacts/cnsaverequest).
This remains a development preview; the production conflict gate and account-specific
real-device verification have not passed. No real Contacts writes were performed during development.

## Other functionality and limitations

Assistant proposes contact and plan actions and retrieves native candidates with source labels; Plan uses exact phone/email destinations. The composer remains in memory; confirmed draft-only plans are encrypted on disk; the Python engine and delivery worker
are not connected. No message is sent or real schedule created by this app. Demo contacts
remain available separately from native contacts.

Native macOS authentication controls the interface. The app starts locked, locks on the
wired sleep/session events and expires after five minutes (fixed duration, not idle timeout).
Apple decides which authentication methods are available; Watch cannot be guaranteed.
Permission attribution, dedicated screen lock, and auth methods need device verification.

Local profiles are stored outside Git in
`~/Library/Application Support/MessageAssistant/contact-profiles.json`. Newly created
storage directories use mode 0700 and profile files mode 0600. This JSON is not encrypted;
authentication is not a filesystem boundary against other code running as the same user.
The final production broker/key architecture is still pending.

## Build and run

```bash
swift run --package-path desktop --scratch-path desktop/.build/native AssistantCoreChecks
swift run --package-path desktop --scratch-path desktop/.build/native NativeIntegrationChecks
./desktop/scripts/build-app.sh
open 'desktop/.build/Message Assistant Demo.app'
```

If Swift's project build cache reports an I/O error:

```bash
IMSG_BUILD_DIR="$(mktemp -d /private/tmp/imsg-native-build.XXXXXX)" ./desktop/scripts/build-app.sh
```

Save unfinished edits and quit the running app with Command-Q before reopening. Check the
lock screen for **Preview 0.10.0 · Contact save recovery**. The build is ad-hoc signed, not notarized;
permission persistence across rebuilds is not guaranteed. The visible project-root app
shortcut points to the hidden build folder and is ignored by Git.

## Verification

- Build and ad-hoc signature verification pass.
- Thirteen core state checks and twenty-six native integration check groups pass. Sync checks use
  an injected synthetic backend, never the real address book. They cover merge/conflict,
  stale review, lock rejection, verified create/update, duplicate dispatch, uncertain
  result handling and preservation of annotations when linking an app-only contact.
- Existing Python suite previously passed 173 tests; this change does not modify Python.
- New sync UI and actual Contacts account behavior still require device verification.

### Real-device checklist (use a dedicated test card)

1. Confirm the current version and authenticate. Cancelled authentication must remain locked.
2. Connect; verify denial/permission recovery without publishing personal lists or counts.
3. Create a synthetic card in a chosen writable account, review the exact details, save,
   then check it in Apple Contacts. Read-only accounts must show failure and keep inputs.
4. Reopen the card here; edit a number/email/birthday; check the change in Apple Contacts.
5. Edit it in Apple Contacts; check list refresh and reopen the app editor to verify fields.
6. Edit different fields in the two apps, then review to verify a disjoint merge. Edit the
   same field to exercise conflict choices; change it again after review to reject stale save.
7. Check existing multi-value labels, linked cards, source account, and yearless birthdays.
8. Move a synthetic app-only card to Mac Contacts; check notes stay local and no local
   duplicate remains. Simulate local storage failure only in an isolated test environment;
   retry annotations without duplicating the native record.
9. Verify success/failure feedback, fresh empty creation forms, locking during review,
   keyboard navigation, window resizing, and VoiceOver. Review the account's own sync
   behavior separately; an accepted local save is not proof of remote cloud delivery.

Do not paste real contacts, counts, identifiers or screenshots into public reports.

### Shared recipients — 0.3.1

Assistant and Plan both expose Connect Apple Contacts, recipient search, and a destination
picker. They share the same NativeContacts instance used by the Contacts panel. A single
available endpoint is selected with the contact; multiple endpoints require an explicit
choice. Selecting a different contact or destination clears the draft and invalidates
approval. Refresh revalidates selection; missing contacts/numbers are cleared, never
silently replaced. Contact name changes invalidate review while preserving draft text.

A review displays the exact native identity's name and selected phone/email. The source
record and endpoint are checked again before review and before demo approval. Access loss,
refreshing, deletion, or locking prevents stale approval. Lock clears native recipient data
and the in-memory draft. No recipient data is logged or written to Git. This does not
connect Messages history, Ollama, sending, or the scheduling worker.

After unlocking 0.3.1: connect in Assistant, choose a contact/destination, type a draft,
then switch to Plan and verify the same selection and text. Change the number and verify
that the old text/review is cleared. These UI/device checks remain pending; synthetic
state tests cover required selection, exact endpoint snapshots, renames, deletion,
permission loss and lock cleanup. The rebuilt app was reopened and its version verified.

### Plan confirmation — 0.3.2

Review exact plan → Confirm plan retains the reviewed snapshot in Added plans (session only),
closes review, and presents a success alert. The new-plan composer resets recipient/search,
message, language, and time (one hour ahead). The list is in memory and does not enqueue a
message or survive quitting. Failed or expired confirmation does not reset the composer or
append a plan; repeated confirmation cannot duplicate the snapshot. Automated state checks
cover these paths. The success alert appears after the review sheet dismisses; visual testing
of that transition still requires unlocking the app on device.

### Persistent plans — 0.4.0 (supersedes session-only plans)

Confirmed plans now save to `~/Library/Application Support/MessageAssistant/plans-v1.encrypted`
using AES-256-GCM. The key is a device-local Keychain generic password, separate from the
ciphertext. Schema version 1 stores the exact reviewed recipient/message/time, creation time
and draft-only/cancelled status. No worker consumes this file, including after restart.

Confirmation validates against a copy of the composer, persists, then resets the real form.
Failures retain input and show an error. A retry with the same review ID is idempotent.
Saved plans load after unlock. Cancellation persists; the cancelled record remains visible.
A file lock serializes cooperating app processes; encrypted writes use atomic replacement.
Missing keys, unknown schema and authentication/corruption errors do not overwrite the file.
The app never creates a replacement key for an existing encrypted store. Read requests do
not create a key when no plans exist. The Keychain key is first created on a confirmed save.

This is an incremental B4/C1 implementation, not the completed production broker. Keychain
access after ad-hoc rebuilds and on-device restart/cancellation must still be tested. Copying
only the ciphertext to another Mac is not sufficient for recovery. Do not delete the key or
saved file to resolve an error. Existing session-only plans from an older running binary
are not automatically migrated; preserve them manually before quitting that old binary.
Existing CLI databases and active jobs are untouched.

Six synthetic storage check groups verify encryption/restart, idempotent cancellation,
locked access, missing key and write-failure behavior, corruption/schema rejection, and
ciphertext-copy restore/wrong-key rejection. No real Keychain item is created by these tests.
See ../docs/NATIVE_STORAGE_DECISION.md for production decisions and remaining gates.

### Combined keyword search and filters — 0.4.1

Saved plans and recipient selection match all keywords across name, connection type,
private app note, and available contact fields; saved plans also search message text.
Filters narrow these results. Saved plans offer multi-select connection/contact/status
filters plus today, next seven days (including today), and an inclusive custom date range.
Recipient selection offers connection filters. Filter chips can be removed individually;
Clear all resets the query and filters. Search never changes a selection or sends data to AI.
Notes are searched locally but never printed in previews. Missing profile data is reported.

See ../docs/UI_REFINEMENT_PLAN.md for the full agreed redesign and remaining work. Matcher
and boundary tests are automated; UI/device validation for these new controls is pending.

### Plans workspace — 0.4.2

Plans now opens the saved list and selected details. Choose New plan for a separate
composer; Assistant → Create plan brings the current draft into it. Back protects an
unfinished draft with Keep editing / Keep draft and return / Discard. Resume draft restores
the same in-memory inputs. Successful save selects the new plan and returns to the list
before the success alert. Switching recipients with typed text now requires confirmation.
Saved-plan details keep cancellation available. Filtering does not silently change the
selected plan. The nonfunctional delivery toggle is removed; no delivery is enabled.

On-device verification pending: create/back/resume/discard, recipient-change cancel/confirm,
save-to-selected-detail, preserved filters, cancellation refresh, minimum-size layout and
keyboard/VoiceOver. Existing 32 native checks remain applicable; this UI-only increment
adds no delivery or persistence schema changes.

### Reviewed saved-plan editing — 0.5.0

Select a saved draft → Edit plan → change the text, recipient or planned time → Review exact
plan. The review shows the current saved revision and proposed replacement. Save changes
updates the same stored ID and increments its revision; it does not add a duplicate. Back
keeps the existing saved record untouched. Cancellation now also has exact native review.
Existing unfinished composer input is protected before switching to another saved plan.

Create/update/cancel use a typed PlanMutation and native PlanActionCoordinator. A proposal
is not approval. Reviews expire in two minutes and are revoked on lock; the stored revision
is rechecked during execution. Failures keep input. Stored timezone is used in edit/review;
legacy plans display that their original timezone was not recorded. New edits review the
current displayed timezone rather than silently inventing a historical one.

First write to a legacy ledger preserves its encrypted bytes in a schema1-backup sibling,
then writes schema 2. Keep the backup and Keychain key; old binaries reject schema 2. No
real user plan file was migrated during development. Thirty-nine native check groups pass
using temporary files/test keys. Device UI, migration and Keychain checks remain pending.
This was the first plan-action slice. The 0.6.0 additions below connect conversational
proposals and reviewed contact deletion; the remaining limitations are listed explicitly.


### Conversational Assistant and contact deletion — 0.6.0

Assistant → Connect Apple Contacts → enter one request → Ask assistant. Select the exact
contact or saved plan from the sourced candidates. Open the editable proposal, choose any
missing account/destination/time, then use the same native Review and Confirm controls as
the manual panels. Outcomes come from native persistence, never from the model.

Examples (synthetic names only):
- Find Jamie, my colleague, with conference in the note.
- Create a contact named Jamie Chen, phone +12025550100, connection colleague.
- Change Jamie's connection type to friend.
- Delete the contact Jamie.
- Create a draft plan for Jamie with message Hello on October 15, 2035 at 14:00.
- Show my saved plans; then make a separate request to edit or cancel one.

The model picker offers local gemma3:4b, gemma3:12b and gemma3:27b. The default is 12b.
Start Ollama and install that model separately. The adapter sends typed requests only to
127.0.0.1:11434/api/chat, rejects redirects, disables HTTP proxies/cookies/cache, caps input
and output, and cancels expired requests. It uses at most two structured inference calls (route, then action-specific extraction),
with a 120-second resource timeout per call. There
are no model-exposed execute/send tools and no cloud fallback. Local keyword lookup works
without Ollama. Only the current request and up to two earlier typed requests are sent;
the native address book and retrieved private notes are not sent to inference.

Contact name/phone/email/birthday/connection/note extraction must be grounded in supplied
text. Names or missing birthdays are not inferred. Existing endpoints are retained in the
editable proposal; replacements/removals require editing the visible lines. Birthdays from
prompts must use YYYY-MM-DD. Multiple candidates and endpoints require an explicit choice.
Missing planned times cannot be confirmed until the date editor is changed. Generated
message prose is a suggestion, not retrieved evidence. Relative-time model reliability is
not established; exact date/time/timezone review remains required.

Contacts → select a card → Review deletion from Apple Contacts. Deletion shows the exact
source/account and local annotations, blocks active saved-plan dependencies, rechecks native
change history and local notes, and records encrypted dispatch state before the native call.
Full Contacts access and a history token are required. Unknown outcomes expose Check result;
verified native deletion plus local failure exposes Retry local cleanup. Neither repeats the
native delete. The encrypted receipt survives restart. App-only profiles have a separate
reviewed delete button. Neither deletion has in-app Undo. No personal contacts were changed
or deleted during development.

Fifty-six native check groups pass (13 core, 43 integration). The opt-in
`NativeIntegrationChecks --ollama-smoke` check uses synthetic prompts with the installed
local model and performs no Contacts or plan writes. All eight live synthetic scenarios passed: contact create/search/update/delete and plan
search/create/update/cancel. These validate proposals only; they do not exercise native writes.

Still pending: authenticated device UI/Keychain and account-specific CRUD verification,
production signing, automatic multi-step dependency execution, model use of retrieved notes,
Messages history, approved-memory UI and full accessibility QA. Multi-action requests ask
which action to do first. Contacts/Plans editors intentionally remain the final editable
review path. There is no automatic message delivery.


### Two-step contact-to-plan workflows — 0.7.0

Ask: “Create a contact named Jamie Chen, phone +12025550100, connection colleague,
then prepare a draft plan for the same person with message Hello on October 15, 2035
at 14:00 in America/Los_Angeles.” These are synthetic example details.

1. Review the contact proposal and possible duplicates. Choose an account, edit the fields
   if needed, and confirm the native contact save.
2. Use View workflow. The second step is bound to the verified native contact ID and
   account, never a new name search. Select an exact current phone/email endpoint, edit the
   proposed plan, review its exact details, and confirm it separately.
3. Both steps show completion only after native persistence succeeds. No delivery occurs.

If native creation succeeds but annotations fail, the workflow retains the native identity
and offers local-only cleanup. Newer local annotations block overwrite; explicitly keeping
the existing notes is a separate choice. An uncertain native save blocks another create;
refresh and explicitly choose a verified existing card, or end the workflow and inspect
Contacts yourself. Plan-save failure keeps the first step completed and the plan composer
intact. Repeated callbacks cannot advance or execute a completed step again.

Workflow progress is session-only. Locking, quitting or explicitly ending it clears pending
workflow state; saved contacts and plans remain. There is no automatic replay after restart.
General multi-action graphs, durable workflow resume, Messages and approved-memory integration
remain pending. This increment supports the one named two-step workflow only.

Sixty-two native groups pass (13 core + 49 integration), including synthetic contact save,
partial annotation failure, exact identity/endpoint binding, plan key failure/retry, duplicate
callbacks and lock/end behavior. The authenticated UI and real-account write checklist in
`docs/ASSISTANT_COMPLETION_PLAN.md` remains required before a production-readiness claim.


The 0.7.0 live model check passed all nine synthetic scenarios, including the combined
workflow. Start the normal Ollama app/server before using Ask assistant; the temporary
development server was stopped after validation. Manual contact/plan controls remain usable
without model inference.


### Selected contact context — 0.8.0

In Assistant, look up and explicitly select a contact, either from an AI search/plan proposal
or with the local keyword lookup. Expand **Write a message using selected contact facts**.
Enter what the message should do, then optionally select connection type, birthday and/or
private note. All optional fields start off. The exact context preview shows the included
name and selected facts with their sources. **Generate with this context** sends your purpose
and those facts to the selected local Gemma model. No other contacts, native IDs, account
labels, endpoint fields, past requests or unselected fields are included. Any private details
inside a selected note are included verbatim in that preview and request; deselect the note
if you do not want them used. This is a direct selected-card workflow, not semantic RAG.

Edit the suggestion, choose the exact phone/email, and choose **Use this message in the plan
editor**. Existing explicit plan times are preserved; otherwise choose a date/time manually.
Review and confirm through the normal plan controls. Nothing is sent or scheduled. The
existing create-contact → plan workflow also supports this step once the contact is saved.

Native source identity, account, fields and local profile are rechecked before inference,
after inference and before opening the plan editor. Changed/unavailable sources require
refresh and reselection. Prompt, model or context changes cancel an outstanding result;
leaving the panel or locking clears it. A suggestion is session-only. Sources show the facts
supplied, not proof that every generated sentence is correct. Review the wording.

Validation: 13 core + 55 integration check groups passed. The two new live Gemma fixtures
cover relevant context and an instruction-injection note; all test input is synthetic.
The earlier nine routing/extraction smoke cases were not rerun for this message-only addition.
To run the new fixtures with the local server already running:

```sh
"${IMSG_BUILD_DIR:-desktop/.build/native}/debug/NativeIntegrationChecks" --context-smoke
```

The temporary test server was stopped after verification. Start normal Ollama for actual use.
Authenticated UI acceptance still requires unlocking on your Mac: check the toggles/preview,
edit/reset/cancel behavior, source refresh, keyboard navigation and plan confirmation using
a disposable test card and draft-only plan. The development run only verified the locked
0.8.0 launch screen, not these real-account interactions.


### Approved writing preferences — 0.9.0

Open **Preferences** in the sidebar after unlocking. Choose tone (neutral, warm,
professional or casual), length (brief or standard), and emoji use (none or light).
The page displays both the saved style and the exact choices to save. **Save these
preferences** explicitly approves those choices and shows success after verified persistence.
Unsaved edits stay available when navigating between panels but clear on lock. Reloading
with pending edits asks before replacing them. Failed/stale saves retain your edits.

In Assistant's selected-contact context section, **Use saved writing preferences** starts
off. Turning it on shows the exact saved style in the context preview; generating includes
only its fixed style choices. Preference identifiers/timestamps are not sent to the model.
The current request takes precedence when it explicitly asks for another style. Preferences
are not injected into contact/plan action classification and grant no action authority.

**Forget saved preferences…** requires confirmation, removes the active saved style and
resets the controls. Changed/forgotten preferences invalidate an in-flight styled suggestion.
Existing messages, saved plans and OS backups are not rewritten. This feature does not
passively learn from your contacts, notes or edits and does not import the legacy Python
approved-memory store. It currently supports a global writing style only.

Storage: authenticated encryption in Application Support with a separate device-local
Keychain key. A revisioned empty record remains after Forget to reject stale saves. An
unreadable file/key or unknown schema fails visibly and is not silently replaced. Plaintext
style and unsaved edits clear from the controller when the workspace locks.

Validation: 13 core + 62 native integration groups passed. Three live Gemma context fixtures
passed using synthetic data: selected facts, adversarial note instructions, and selected
brief/no-emoji preferences. Run the existing `--context-smoke` check with Ollama running to
repeat those cases. The temporary development server was stopped afterward. The nine older
routing scenarios retain their prior 0.7.0 result; they were not rerun in this increment.

Device acceptance remains: unlock and save a test style, quit/reopen to verify the real
Keychain path, opt in for a draft, edit/save the plan through normal review, and forget the
style. Confirm stale/failure text, keyboard navigation and lock clearing. Development tests
used temporary stores and injected keys; the app was only opened to its locked 0.9.0 screen.


### Durable contact-save recovery — 0.10.0

Contact create/edit now stores an encrypted receipt before dispatching the native save.
After verified readback it records the native ID and retains pending local annotations until
those annotations and completion are persisted. If the app quits or a storage error occurs,
open Contacts after unlocking to see **Contact saves needing recovery**. New native saves
are blocked while any earlier save remains unresolved.

- **Check existing card only** reads the exact native ID/account/fields without writing.
  For an unconfirmed creation whose ID was never recorded, inspect Apple Contacts and select
  the exact source card first. A matching name alone is insufficient; the selected card must
  match all reviewed native fields and account. No automatic name-based association occurs.
- **Save pending local notes only** checks current native identity/fields and expected local
  notes, then saves the reviewed annotations. Newer notes, changed app-only source profiles,
  unreadable data or unavailable access reject recovery. A prior identical local save is
  accepted idempotently. No create/update request is repeated.
- **Dismiss recovery…** asks you to confirm that you inspected Contacts, then discards the
  pending notes and marks the receipt dismissed. It does not assert save success, undo the
  native save or change existing notes. Starting another creation afterward can duplicate
  an already-created card; inspect first. Dismissal is an explicit way to resolve a known
  failed or unwanted pending operation without replaying it.

Normal contact edits also compare local annotations to what was loaded when editing began
before native dispatch. A stale note edit therefore fails before changing Apple Contacts.
The Assistant's current-session note retry and uncertain-card choice use the same journal.
Recovery completion can advance a still-active matching workflow; the complete workflow and
unsaved plan composer are not persisted across lock/restart by this change.

Validation: 13 core + 70 integration groups passed, including restart/replay, unknown create,
exact update identity, newer notes, corrupt profiles, locked access, receipt key loss,
app-only linking and receipt failure immediately after successful native writing. Tests use
fake native backends, temporary stores and injected keys. No real contacts were written.
Build, signature verification and the locked 0.10.0 launch passed. Model behavior did not
change, so the previous 0.9.0 live Gemma results were not rerun.

Device acceptance remains: use a disposable test card to check success/reset, persistence
of recovery across quit/reopen, source-account behavior and keyboard accessibility. Do not
corrupt real data or force a crash during a real Contacts save to simulate failure; the
failure paths are covered by isolated injected fixtures. Production signing and real
Keychain recovery still need dedicated device testing.
