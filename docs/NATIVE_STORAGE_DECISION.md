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
