import json
from pathlib import Path
from unittest.mock import Mock

from typer.testing import CliRunner

from imsg_agent.cli import app
from imsg_agent.store import Store


def test_cli_schedule_list_cancel_and_send_preview(tmp_path, monkeypatch):
    monkeypatch.setattr(
        "imsg_agent.messenger.Messenger.send", Mock(side_effect=AssertionError("No live sends"))
    )
    config = tmp_path / "config.json"
    config.write_text(json.dumps({"data_dir": str(tmp_path)}))
    contacts = Path(__file__).parent / "fixtures/contacts.example.json"
    runner = CliRunner()
    options = ["--config", str(config), "--contacts", str(contacts)]
    result = runner.invoke(app, ["send", "Mom", "hello", *options, "--dry-run"])
    assert result.exit_code == 0, result.output
    assert "dry_run" in result.output
    result = runner.invoke(
        app, ["schedule", "Mom", "hello", "--at", "2099-01-01T12:00:00Z", *options], input="y\n"
    )
    assert result.exit_code == 0, result.output
    assert "automatic delivery" in result.output
    store = Store(tmp_path / "imsg_agent.db")
    item = store.get_pending()[0]
    assert item.delivery_approved
    result = runner.invoke(app, ["list", "--config", str(config)])
    assert result.exit_code == 0 and item.id in result.output
    result = runner.invoke(app, ["cancel", item.id, "--config", str(config)], input="y\n")
    assert result.exit_code == 0, result.output
    assert store.get_by_id(item.id).status == "cancelled"
    store.close()


def test_daemon_status_has_no_start_side_effect(tmp_path, monkeypatch):
    runner = Mock(side_effect=AssertionError("Must not call launchctl"))
    monkeypatch.setattr("imsg_agent.daemon.subprocess.run", runner)
    config = tmp_path / "config.json"
    config.write_text(json.dumps({"data_dir": str(tmp_path)}))
    result = CliRunner().invoke(app, ["daemon", "status", "--config", str(config)])
    assert result.exit_code == 0 and "false" in result.output
