# 🦴 Project Skeleton — iMessage Scheduler Agent

This document maps every file in the project, its purpose, and its build phase.

## Implementation status — September 21, 2026

- Phase 1: models, config, logger, store, contacts manager, and messaging bridge implemented.
  Automated tests cover temporary storage and mocked sending; live macOS delivery is unverified.
- Phase 2: not implemented. Add a minimal `chat` CLI command here to satisfy its checkpoint.
- Phase 3: `config`, `contacts`, and the CLI entry point now work; scheduling, sending from
  the CLI, daemon management, and plist installation remain unimplemented.
- Phase 4: contact/store tests and shared fixtures implemented; `test_foundation.py` adds
  model, config, CLI, logger, and mocked messaging checks. Other test modules are placeholders.
- Contact reload is explicit, with no file watcher. Messaging supports explicit iMessage/SMS
  selection; automatic fallback after an uncertain submission is intentionally deferred.
- Additional files: `.gitignore`, `uv.lock`, and `tests/test_foundation.py`.

Next milestone: Phase 2 tool validation, guardrails, registry/handlers, Ollama integration,
and the bounded agent loop. Tests are added alongside implementation rather than deferred
until Phase 4. Scheduled execution will need atomic claims and explicit crash-recovery
semantics before multiple workers can safely deliver messages.

---

## Project Tree

```
messenger_assistant_mac/
├── pyproject.toml
├── README.md
├── skeleton.md                          ← You are here
├── contacts.json
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
    ├── conftest.py
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
| `contacts.json` | **Contact List Template** — Example contacts with groups, templates, metadata | Setup |
| `config.json` | **Default Configuration** — Guardrail settings, Ollama model, data directory | Setup |
| `com.imsg-agent.daemon.plist` | **launchd Config** — Auto-starts daemon on login, keeps alive on crash | Phase 3 |

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
| `reader.py` | **Message Reader** — Reads ~/Library/Messages/chat.db (read-only). For smart replies. Requires Full Disk Access. | 4 |
| `scheduler.py` | **Tick Scheduler** — 60-second polling loop. No setTimeout overflow. Handles sleep. Exponential backoff retry. | 3 |
| `cli.py` | **CLI Interface** — Typer + Rich. Commands: chat, send, schedule, list, cancel, reply, contacts, daemon, config. | 3 |
| `daemon.py` | **Background Daemon** — Tick scheduler + heartbeat. Signal handling. launchd managed. | 3 |

---

### Agent Module — `src/imsg_agent/agent/`

| File | Headline | Phase |
|---|---|---|
| `__init__.py` | **Agent Package Init** | 2 |
| `orchestrator.py` | **Agent Orchestrator** — Core AI loop: user input → Ollama → validate → guardrail → confirm → execute → respond. Max 5 tool iterations. Context capped at 10 messages. | 2 |
| `backend.py` | **Ollama Backend** — SDK wrapper: chat(), is_available(), ensure_model_pulled() | 2 |
| `prompts.py` | **System Prompt Builder** — Dynamic prompt with current time, contact summary, pending count, rules. Contacts NOT injected (lazy via tool). | 2 |
| `validator.py` | **Tool-Call Validator** — Pydantic schema enforcement. Auto-repairs: misspelled fields (rapidfuzz), NL dates (dateparser), type coercion. | 2 |
| `fallback.py` | **Regex Fallback Parser** — Catches common command patterns when model fails (~15-20% with 12B). 6 regex patterns validated through Pydantic. | 2 |

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
| `manager.py` | **Contact Manager** — Resolves names → phones. Pipeline: exact → alias → phone → fuzzy (rapidfuzz ≥70). Groups, templates, summary. | 1 |

---

### Tools Module — `src/imsg_agent/tools/`

| File | Headline | Phase |
|---|---|---|
| `__init__.py` | **Tools Package Init** | 2 |
| `registry.py` | **Tool Registry** — Register handlers, get Ollama schemas, dispatch tool calls. | 2 |
| `schemas.py` | **Tool Schemas** — 8 tool definitions in Ollama JSON format: send, schedule, cancel, list, resolve, list_contacts, get_recent, suggest_reply. | 2 |
| `send.py` | **Send Handler** — send_message_now: resolve contact → messenger.send() | 2 |
| `schedule.py` | **Schedule Handler** — schedule_message: resolve contact → parse time → store.add(). Supports group: and template: prefixes. | 2 |
| `manage.py` | **Manage Handlers** — list_scheduled: query store. cancel_scheduled: update status. | 2 |
| `contacts.py` | **Contact Handlers** — resolve_contact: fuzzy lookup. list_contacts: filter by group. | 2 |
| `reply.py` | **Reply Handlers** — get_recent_messages: read chat.db. suggest_reply: read + Ollama generate. Data never leaves machine. | 4 |

---

### Tests — `tests/`

| File | Headline | Phase |
|---|---|---|
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
| **3** | Scheduler + CLI + Daemon | scheduler, cli, daemon, __main__, plist | Schedule → daemon fires → message sent |
| **4** | Smart Replies + Tests | reader, tools/reply, tests/* | Smart replies work. All tests pass. |
