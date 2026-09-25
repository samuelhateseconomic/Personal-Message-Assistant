# Native desktop integration preview

SwiftUI app for the V1 specification in ../docs/DESKTOP_BUILD_SPEC.md. Requires macOS
14+ and a compatible Swift 6 toolchain. No third-party Swift dependencies.

## Current build: Preview 0.4.0 · Saved draft plans

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

Assistant and Plan now share a searchable native contact recipient and exact phone/email destination. The composer remains in memory; confirmed draft-only plans are encrypted on disk; the Python engine and delivery worker
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
lock screen for **Preview 0.4.0 · Saved draft plans**. The build is ad-hoc signed, not notarized;
permission persistence across rebuilds is not guaranteed. The visible project-root app
shortcut points to the hidden build folder and is ignored by Git.

## Verification

- Build and ad-hoc signature verification pass.
- Eleven core state checks and nineteen native integration check groups pass. Sync checks use
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
