# 📬 iMessage Scheduler Agent

**AI-powered iMessage & SMS scheduling for macOS — 100% local, privacy-first.**

Planned: schedule messages with natural language using local Ollama inference.
Message delivery still uses Apple's messaging services and, for SMS, your carrier.

## Development status — Phase 3 + approved memory

Implemented: foundation storage and contacts, structured contact retrieval with source
references, tool argument validation, nine guardrails, local Ollama orchestration,
regex fallback commands, and all CLI commands except smart replies. Phase 3 adds persistent delivery claims,
cron recurrence, conservative retries, a foreground worker, and launchd management.

Chat can submit a message, store a schedule, or cancel a pending schedule after
showing the exact action and requesting confirmation. Confirmation remains mandatory
for chat mutations even if `require_confirmation` is false. `--dry-run` previews all
mutations without sending, creating schedules, or cancelling them; audit records may
still be written. Both CLI processes must use the same database for the send-rate lock
and shared history to apply.

**Approved schedules deliver when the daemon is running.** Smart replies, Messages
history reading, document embeddings, and relevance-based retrieval gating remain
future work. Contact retrieval currently checks identity,
returns stored fields with source references, and asks for clarification on ambiguity;
it does not verify every model-generated statement or citation.

Automated checks use temporary data and mocked messaging/model calls. Real message
delivery, a live Ollama conversation, and installed launchd operation have not been
verified. No live daemon has been installed or started during development. The messaging bridge
supports explicit iMessage/SMS selection; it does not retry uncertain iMessage sends
as SMS. Contact reload remains explicit.

### Approved preference memory

The agent can remember approved drafting preferences across sessions. This uses local
SQLite memory, not model retraining. Supported keys are `language`, `tone`, `length`,
`emoji`, and `formality`; `imsg memory choices` lists their allowed values. There is
no background learning from messages or automatic collection of draft edits.

```bash
# Review supported values without writing memory
uv run imsg memory choices

# Save only after reviewing and confirming the exact proposed preference
uv run imsg memory --contacts contacts.json remember language Vietnamese --contact Mom
uv run imsg memory --contacts contacts.json remember length short --contact Mom

# Global preference (omit --contact), or list all saved preferences
uv run imsg memory remember tone warm
uv run imsg memory --contacts contacts.json list

# Use the ID returned by list; replacement and deletion require confirmation
uv run imsg memory --contacts contacts.json update pref-<id> medium
uv run imsg memory --contacts contacts.json forget pref-<id>

# Prompt for an original draft and correction, then confirm saving them locally
uv run imsg memory --contacts contacts.json feedback --contact Mom
uv run imsg memory feedback-list
uv run imsg memory --contacts contacts.json approve-feedback feedback-<id>
uv run imsg memory forget-feedback feedback-<id>
```

`memory` options (`--config`, `--contacts`, `--dry-run`) go **before its subcommand**.
Chat also exposes confirmed `remember_preference` and `forget_preference` tools, and
retrieves preferences through `get_preferences` and resolved-contact results. A local
model is needed for natural-language memory requests; the memory CLI does not need it.

Current-request overrides take precedence over contact preferences, then global
preferences. Overrides are not saved. Conflicting replacements display both old and
new values and require approval. Preferences are only drafting data: they cannot
change tool permissions, schedule delivery, or disable sending confirmations.

Feedback storage and preference approval are separate actions. The initial deterministic
proposal rule suggests `length=short` only when an original has at least eight words and
the correction has at most 60% as many words. Other corrections can be stored without
proposing a preference. Examples are not automatically included in model prompts.
The heuristic is not proof of a lasting preference; you decide whether to approve it.

Each preference has an ID, scope, source, timestamps, and approval state. Personal
contacts have persistent `contact-...` IDs; retain these IDs when renaming or changing
numbers. Legacy contacts without IDs use a phone-derived identity and cannot safely
share memory if multiple entries share that identity. Unknown and ambiguous contacts
require clarification before memory can be saved or retrieved.

Forgetting removes the active preference and linked feedback, including pending examples
for that preference slot. It is ordinary database deletion, not secure erasure of disk
pages, backups, or past send logs. Memory changes clear old in-process chat context on
the next request so deleted preferences are not carried forward from previous turns.
`/reset` clears conversation context only; use `memory forget` for persistent preferences.

Memory remains in the configured local `imsg_agent.db`, outside Git. Tests cover memory
persistence, scope isolation, override precedence, conflicts, consent, deletion, concurrent
edits, and tool integration. Live model adherence to drafting preferences is unverified.

### Scheduling and background delivery

```bash
# Preview a schedule without saving it
uv run imsg schedule Mom "Good morning" --at "tomorrow 8am" --contacts contacts.json --dry-run

# Save it after confirming the exact plan and automatic-delivery policy
uv run imsg schedule Mom "Good morning" --at "tomorrow 8am" --contacts contacts.json
uv run imsg list --status pending
uv run imsg cancel msg-<schedule-id>

# Inspect due work without sending or changing schedule states (Ctrl-C exits)
uv run imsg daemon start --foreground --dry-run
uv run imsg daemon status

# These commands enable real unattended delivery of approved schedules:
uv run imsg daemon install
uv run imsg daemon start
uv run imsg daemon stop
uv run imsg daemon uninstall
```

Use `--config /absolute/path/config.json` consistently on commands when using a custom
configuration. `daemon install` writes a launch agent for the current Python environment
and configuration; it enables login startup but does not start the service immediately.
`daemon start` loads it now. The root plist is a reference template; installation generates
actual absolute paths rather than loading its placeholders. `stop` is asynchronous; check
`daemon status` to confirm shutdown. Uninstallation preserves schedules and logs.

Delivery behavior:

- `--at` sets the first occurrence. `--timezone` controls parsing of times without an
  offset. `--cron` sets subsequent occurrences in the **contact timezone shown in the
  confirmation**, which may differ from the parsing timezone.
- After sleep or downtime, a recurring schedule submits at most one overdue occurrence,
  then advances past missed repeats. Spring-forward nonexistent times are skipped;
  fall-back repeated times run only at the first occurrence.
- Quiet hours, global/per-contact rate limits, and duplicate warnings defer unattended
  delivery for another check in 60 seconds. Invalid content fails the schedule.
- A durable `sending` claim precedes submission. A crash or uncertain result stops the
  schedule for review; exactly-once delivery cannot be guaranteed by AppleScript.
  Here `sent` means submitted to Messages.app, not confirmed receipt by the recipient.
- Failures known to precede submission retry after 30, 60, and 120 seconds by default.
  Retries survive restarts. The worker wakes once per second; actual timing also depends
  on macOS sleep and any other in-flight work.
- Schedules saved before Phase 3 lack background-delivery approval and are marked failed
  rather than sent. Recreate them through the confirmation flow if you want delivery.
- A dry-run worker never claims, sends, reschedules, recovers, or cancels jobs, but it
  writes daemon logs and heartbeat information. It cannot run alongside another worker
  for the same data directory.

### Personal contacts and Git

`contacts.json` is local and ignored by Git. `contacts.example.json` contains only
sample contacts and can be copied for a new installation. The import review report,
databases, and database lock files are also ignored. Tests use synthetic contacts.
The previous Git commit contains only the original sample contacts.

### Try guarded chat

```bash
# Uses the project's contacts and previews actions without sending
uv run imsg chat --contacts contacts.json --dry-run

# Optional local model setup for natural-language requests
ollama pull gemma3:12b
```

Run Ollama locally for AI chat. Without an available model, these explicit commands
still work through the same validation and guardrail path:

```text
send "hello" to Mom
schedule "hello" to Mom at tomorrow 8am
list pending
cancel msg-<schedule-id>
```

Use `/quit` to exit or `/reset` to clear conversation history. `--timezone` selects
the timezone for dates without an offset (default: America/Los_Angeles). Ambiguous
or nonexistent daylight-saving times require an explicit offset. Imported contacts'
unknown timezone/service defaults are identified in the confirmation preview.


---

## Features and Roadmap

- 🗣️ **Natural Language** — `"Text Mom happy birthday tomorrow at 8am"`
- 📅 **Scheduled Delivery** — One-time or recurring (cron) schedules
- 🔁 **Smart Replies** — Read recent messages, get AI-suggested replies
- 👥 **Groups & Batches** — Send to contact groups in one command
- 📝 **Message Templates** — Pre-defined messages per contact
- 🛡️ **Guardrails** — Rate limiting, blackout hours, duplicate detection, confirmation gates
- 🔒 **Local AI** — Planned on-device inference through Ollama; delivery uses messaging services.
- 🔄 **Background Daemon** — Auto-starts on login, survives reboots

---

## Quick Start

### 1. Install Development Prerequisites

```bash
brew install python uv
```

### 2. Set Up Project

```bash
cd ~/Desktop/messenger_assistant_mac
uv venv
uv pip install -e ".[dev]"
```

Ollama is needed for AI interpretation; config, contacts, and explicit fallback commands do not need a running model.

### 3. Configure Contacts

The tracked `contacts.example.json` contains examples; your local `contacts.json` holds your imported contacts.
For your own contacts, copy and edit it in the data directory shown by `imsg config`.

### 4. Run

```bash
# Inspect local contacts without sending messages
uv run imsg contacts --path contacts.json
uv run imsg contacts --path contacts.json --group family

# Read the example configuration without changing it
uv run imsg config --path config.json

# Create default configuration in ~/.imsg-agent/ if missing
uv run imsg config
```

---

## Architecture

```
┌──────────────────────────────────────────────────┐
│                    CLI (typer + rich)             │
├──────────────────────────────────────────────────┤
│              Agent Orchestrator                   │
│   ┌───────────┐  ┌───────────┐  ┌─────────────┐ │
│   │  Ollama   │  │ Pydantic  │  │   Regex     │ │
│   │ Backend   │  │ Validator │  │  Fallback   │ │
│   └───────────┘  └───────────┘  └─────────────┘ │
├──────────────────────────────────────────────────┤
│         Guardian Middleware (9 rules)             │
├──────────────────────────────────────────────────┤
│  ┌──────────┐  ┌───────────┐  ┌───────────────┐ │
│  │Scheduler │  │ Messenger │  │ SQLite Store  │ │
│  │(1s tick) │  │(osascript)│  │  (WAL mode)   │ │
│  └──────────┘  └───────────┘  └───────────────┘ │
├──────────────────────────────────────────────────┤
│              macOS Messages.app                   │
└──────────────────────────────────────────────────┘
```

---

## CLI Reference

All commands below are implemented except `reply`, which is planned for Phase 4.
`contacts` and `config` also accept `--path`. Mutation commands accept `--dry-run`;
`chat`, send/schedule/list/cancel, and daemon commands accept `--config`.

| Command | Description |
|---|---|
| `imsg chat [--dry-run]` | Interactive AI chat mode |
| `imsg send <to> <msg>` | Send immediately |
| `imsg schedule <to> <msg> --at <time> [--cron <expr>]` | Schedule delivery |
| `imsg list [--status ...]` | List schedules |
| `imsg cancel <id>` | Cancel a schedule |
| `imsg reply <contact>` | Smart reply |
| `imsg contacts [--group <name>]` | List contacts |
| `imsg daemon start\|stop\|status\|install\|uninstall` | Manage daemon |
| `imsg config` | Show config |

---

## Permissions

On first run, macOS will prompt for:

1. **Automation** — Allow Terminal to control Messages.app
2. **Full Disk Access** *(smart replies only)* — Allow reading chat.db

---

## Development

### Run Tests

```bash
uv run pytest tests/ -v --cov=imsg_agent
```

### Debug in VS Code

Open this folder in VS Code. Recommended extensions will be suggested.
Use the debug configurations in `.vscode/launch.json`:

- **Debug: imsg chat** — Step through the agent loop
- **Debug: imsg daemon** — Debug the background daemon
- **Debug: pytest** — Debug test failures

### Lint & Format

```bash
uv run ruff check src/
uv run ruff format src/
```

---

## Data Storage

All data lives at `~/.imsg-agent/`:

| File | Purpose |
|---|---|
| `config.json` | Guardrail settings, model config |
| `contacts.json` | Your contact list |
| `imsg_agent.db` | SQLite: schedules, send log, audit log, heartbeat |
| `daemon.log` | Daemon output |

---

## License

MIT
