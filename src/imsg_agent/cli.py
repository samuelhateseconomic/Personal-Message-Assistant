"""Foundation CLI. Chat, delivery and daemon commands arrive in later phases."""

from pathlib import Path
from typing import Annotated

import typer
from pydantic import ValidationError
from rich.console import Console
from rich.table import Table

from imsg_agent.config import load_config
from imsg_agent.contacts.manager import ContactManager

app = typer.Typer(no_args_is_help=True, help="Local iMessage scheduler — Phase 1 foundation.")
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
