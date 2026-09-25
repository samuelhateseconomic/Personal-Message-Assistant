# Native desktop prototype — first milestone

SwiftUI prototype for the V1 specification in ../docs/DESKTOP_BUILD_SPEC.md. Requires
macOS 14+ and a compatible Swift 6 toolchain. No third-party Swift dependencies.

Features: native sidebar, Assistant with editable example drafts and language choices,
manual one-time Plan editor, exact-plan review sheet, approval invalidation, cancel,
Contacts editor with simulated competing edits, and simulated lock/unlock.

All content is synthetic and stays in memory. Closing the app discards the session.
There is no real Messages/Contacts access, sending, scheduling, model connection,
password collection, Watch authentication, background worker, or persistent storage.
Lock/unlock demonstrates UI flow only; it is not a security boundary. Each window is
an independent demo. The first prototype has one plan editor; contact switching clears
its draft. Per-contact draft preservation and a multi-plan repository are later work.

Build and run from the repository root:

```bash
swift run --package-path desktop --scratch-path desktop/.build/native AssistantCoreChecks
./desktop/scripts/build-app.sh
open 'desktop/.build/Message Assistant Demo.app'
```

The script creates a local development app, not a signed/notarized distribution.
Native permission attribution, bundled Python and real system authentication are the
next feasibility milestone. Build artifacts are ignored by Git.

Manual review:
1. Assistant → expand AI assistance → Load example draft → edit it.
2. Review schedule → select a future time → Review exact plan → Approve demo plan.
3. Edit the text: status must return to Needs review. Cancel the demo plan.
4. Contacts → change name/email → simulate competing edit → review and choose a value.
5. Lock demo → content disappears → Simulate successful unlock.
6. Resize window; check keyboard navigation and native sheet cancellation with Escape.

Core tests cover stale approval rejection, locking, recipient changes, invalid content/time,
and cancellation. UI interaction/appearance verification must be recorded separately.

The checks use a dependency-free executable harness because the installed Command Line
Tools do not include the Swift Testing module. They exit nonzero on any failed check.

## Verification — 2026-09-25

- SwiftUI app compiled and packaged with Swift 6.3.3 on Apple Silicon.
- Five dependency-free core checks passed, including stale approvals and locked mutations.
- Existing Python regression suite: 173 passed.
- Native UI observed: Assistant → Plan, exact-plan sheet, demo approval to Pending,
  text edit back to Needs review, Contacts conflict resolution to incoming value,
  lock hiding workspace, and simulated unlock restoring it.
- Contacts layout visually inspected in dark appearance at the initial window size.
  Full keyboard/VoiceOver, light appearance and minimum-size review remain pending.
- Real Contacts, authentication, model IPC, persistence and delivery remain unconnected.

Swift's build database reported I/O errors when placed under this project's desktop
folder. Building in a temporary cache succeeded. If the normal command has that issue:

```bash
IMSG_BUILD_DIR="$(mktemp -d /private/tmp/imsg-native-build.XXXXXX)" ./desktop/scripts/build-app.sh
open 'desktop/.build/Message Assistant Demo.app'
```

The completed demo is at `desktop/.build/Message Assistant Demo.app`. The temporary
cache can be discarded after the build; it contains generated objects, not user data.
