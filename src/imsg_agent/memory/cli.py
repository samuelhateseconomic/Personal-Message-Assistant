"""Explicit preference and opt-in feedback management."""

from contextlib import contextmanager
from pathlib import Path
from typing import Annotated

import typer
from rich.console import Console

from imsg_agent.config import load_config
from imsg_agent.contacts.manager import ContactManager
from imsg_agent.memory.models import PREFERENCE_VALUES
from imsg_agent.memory.service import MemoryService
from imsg_agent.store import Store

app = typer.Typer(no_args_is_help=True, help="Manage local, approved drafting preferences.")
console = Console()


@app.callback()
def options(
    ctx: typer.Context,
    config: Annotated[Path | None, typer.Option("--config")] = None,
    contacts: Annotated[Path | None, typer.Option("--contacts")] = None,
    dry_run: Annotated[bool, typer.Option("--dry-run")] = False,
):
    ctx.obj = {"config": config, "contacts": contacts, "dry_run": dry_run}


@contextmanager
def service(ctx):
    store = None
    try:
        config = load_config(ctx.obj["config"])
        source = ctx.obj["contacts"] or Path(config.data_dir) / "contacts.json"
        if source.exists():
            contacts = ContactManager(source)
        elif ctx.obj["contacts"]:
            raise ValueError("Selected contacts file does not exist")
        else:
            from types import SimpleNamespace

            # Global memory management does not require an address book.
            from imsg_agent.models import ResolveResult

            contacts = SimpleNamespace(
                contacts=[], resolve=lambda _: ResolveResult(status="not_found")
            )
        store = Store(Path(config.data_dir) / "imsg_agent.db")

        def confirm(summary):
            console.print(summary, markup=False)
            return typer.confirm("Approve this memory change?", default=False)

        yield MemoryService(
            store, contacts, confirm, ctx.obj["dry_run"] or config.guardrails.dry_run_mode
        )
    except (OSError, ValueError) as exc:
        console.print(f"Memory error: {exc}", markup=False)
        raise typer.Exit(1) from exc
    finally:
        if store:
            store.close()


@app.command("choices")
def choices():
    """Show supported preference keys and values."""
    console.print_json(data=PREFERENCE_VALUES)


@app.command("remember")
def remember(
    ctx: typer.Context,
    key: str,
    value: str,
    contact: Annotated[str | None, typer.Option("--contact")] = None,
):
    """Save a global preference or one for a uniquely resolved contact."""
    with service(ctx) as memory:
        console.print_json(data=memory.remember(key, value, contact))


@app.command("list")
def list_preferences(
    ctx: typer.Context, contact: Annotated[str | None, typer.Option("--contact")] = None
):
    """List all preferences, or only one contact's preferences."""
    with service(ctx) as memory:
        scope = memory.scope(contact)[0] if contact else None
        console.print_json(
            data=[
                {**row, "scope_label": memory.label(row["scope"])}
                for row in memory.repository.list(scope)
            ]
        )


@app.command("update")
def update(ctx: typer.Context, id: str, value: str):
    with service(ctx) as memory:
        console.print_json(data=memory.update(id, value))


@app.command("forget")
def forget(ctx: typer.Context, id: str):
    with service(ctx) as memory:
        console.print_json(data=memory.forget(id))


@app.command("feedback")
def feedback(
    ctx: typer.Context,
    original: Annotated[str, typer.Option("--original", prompt="Original draft")],
    corrected: Annotated[str, typer.Option("--corrected", prompt="Your correction")],
    contact: Annotated[str | None, typer.Option("--contact")] = None,
):
    """Opt in to saving a draft correction and review a proposed preference."""
    with service(ctx) as memory:
        console.print_json(data=memory.record_feedback(original, corrected, contact))


@app.command("feedback-list")
def feedback_list(ctx: typer.Context):
    with service(ctx) as memory:
        console.print_json(data=memory.repository.feedback())


@app.command("approve-feedback")
def approve_feedback(ctx: typer.Context, id: str):
    with service(ctx) as memory:
        console.print_json(data=memory.approve_feedback(id))


@app.command("forget-feedback")
def forget_feedback(ctx: typer.Context, id: str):
    with service(ctx) as memory:
        console.print_json(data=memory.forget_feedback(id))
