# 📬 iMessage Scheduler Agent

**AI-powered iMessage & SMS scheduling for macOS — 100% local, privacy-first.**

Planned: schedule messages with natural language using local Ollama inference.
Message delivery still uses Apple's messaging services and, for SMS, your carrier.

## Development status — September 21, 2026

Phase 1 foundation is implemented: validated models, configuration loading, rotating
logging, SQLite persistence, contact resolution, and a dry-run-capable messaging
bridge. The CLI currently provides `config` and `contacts` only. AI chat,
scheduling, guardrails, smart replies, and daemon operation remain planned.

Foundation tests use temporary data and mocked subprocesses; no real messages have
been sent or delivery verified. The bridge supports explicit iMessage or SMS selection;
automatic SMS fallback is deferred to avoid duplicate sends after uncertain failures.
Contacts support explicit `reload()`; automatic file watching is not implemented.

---

## Planned Features

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

Ollama and the model will be needed for Phase 2; the foundation commands do not need them.

### 3. Configure Contacts

The root `contacts.json` contains examples. You can inspect it with `--path` below.
For your own contacts, copy and edit it in the data directory shown by `imsg config`.

### 4. Run

```bash
# Inspect the sample contacts without sending messages
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
│  │(60s tick)│  │(osascript)│  │  (WAL mode)   │ │
│  └──────────┘  └───────────┘  └───────────────┘ │
├──────────────────────────────────────────────────┤
│              macOS Messages.app                   │
└──────────────────────────────────────────────────┘
```

---

## Planned CLI Reference

Only `contacts` and `config` are currently implemented. Both also accept `--path`.
The following table describes the full target interface.

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
