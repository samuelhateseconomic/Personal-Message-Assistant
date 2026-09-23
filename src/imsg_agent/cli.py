"""Local chat, configuration and contact commands."""

from pathlib import Path
from typing import Annotated

import typer
from pydantic import ValidationError
from rich.console import Console
from rich.table import Table

from imsg_agent.config import load_config
from imsg_agent.contacts.manager import ContactManager
from imsg_agent.memory.cli import app as memory_app

app = typer.Typer(
    no_args_is_help=True, help="Local iMessage scheduler — guarded chat and contact lookup."
)
console = Console()


@app.command("config")
def show_config(path: Annotated[Path | None, typer.Option("--path")] = None):
    """Show validated settings; create defaults if the config file is missing."""
    try:
        config = load_config(path)
    except (OSError, ValidationError) as exc:
        console.print(f"Configuration error: {exc}", markup=False)
        raise typer.Exit(1) from exc
    console.print_json(config.model_dump_json())


@app.command("contacts")
def list_contacts(
    path: Annotated[Path | None, typer.Option("--path")] = None,
    group: Annotated[str | None, typer.Option("--group")] = None,
):
    """List contacts from a file or the configured data directory."""
    try:
        source = path if path is not None else Path(load_config().data_dir) / "contacts.json"
        manager = ContactManager(source)
    except (OSError, ValidationError) as exc:
        console.print(
            f"Cannot load contacts: {exc}\nUse --path to select your contacts JSON.", markup=False
        )
        raise typer.Exit(1) from exc
    table = Table("Name", "Phone", "Groups")
    for contact in manager.get_group(group) if group else manager.contacts:
        from rich.text import Text

        table.add_row(Text(contact.name), Text(contact.phone), Text(", ".join(contact.group)))
    console.print(table)


@app.command("chat")
def chat(
    messages_db: Annotated[Path | None, typer.Option("--messages-db")] = None,
    path: Annotated[Path | None, typer.Option("--config")] = None,
    contacts_path: Annotated[Path | None, typer.Option("--contacts")] = None,
    dry_run: Annotated[bool, typer.Option("--dry-run")] = False,
    timezone: Annotated[str, typer.Option("--timezone")] = "America/Los_Angeles",
):
    """Chat with local Ollama; /quit exits and /reset clears conversation history."""
    from imsg_agent.agent.backend import OllamaBackend
    from imsg_agent.agent.orchestrator import Agent
    from imsg_agent.messenger import Messenger
    from imsg_agent.store import Store
    from imsg_agent.tools.registry import ToolRegistry

    store = None
    try:
        config = load_config(path)
        source = contacts_path or Path(config.data_dir) / "contacts.json"
        manager = ContactManager(source)
        store = Store(Path(config.data_dir) / "imsg_agent.db")

        def confirm(summary):
            console.print(summary, markup=False)
            return typer.confirm("Approve this exact action?", default=False)

        from imsg_agent.reader import MessageReader

        backend = OllamaBackend(config.ollama_model, config.ollama_host)
        registry = ToolRegistry(
            manager,
            store,
            Messenger(),
            config.guardrails,
            confirm=confirm,
            dry_run=dry_run,
            timezone=timezone,
            reader=MessageReader(messages_db),
            backend=backend,
        )
        agent = Agent(backend, registry)
        console.print(
            "Local chat. /quit to exit; /reset to clear. Approved schedules deliver while the daemon is running.",
            markup=False,
        )
        if registry.dry_run:
            console.print("Dry run: sends, schedules, and cancellations are previews only.")
        while True:
            text = typer.prompt("You").strip()
            if text == "/quit":
                break
            if text == "/reset":
                agent.reset()
                continue
            console.print(agent.process_input(text), markup=False)
    except (EOFError, KeyboardInterrupt):
        pass
    except (OSError, ValueError) as exc:
        console.print(f"Chat error: {exc}", markup=False)
        raise typer.Exit(1) from exc
    finally:
        if store:
            store.close()


def _direct_action(
    name, args, config_path=None, contacts_path=None, dry_run=False, timezone="America/Los_Angeles"
):
    from imsg_agent.messenger import Messenger
    from imsg_agent.store import Store
    from imsg_agent.tools.registry import ToolRegistry

    store = None
    try:
        config = load_config(config_path)
        source = contacts_path or Path(config.data_dir) / "contacts.json"
        if name in ("list_scheduled", "cancel_scheduled"):
            # These actions do not resolve recipients; an address book is not required.
            from types import SimpleNamespace

            manager = SimpleNamespace(contacts=[])
        else:
            manager = ContactManager(source)
        store = Store(Path(config.data_dir) / "imsg_agent.db")

        def confirm(summary):
            console.print(summary, markup=False)
            return typer.confirm("Approve this exact action?", default=False)

        registry = ToolRegistry(
            manager,
            store,
            Messenger(),
            config.guardrails,
            confirm=confirm,
            dry_run=dry_run,
            timezone=timezone,
        )
        result = registry.execute(name, args)
        console.print_json(data=result)
        if "error" in result or any(
            r.get("status") == "unknown_or_failed" for r in result.get("results", [])
        ):
            raise typer.Exit(1)
    except (OSError, ValueError) as exc:
        console.print(f"Command error: {exc}", markup=False)
        raise typer.Exit(1) from exc
    finally:
        if store:
            store.close()


@app.command("send")
def send_message(
    to: str,
    message: str,
    config: Annotated[Path | None, typer.Option("--config")] = None,
    contacts: Annotated[Path | None, typer.Option("--contacts")] = None,
    dry_run: Annotated[bool, typer.Option("--dry-run")] = False,
):
    """Submit a message after displaying and confirming its exact recipient and content."""
    _direct_action("send_message_now", {"to": to, "message": message}, config, contacts, dry_run)


@app.command("schedule")
def schedule_message(
    to: str,
    message: str,
    at: Annotated[str, typer.Option("--at")],
    cron: Annotated[str | None, typer.Option("--cron")] = None,
    config: Annotated[Path | None, typer.Option("--config")] = None,
    contacts: Annotated[Path | None, typer.Option("--contacts")] = None,
    timezone: Annotated[str, typer.Option("--timezone")] = "America/Los_Angeles",
    dry_run: Annotated[bool, typer.Option("--dry-run")] = False,
):
    """Approve automatic delivery at --at; optional cron repeats in the contact timezone."""
    _direct_action(
        "schedule_message",
        {"to": to, "message": message, "send_at": at, "cron": cron},
        config,
        contacts,
        dry_run,
        timezone,
    )


@app.command("list")
def list_schedules(
    status: Annotated[str | None, typer.Option("--status")] = None,
    config: Annotated[Path | None, typer.Option("--config")] = None,
):
    """List schedules, including failed submissions needing review."""
    _direct_action("list_scheduled", {"status": status}, config)


@app.command("cancel")
def cancel_schedule(
    id: str,
    config: Annotated[Path | None, typer.Option("--config")] = None,
    dry_run: Annotated[bool, typer.Option("--dry-run")] = False,
):
    """Cancel a pending schedule after confirmation."""
    _direct_action("cancel_scheduled", {"id": id}, config, dry_run=dry_run)


daemon_app = typer.Typer(no_args_is_help=True, help="Manage scheduled background delivery.")
app.add_typer(daemon_app, name="daemon")


def _daemon_command(action, config_path, foreground=False, dry_run=False):
    import subprocess

    from imsg_agent.daemon import Daemon, LaunchAgent, status

    try:
        path = config_path or Path.home() / ".imsg-agent/config.json"
        config = load_config(path)
        if action == "status":
            console.print_json(data=status(config))
        elif action == "start" and foreground:
            config.guardrails.dry_run_mode = config.guardrails.dry_run_mode or dry_run
            Daemon(config).run()
        else:
            if dry_run:
                raise ValueError(
                    "--dry-run requires --foreground; it does not change installed service settings"
                )
            manager = LaunchAgent(path, config.data_dir)
            console.print(getattr(manager, action)(), markup=False)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
        console.print(f"Daemon error: {exc}", markup=False)
        raise typer.Exit(1) from exc


@daemon_app.command("start")
def daemon_start(
    config: Annotated[Path | None, typer.Option("--config")] = None,
    foreground: Annotated[bool, typer.Option("--foreground")] = False,
    dry_run: Annotated[bool, typer.Option("--dry-run")] = False,
):
    """Run in foreground or start the installed launch agent."""
    _daemon_command("start", config, foreground, dry_run)


@daemon_app.command("stop")
def daemon_stop(config: Annotated[Path | None, typer.Option("--config")] = None):
    _daemon_command("stop", config)


@daemon_app.command("status")
def daemon_status(config: Annotated[Path | None, typer.Option("--config")] = None):
    _daemon_command("status", config)


@daemon_app.command("install")
def daemon_install(config: Annotated[Path | None, typer.Option("--config")] = None):
    """Install a login launch agent; start it now separately with daemon start."""
    _daemon_command("install", config)


@daemon_app.command("uninstall")
def daemon_uninstall(config: Annotated[Path | None, typer.Option("--config")] = None):
    _daemon_command("uninstall", config)


app.add_typer(memory_app, name="memory")


@app.command("history")
def message_history(
    contact: str,
    config: Annotated[Path | None, typer.Option("--config")] = None,
    contacts: Annotated[Path | None, typer.Option("--contacts")] = None,
    messages_db: Annotated[Path | None, typer.Option("--messages-db")] = None,
    limit: Annotated[int, typer.Option("--limit", min=1, max=100)] = 10,
):
    """Read a contact's recent direct messages; requires Messages database access."""
    _reply_command("history", contact, config, contacts, messages_db, limit)


@app.command("reply")
def suggest_reply(
    contact: str,
    instruction: Annotated[str, typer.Option("--instruction")] = "",
    language: Annotated[str | None, typer.Option("--language")] = None,
    config: Annotated[Path | None, typer.Option("--config")] = None,
    contacts: Annotated[Path | None, typer.Option("--contacts")] = None,
    messages_db: Annotated[Path | None, typer.Option("--messages-db")] = None,
    limit: Annotated[int, typer.Option("--limit", min=1, max=100)] = 10,
):
    """Suggest a reply using local history and preferences. Never sends a message."""
    _reply_command("reply", contact, config, contacts, messages_db, limit, instruction, language)


def _reply_command(
    action, contact, config_path, contacts_path, messages_db, limit, instruction="", language=None
):
    from imsg_agent.agent.backend import OllamaBackend
    from imsg_agent.memory.service import MemoryService
    from imsg_agent.models import SuggestReplyArgs
    from imsg_agent.reader import MessageReader
    from imsg_agent.store import Store
    from imsg_agent.tools.reply import handle_get_recent, handle_suggest_reply

    store = None
    try:
        config = load_config(config_path)
        contacts = ContactManager(contacts_path or Path(config.data_dir) / "contacts.json")
        reader = MessageReader(messages_db)
        args = SuggestReplyArgs(
            contact=contact,
            limit=limit,
            instruction=instruction,
            overrides={"language": language} if language else {},
        ).model_dump()
        if action == "history":
            result = handle_get_recent(args, reader, contacts)
        else:
            store = Store(Path(config.data_dir) / "imsg_agent.db")
            result = handle_suggest_reply(
                args,
                reader,
                contacts,
                OllamaBackend(config.ollama_model, config.ollama_host),
                MemoryService(store, contacts),
                config.guardrails.max_message_length,
            )
        console.print_json(data=result)
        if result.get("status") not in ("ok", "draft", "no_history"):
            raise typer.Exit(1)
    except (OSError, ValueError) as exc:
        console.print(f"Message history error: {exc}", markup=False)
        raise typer.Exit(1) from exc
    finally:
        if store:
            store.close()
