# 🦴 Project Skeleton — iMessage Scheduler Agent

This document maps the current project, its implemented behavior, and the remaining build phases.

Phase 3 and approved memory were published in a2ff30c. Phase 4 adds read-only history and reply suggestions.
Validation: 173 automated tests, Ruff lint/format checks, and diff checks passed.
Selected live history and Gemma drafting passed; scheduled delivery and installed
launchd operation remain unverified. See docs/ACCEPTANCE_RESULTS.md for evidence and limits.

## Current native desktop preview — 0.4.0

`desktop/` contains SwiftUI Assistant, Plan and Contacts workspaces with LocalAuthentication,
shared searchable Apple Contacts recipients, reviewed native contact saves, and per-field
conflict choices. Plan confirmation now persists an encrypted draft-only record before
resetting the composer. Saved plans restore on unlock/restart and support cancellation.
The Keychain key stays outside the repository; ciphertext is stored in Application Support.
NativeServices is the sole plan-store writer, with authorization checks and serialized file
updates. No Python helper, real message history, model IPC or delivery is connected yet.

Thirty native synthetic check groups pass (eleven core, nineteen integration), including
restart, corruption/key-loss handling, cancellation and duplicate-save rejection. The
existing Python engine and its previously passing 173-test suite remain separate.
B1/B2/B3 device/signing checks, final B4 key/recovery proof, and production C1/C2/C3 gates
remain open. See [desktop/README.md](desktop/README.md) and
[storage decision](docs/NATIVE_STORAGE_DECISION.md). Later version-specific entries below
record earlier preview stages; this section is the current status.

## Implementation status — Phase 4 implementation + approved memory

- Phase 1: implemented and tested. A live direct submission passed; recipient receipt remains unverified.
- Phase 2: implemented: structured JSON Ollama adapter, prompt builder, validator,
  six-pattern fallback parser, bounded agent loop, eleven active tools in chat (including three memory tools), nine guardrails,
  exact-plan confirmations, and a `chat` CLI command. Reader/reply handlers are exposed
  only when their reader/backend dependencies are provided.
- Phase 3: implemented: direct send/schedule/list/cancel CLI, persistent claims, cron
  scheduling, safe retries, overdue handling, delivery-time checks, crash recovery,
  singleton foreground daemon, heartbeat, notifications, and launchd management.
  Daemon/launchd/sending tests are mocked; live integration remains unverified.
- Phase 4: read-only direct-message history, archived-text decoding, identity/readability
  gating, memory-aware reply suggestions, history/reply CLI, and synthetic tests implemented.
  Selected live Messages history and Gemma drafts verified; wider platform testing remains outstanding.
- Approved memory: `memory/models.py`, `repository.py`, `service.py`, and `cli.py`
  implement approved preferences, opt-in draft feedback, conflict confirmations,
  management commands, and local SQLite persistence. Chat tools retrieve/save/forget
  preferences. `tests/test_memory.py` evaluates this behavior with synthetic data.
- Personal contacts have persistent IDs for memory scope. Legacy contacts without IDs
  use phone-derived IDs and reject shared identities. New memory tables are created
  lazily when a memory service is initialized; existing delivery tables are preserved.
- Preference precedence: current explicit request, contact-specific, then global.
  Feedback proposals are not active until separately approved. The initial proposal
  heuristic detects substantially shorter rewrites only. No model retraining, passive
  Messages-history analysis, or automatic changes to guardrails are implemented.
- Contact evidence retrieval returns structured stored fields and source pointers with
  clarification for ambiguous identity. Document RAG and generated-citation verification
  are not implemented.
- Personal `contacts.json` and import reports are local/ignored; `contacts.example.json`
  is the tracked sample. Tests use `tests/fixtures/contacts.example.json`.

Implementation decisions: interactive mutations require confirmation, including cancellation;
scheduled delivery uses the approval recorded when the schedule was created;
dry runs preview all mutations. A mutation attempt ends the agent turn to prevent automatic
resends. Invalid read-only tool calls can be corrected within the five-step loop. History
retains five complete user/answer pairs without AI summarization. IDs are not guessed or
rewritten. Schemas are generated from Pydantic. The model adapter uses structured JSON
rather than assuming native tool support. Only loopback Ollama hosts are accepted.

Next milestone: finish chat action routing and live scheduler/launchd verification.
The 2026-09-24 run was draft-only at the user's request. Selected history and model
drafting were tested; a prior separately authorized direct iMessage was submitted.
No live daemon was installed or started during development.
Read-only preflight on 2026-09-22 found valid personal contacts, denied Messages database
access, and no responding Ollama service. Both blockers are now resolved.
`imsg doctor --config config.json --contacts
contacts.json` now repeats these prerequisite checks without reading conversation rows,
creating files, running inference, or sending. `diagnostics.py` implements the checks;
`test_diagnostics.py` covers unavailable services, missing models, local-only networking,
private error suppression, and configuration reads without writes.
Contact reload is manual and SMS fallback after uncertain submission remains omitted.

Phase 3 decisions: worker wakes every second to support 30/60/120-second persisted retry
backoff. It retries only failures known to precede submission. Claims left in `sending`
after a crash become failed for manual review, never automatically replayed. A shared
mutation lock serializes app senders. Quiet hours, rate and duplicate checks defer
unattended sends; old schedules require renewed background-delivery approval. Cron uses
the saved contact timezone, skips DST gaps and second folds, and catches up at most one
overdue occurrence. The first delivery is controlled by `send_at`. Installed plists use
absolute paths and restart only after unsuccessful exits.

Tests are implemented alongside each phase, rather than deferred until Phase 4.

---

## Project Tree

```
messenger_assistant_mac/
├── .gitignore
├── pyproject.toml
├── uv.lock
├── README.md
├── skeleton.md                          ← You are here
├── contacts.example.json                ← Tracked sample only
├── contacts.json                        ← Local, ignored personal contacts
├── contacts.import-review.json          ← Local, ignored import review
├── config.json
├── com.imsg-agent.daemon.plist
│
├── .vscode/
│   ├── settings.json
│   ├── launch.json
│   └── extensions.json
│
├── src/imsg_agent/
│   ├── __init__.py
│   ├── __main__.py
│   ├── models.py
│   ├── config.py
│   ├── logger.py
│   ├── store.py
│   ├── messenger.py
│   ├── reader.py
│   ├── scheduler.py
│   ├── cli.py
│   ├── daemon.py
│   │
│   ├── agent/
│   │   ├── __init__.py
│   │   ├── orchestrator.py
│   │   ├── backend.py
│   │   ├── prompts.py
│   │   ├── validator.py
│   │   └── fallback.py
│   │
│   ├── guardrails/
│   │   ├── __init__.py
│   │   ├── guardian.py
│   │   └── rules.py
│   │
│   ├── contacts/
│   │   ├── __init__.py
│   │   └── manager.py
│   │
│   ├── memory/
│   │   ├── __init__.py
│   │   ├── models.py
│   │   ├── repository.py
│   │   ├── service.py
│   │   └── cli.py
│   │
│   └── tools/
│       ├── __init__.py
│       ├── registry.py
│       ├── schemas.py
│       ├── send.py
│       ├── schedule.py
│       ├── manage.py
│       ├── contacts.py
│       └── reply.py
│
└── tests/
    ├── fixtures/
    │   └── contacts.example.json
    ├── conftest.py
    ├── test_foundation.py
    ├── test_cli_delivery.py
    ├── test_daemon.py
    ├── test_memory.py
    ├── test_reader.py
    ├── test_reply.py
    ├── test_contacts.py
    ├── test_guardrails.py
    ├── test_validator.py
    ├── test_fallback.py
    ├── test_store.py
    ├── test_scheduler.py
    └── test_agent.py
```

---

## File-by-File Reference

### Root Files

| File | Headline | Phase |
|---|---|---|
| `pyproject.toml` | **Project Configuration** — Dependencies, entry points, build system, tool settings | Setup |
| `README.md` | **Documentation** — Setup guide, architecture, CLI reference, dev workflow | Setup |
| `skeleton.md` | **Project Skeleton** — This file. Maps every file and its purpose | Setup |
| `contacts.example.json` | **Sample Contacts** — Synthetic contacts safe to publish | Setup |
| `contacts.json` | **Personal Contacts** — Local and ignored; persistent contact IDs | Local data |
| `contacts.import-review.json` | **Import Review** — Local and ignored; entries needing review | Local data |
| `.gitignore` | Excludes personal contacts, databases, logs, environment, and caches | Setup |
| `uv.lock` | Reproducible Python dependency resolution | Setup |
| `config.json` | **Default Configuration** — Guardrail settings, Ollama model, data directory | Setup |
| `com.imsg-agent.daemon.plist` | **launchd Reference Template** — Installer generates a plist with absolute paths; restart on unsuccessful exits | Phase 3 |

### VS Code Workspace

| File | Headline |
|---|---|
| `.vscode/settings.json` | **Editor Settings** — Python interpreter, Ruff formatter, pytest integration |
| `.vscode/launch.json` | **Debug Configurations** — 4 configs: chat, daemon, send, pytest |
| `.vscode/extensions.json` | **Recommended Extensions** — Python, Pylance, Ruff, debugpy |

---

### Core Source — `src/imsg_agent/`

| File | Headline | Phase |
|---|---|---|
| `__init__.py` | **Package Init** — Version string | 1 |
| `__main__.py` | **Entry Point** — `python -m imsg_agent` delegates to CLI | 3 |
| `models.py` | **Data Models** — All Pydantic models: ScheduledMessage, Contact, GuardrailConfig, tool arg schemas, TOOL_ARG_MODELS registry | 1 |
| `config.py` | **Configuration Loader** — Reads `config.json`, applies defaults via Pydantic | 1 |
| `logger.py` | **Structured Logger** — Rich-powered logging for CLI (color) and daemon (file) | 1 |
| `store.py` | **SQLite Store** — Schedules, send log, audit log, heartbeat. WAL mode. Built-in sqlite3. | 1 |
| `messenger.py` | **AppleScript Bridge** — Sends iMessage/SMS via osascript. Escaping, version detection, dry-run. | 1 |
| `reader.py` | **Message Reader** — Read-only direct-phone history, schema checks, timestamps, supported archive decoding, and bounded reads; requires Full Disk Access. | 4 |
| `scheduler.py` | **Tick Scheduler** — 1-second polling loop. Persistent claims, sleep recovery, and safe retry backoff. | 3 |
| `cli.py` | **CLI Interface** — Typer + Rich. Commands: chat, send, schedule, list, cancel, history, reply, contacts, daemon, config, memory. | 3 |
| `daemon.py` | **Background Daemon** — Tick scheduler + heartbeat. Signal handling. launchd managed. | 3 |

---

### Agent Module — `src/imsg_agent/agent/`

| File | Headline | Phase |
|---|---|---|
| `__init__.py` | **Agent Package Init** | 2 |
| `orchestrator.py` | **Agent Orchestrator** — Core AI loop: user input → Ollama → validate → guardrail → confirm → execute → respond. Max 5 tool iterations. Context capped at 10 messages. | 2 |
| `backend.py` | **Ollama Backend** — Loopback-only SDK adapter; structured JSON, availability and model setup | 2 |
| `prompts.py` | **System Prompt Builder** — Dynamic prompt with current time, contact summary, pending count, rules. Contacts NOT injected (lazy via tool). | 2 |
| `validator.py` | **Tool-Call Validator** — Pydantic schema enforcement. Auto-repairs: misspelled fields (rapidfuzz), NL dates (dateparser), type coercion. | 2 |
| `fallback.py` | **Regex Fallback Parser** — Handles explicit commands when the local model is unavailable. 6 regex patterns validated through Pydantic. | 2 |

---

### Guardrails Module — `src/imsg_agent/guardrails/`

| File | Headline | Phase |
|---|---|---|
| `__init__.py` | **Guardrails Package Init** | 2 |
| `guardian.py` | **Guardian Middleware** — Sequential rule runner. Deterministic (not AI). Blocks/warns/approves. Logs to audit table. | 2 |
| `rules.py` | **9 Guardrail Rules** — ContactValidation, BlackoutHours, GlobalRateLimit, PerContactRateLimit, DuplicateDetection, ContentLimits, TimeValidation, ConfirmationGate, BatchSizeLimit | 2 |

---

### Contacts Module — `src/imsg_agent/contacts/`

| File | Headline | Phase |
|---|---|---|
| `__init__.py` | **Contacts Package Init** | 1 |
| `manager.py` | **Contact Manager** — Resolves names → phones. Pipeline: exact → alias → phone → fuzzy (rapidfuzz ≥70). Groups, templates, summary, and unique contact IDs. | 1 |

---

### Memory Module — `src/imsg_agent/memory/`

| File | Responsibility | Stage |
|---|---|---|
| `__init__.py` | Memory package | Approved memory |
| `models.py` | Limited vocabulary for language, tone, length, emoji, and formality | Approved memory |
| `repository.py` | SQLite preferences, feedback, revision tracking, and deletion | Approved memory |
| `service.py` | Scope resolution, exact-change confirmations, overrides, conflicts, and feedback proposals | Approved memory |
| `cli.py` | List, remember, update, forget, record feedback, approve proposals, and delete feedback | Approved memory |

---

### Tools Module — `src/imsg_agent/tools/`

| File | Headline | Phase |
|---|---|---|
| `__init__.py` | **Tools Package Init** | 2 |
| `registry.py` | **Tool Registry** — Register handlers, get Ollama schemas, dispatch tool calls. | 2 |
| `schemas.py` | **Tool Schemas** — 11 generated schemas including memory, history, and reply tools; availability is dependency-gated. | 2 |
| `send.py` | **Send Handler** — Submit the confirmed, resolved plan; log outcomes without uncertain retries | 2 |
| `schedule.py` | **Schedule Handler** — Atomically persist the confirmed expanded batch with delivery approval. Registry resolves groups and templates. | 2 |
| `manage.py` | **Manage Handlers** — list_scheduled: query store. cancel_scheduled: update status. | 2 |
| `contacts.py` | **Contact Handlers** — resolve_contact: fuzzy lookup. list_contacts: filter by group. | 2 |
| `reply.py` | **Reply Handlers** — Read-only history and draft-only generation with evidence/source checks and approved preferences. | 4 |

---

### Tests — `tests/`

| File | Headline | Phase |
|---|---|---|
| `fixtures/contacts.example.json` | Synthetic contact data used by tests | Foundation |
| `test_foundation.py` | Models, config, logging, and mocked messaging | Foundation |
| `test_cli_delivery.py` | Direct CLI schedule/list/cancel and send previews | 3 |
| `test_daemon.py` | Singleton worker, lifecycle, and mocked launchd management | 3 |
| `test_reader.py` | Synthetic SQLite schemas, archives, group exclusion, read-only access, WAL, and timestamps | 4 |
| `test_reply.py` | Evidence gate, preference overrides, draft validation, no-send behavior, and CLI | 4 |
| `test_memory.py` | Consent, persistence, identity, override precedence, feedback, forgetting, and concurrent changes | Approved memory |
| `conftest.py` | **Shared Fixtures** — Temp SQLite DB, mock contacts, mock Ollama, mock messenger | 4 |
| `test_contacts.py` | **Contact Tests** — Exact, alias, fuzzy, ambiguous, not found, group, template | 4 |
| `test_guardrails.py` | **Guardrail Tests** — All 9 rules: blackout, rate limit, duplicate, batch, time | 4 |
| `test_validator.py` | **Validator Tests** — Pydantic validation, auto-repair (typos, dates, types) | 4 |
| `test_fallback.py` | **Fallback Tests** — 6 regex patterns + unrecognized input | 4 |
| `test_store.py` | **Store Tests** — CRUD, due queries, rate limit queries, WAL concurrency | 4 |
| `test_scheduler.py` | **Scheduler Tests** — Tick fire, overdue/sleep, retry backoff, cron | 4 |
| `test_agent.py` | **Agent Tests** — Tool loop, multi-turn, max iterations, repair, fallback, guardrail block | 4 |

---

## Build Order

| Phase | Focus | Files | Checkpoint |
|---|---|---|---|
| **1** | Foundation | models, config, logger, store, contacts/manager, messenger | Can resolve contacts and send messages |
| **2** | Agent + Tools + Guardrails | tools/*, guardrails/*, agent/* | `imsg chat` works end-to-end |
| **3** | Scheduler + CLI + Daemon | scheduler, cli, daemon, __main__, plist | Implemented; delivery verified with mocks only |
| **Memory** | Approved preferences and feedback | memory/*, agent/tool integration | Persistent approved preferences; no retraining |
| **4** | Smart replies and live verification | reader, tools/reply, reply CLI, integration tests | Selected live history and drafts passed; background delivery remains unverified |


## Phase 4 behavior and limits

- Only direct phone conversations are selected; groups and email-only threads are excluded.
- Chat selection requires explicit direct-chat style plus one matching participant; unknown
  styles are excluded and schemas missing chat-type metadata fail closed.
- SQLite is opened with mode=ro and query_only. No source copy or permission change is made.
- pytypedstream decodes supported attributed-string archives. Unsupported bodies remain
  unreadable; no raw-byte string guessing is used.
- Reply generation requires readable, untruncated latest context and an incoming message.
  Context is bounded; source IDs must refer to supplied readable messages.
- Source matching is provenance validation, not factual or semantic citation verification.
- Draft generation has no tools and ends the chat turn; sending remains a separate action.
- No automatic saving of conversation history or draft feedback occurs.
- Document RAG, attachments/media understanding, and exhaustive macOS format compatibility
  remain outside the implemented scope.

### Contact profile editor

Native Contacts panel now supports search and app-only personal information: name, connection type, optional birthday, and notes. Explicit saves persist locally outside Git with owner-only file permissions. Apple Contacts remains read-only; these annotations are not yet inputs to AI drafting. Local profile JSON is not encrypted. Synthetic storage checks are included; real-device editor verification remains pending.

The contact profile editor also supports **New contact** with explicit creation/cancellation. New contacts use stable app-local IDs and persist outside the repository; Apple Contacts writes and messaging-recipient integration remain pending. Preview 0.2.1 identifies this build.

Preview 0.2.2 adds explicit success/failure banners and a New contact sheet. Successful creation closes and resets the sheet; failures retain entries for retry.

Preview 0.2.3 adds persistent phone/email fields for local contacts and live read-only phone/email details for native contacts, including search. Native-to-app refresh is wired; two-way writes remain unimplemented pending the contact conflict gate. Existing profile JSON loads without migration loss.

### Current native sync preview — 0.3.0

Supersedes the earlier read-only preview: reviewed native create/update is implemented for
single-source records. New contacts require an explicit account. Native name/phone/email/
birthday updates use three-way merge, per-field conflict choices, stale-review rejection,
and post-save verification. Mac changes refresh the source list. Private relationship and
notes remain local; app-only profiles can be linked after native creation. Uncertain saves
are not replayed, and partial annotation failures retry only local storage. Synthetic sync
checks pass; real-account/UI verification and the production conflict gate remain pending.
Apple's last-writer-wins API leaves an external-writer race; this is not atomic conflict safety.

### Shared contact recipients — 0.3.1

Assistant, Plan, and Contacts share the native contact connection. Assistant/Plan use a
searchable native recipient and explicit phone/email destination. Review binds the exact
recipient, rechecks the source, and rejects stale approval; changing or losing a destination
clears the old draft. Lock removes native recipient/draft data. Delivery remains disabled.
Nine core and thirteen integration check groups pass; live UI validation awaits user unlock.

### Plan confirmation — 0.3.2

Successful reviewed confirmation now adds an immutable session-only plan snapshot, shows a
success pop-up after review closes, and resets the composer. Failed confirmation preserves
inputs and does not append. Duplicate/expired confirmations are covered by automated checks.
Plans are not persisted or scheduled for delivery. Eleven core plus thirteen integration
check groups pass; the native alert transition remains pending on-device verification.

### Saved draft plans — 0.4.0

Confirmed plans now survive restart in a versioned AES-GCM store with a Keychain-held key.
Confirm persists before composer reset; cancellation persists; lock clears the loaded list.
Missing keys, corrupt ciphertext and unknown schemas fail closed without replacing existing
data. Older Python databases/jobs are not imported or activated. Thirty native check groups
pass; real Keychain access/upgrade, alert UI and cross-restart device verification are pending.
