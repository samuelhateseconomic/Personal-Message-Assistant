import json
import logging
import subprocess
from datetime import UTC, datetime
from pathlib import Path
from unittest.mock import patch

import pytest
from pydantic import ValidationError

from imsg_agent.config import load_config
from imsg_agent.logger import get_logger
from imsg_agent.messenger import Messenger, MessengerError
from imsg_agent.models import TOOL_ARG_MODELS, AppConfig, ContactList, ScheduledMessage

ROOT = Path(__file__).resolve().parents[1]


def test_templates_match_models():
    AppConfig.model_validate_json((ROOT / "config.json").read_text())
    assert (
        len(
            ContactList.model_validate_json(
                (ROOT / "tests/fixtures/contacts.example.json").read_text()
            ).contacts
        )
        == 2
    )
    assert len(TOOL_ARG_MODELS) == 11


def test_config_creation_and_existing_settings(tmp_path):
    path = tmp_path / "data/config.json"
    config = load_config(path)
    assert config.data_dir == str(path.parent)
    data = json.loads(path.read_text())
    data["max_retries"] = 7
    data["data_dir"] = "storage"
    path.write_text(json.dumps(data))
    before = path.read_text()
    assert load_config(path).max_retries == 7
    assert load_config(path).data_dir == str(path.parent / "storage")
    assert path.read_text() == before
    path.write_text('{"max_retries": -1}')
    with pytest.raises(ValidationError):
        load_config(path)
    assert path.read_text() == '{"max_retries": -1}'


def test_schedule_validation():
    kwargs = {"to": "+15550109999", "message": "Hi", "send_at": "2026-09-21T08:00:00-04:00"}
    item = ScheduledMessage(**kwargs)
    assert item.send_at == datetime(2026, 9, 21, 12, tzinfo=UTC)
    for field, value in [
        ("send_at", "2026-09-21T08:00:00"),
        ("cron", "invalid"),
        ("to", "not a phone"),
        ("timezone", "Invalid/Place"),
    ]:
        with pytest.raises(ValidationError):
            ScheduledMessage(**{**kwargs, field: value})


def test_dry_run_never_calls_subprocess():
    with patch("imsg_agent.messenger.subprocess.run") as run:
        assert Messenger(dry_run=True).send("+15550109999", "hello").status == "dry_run"
        run.assert_not_called()


def test_message_is_passed_as_data():
    text = 'Hello "friend"\\\nline 2; do shell script "bad"'
    with (
        patch("imsg_agent.messenger.platform.system", return_value="Darwin"),
        patch("imsg_agent.messenger.subprocess.run") as run,
    ):
        result = Messenger().send("+15550109999", text)
        args = run.call_args.args[0]
        assert args[-2:] == ["+15550109999", text]
        assert text not in args[2]
        assert result.status == "submitted"


def test_failure_does_not_trigger_duplicate_sms_send():
    with (
        patch("imsg_agent.messenger.platform.system", return_value="Darwin"),
        patch(
            "imsg_agent.messenger.subprocess.run",
            side_effect=[None, subprocess.TimeoutExpired("osascript", 30)],
        ) as run,
    ):
        with pytest.raises(MessengerError):
            Messenger().send("+15550109999", "hello")
        assert run.call_count == 2


@pytest.mark.parametrize(
    "to,text", [("Mom", "hello"), ("+15550109999", ""), ("+15550109999", "a\x00b")]
)
def test_invalid_send(to, text):
    with patch("imsg_agent.messenger.subprocess.run") as run:
        with pytest.raises(ValueError):
            Messenger().send(to, text)
        run.assert_not_called()


def test_logger_does_not_duplicate_handlers(tmp_path):
    path = tmp_path / "daemon.log"
    logger = get_logger("test.foundation", path)
    assert get_logger("test.foundation", path) is logger
    logger.info("One event")
    assert path.read_text().count("One event") == 1
    for handler in logger.handlers[:]:
        logger.removeHandler(handler)
        handler.close()
    logging.shutdown()


def test_relative_config_path(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    assert load_config("settings/config.json").data_dir == str(tmp_path / "settings")


def test_cli_contacts_and_missing_file(tmp_path):
    from typer.testing import CliRunner

    from imsg_agent.cli import app

    runner = CliRunner()
    result = runner.invoke(
        app,
        [
            "contacts",
            "--path",
            str(ROOT / "tests/fixtures/contacts.example.json"),
            "--group",
            "family",
        ],
    )
    assert result.exit_code == 0
    assert "Mom" in result.stdout
    assert "John Chen" not in result.stdout
    result = runner.invoke(app, ["contacts", "--path", str(tmp_path / "missing.json")])
    assert result.exit_code == 1
    assert "Cannot load contacts" in result.stdout


def test_messenger_startup_failure_is_safe_to_retry():
    from imsg_agent.messenger import MessengerUnavailable

    with (
        patch("imsg_agent.messenger.platform.system", return_value="Darwin"),
        patch(
            "imsg_agent.messenger.subprocess.run", side_effect=subprocess.TimeoutExpired("open", 30)
        ) as run,
    ):
        with pytest.raises(MessengerUnavailable):
            Messenger().send("+15550109999", "hello")
        run.assert_called_once()
        assert run.call_args.args[0][0] == "/usr/bin/open"
