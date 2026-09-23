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

        registry = ToolRegistry(
            manager,
            store,
            Messenger(),
            config.guardrails,
            confirm=confirm,
            dry_run=dry_run,
            timezone=timezone,
        )
        agent = Agent(OllamaBackend(config.ollama_model, config.ollama_host), registry)
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
