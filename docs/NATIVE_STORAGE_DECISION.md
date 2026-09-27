# Native plan storage decision — preview 0.4.0

## Scope and ownership

NativeServices.PlanRepository is the only writer of the desktop's draft-only plan file.
All windows share the repository. Authorization is checked synchronously before operations;
no async suspension occurs between authorization, write, and composer reset. Other app
processes using the same file cooperate through a nonblocking advisory lock. Python cannot
write this file through an exposed interface; the Python CLI remains an independent system.
No existing schedules are imported and no worker receives these plans.

## Format and keys

A version-1 JSON envelope contains a version and base64 AES-GCM sealed box. The encrypted
payload contains its own schema version and reviewed plan snapshots, creation time and
status. Ciphertext is authenticated with an application/version-specific context. The
8 MiB read/write limit prevents unbounded files. UUID review IDs provide idempotency;
repeated saves cannot reactivate a cancelled plan. Future schema versions are rejected,
not replaced or opportunistically decoded. The original data is preserved on read failure.

A 256-bit random key is stored as a device-local, when-unlocked Keychain generic password.
The app does not store a password or write the key into the repository or plan file. The
real Keychain provider is only exercised by user actions in the app; test keys are injected.
An existing encrypted file requires its existing key. A missing key never triggers key
regeneration over that file. The file is created outside Git in Application Support with
owner-only permissions. Atomic replacement writes only encrypted bytes to temporary disk.
The profile JSON for relationship/notes is separate and remains unencrypted in this preview.

## Failure and lock behavior

A candidate composer is validated before storage; the live composer resets only after
storage returns success. Local write/Keychain failure keeps the input and gives feedback.
Cancellation retains a durable cancelled record. On app lock the repository drops its
loaded plan list, and workspace recipient/draft/preview-history state is cleared. There
is no claim of memory zeroization or protection against arbitrary same-user code.

## Remaining production gates

- B1/B2: stable Developer ID/helper identities, bundled runtime, permission attribution,
  available authentication methods, and key access across rebuild/install upgrades.
- B4: authenticated IPC caller identity and capability revocation across processes;
  key recovery/export policy; profile encryption; immutable worker-payload key design.
- C1: future-schema migrations and any explicit legacy import with backup/collision review.
  There is no import of Python jobs or old in-memory previews in this change.
- C2/C3: typed IPC, timeouts/size bounds, action ledger, durable dispatch receipts and
  edit/cancel/worker claim transactions. A stored draft is not an authorization to send.
- Device QA: first save through Keychain, quit/reopen, cancellation, locked access,
  wrong/missing-key recovery UX and concurrent app instances. Do not test destructive
  recovery scenarios on personal data; use an isolated fixture environment.

## Evidence

Synthetic tests pass for restart/preservation, ciphertext contents, file permissions,
idempotent saves, cancelled-state retention, lock denial, failed-write draft retention,
missing key, corrupted authentication tag, unknown schema, restore from a ciphertext copy
with the original key, and wrong-key rejection. Actual Keychain/OS integration is pending.

## Schema 2 and reviewed actions — 0.5.0

The encrypted envelope, Keychain identity, associated-data string and file path stay the
same for compatibility; the inner ledger moves to version 2 on the first successful write.
Each plan now has a stable ID, independent reviewed snapshot ID, revision and optional IANA
timezone. Missing legacy timezone is not guessed during load. Durable receipts bind each
operation ID to its payload digest and resulting revision. Cancelled records stay cancelled
on a repeated operation; old expected revisions cannot overwrite edits or cancellation.

Loading version 1 is read-only. Its first mutation writes an exact ciphertext copy to
`plans-v1.encrypted.schema1-backup` with mode 0600 before replacing the original. An existing
conflicting backup blocks migration. Reopening does not remigrate version 2. The older app
will reject this newer inner schema; do not restore a backup over newer changes. Fixture
restoration is done to another path with the original test key.

PlanActionCoordinator issues two-minute native review previews; the native Confirm UI checks
issued identity, expiry, session and current composer, then the store rechecks revision under
the file lock. Proposals and previews alone do not mutate. Lock revokes issued previews.
Contact actions and the future Python bridge have not yet migrated to this contract. This
in-process boundary is not a substitute for the pending signed IPC authority.


## Contact deletion receipts and local inference — 0.6.0

`contact-deletions.encrypted` uses the existing Keychain symmetric key with a separate
AES-GCM associated-data domain. A cooperating-process file lock covers write-ahead receipt,
native dispatch and follow-up receipt writes. Plan-store locking prevents cooperating app
writers from adding a dependency during the native delete. The receipt is saved before
execution; native errors remain uncertain until a fully authorized absence query succeeds.
Restart recovery only checks the result and retries local annotation cleanup, never delete.
Completed receipts discard their stored annotation payload. Receipt files remain private
Application Support data and must not enter Git. This does not encrypt the main profile file.

Create/update contact review tokens are native-issued, expiring and session-bound; durable
receipts for those two older operations are still pending. Contact deletion depends on full
Contacts access and a store history token, with residual last-writer-wins races as documented
by [Apple](https://developer.apple.com/documentation/contacts/cnsaverequest). This is not an
atomic transaction spanning Apple's store and local JSON.

The first conversational planner uses the native Ollama
[chat API](https://docs.ollama.com/api/chat) with
[structured outputs](https://docs.ollama.com/capabilities/structured-outputs). It has no
mutation authority, helper process or access to legacy Python send tools. It receives only
bounded typed user requests; native retrieval and exact-record reviews stay in-process.


### Preview 0.9.0: approved writing preferences

The native global writing-style record is stored in `writing-preferences.encrypted` under
the app's Application Support directory. It uses AES-GCM with domain
`MessageAssistant.writing-preferences.v1` and its own Keychain service
`local.messageassistant.prototype.writing-preferences`; the existing plan/deletion key is
unchanged. Values are fixed enums, with UUID revision and update time. Missing means no
approved memory. Forget writes a nil-style tombstone, preserving revision conflict checks.
The store authorizes reads/writes against the current native session, bounds file size,
serializes cooperating writers, compares expected records, atomically writes ciphertext,
and verifies readback. Unreadable data is preserved. No automatic migration from Python
memory exists. Session lock clears the controller, not the encrypted approved style.


### Preview 0.10.0: contact save receipts

`contact-saves.encrypted` in Application Support uses a separate device-local Keychain
service `local.messageassistant.prototype.contact-saves` and AES-GCM authenticated-data
domain `MessageAssistant.contact-saves.v1`. A nonblocking file lock serializes cooperating
writers. The bounded ledger retains operation IDs and native-field/account snapshots, plus
pending annotation values/baselines while recovery is needed. Completed/dismissed/notSaved
records clear the pending note values; encrypted operation markers remain to reject replay.
The whole ledger is capped at 4 MiB; it is not silently truncated or reset when full or
unreadable. Native dispatch requires confirmed receipt persistence. Local cleanup uses
baseline checks; this does not add cross-process locking to the existing profile store.
No legacy contact JSON, personal contacts or receipt files belong in the repository.
