"""Readiness checks never need live private data or delivery integrations."""

from pathlib import Path
from types import SimpleNamespace

import pytest
from typer.testing import CliRunner

from imsg_agent.cli import app
from imsg_agent.config import load_config
from imsg_agent.diagnostics import check_readiness
from imsg_agent.models import AppConfig
from imsg_agent.reader import MessageReaderError

FIXTURE = Path(__file__).parent / "fixtures/contacts.example.json"


@pytest.fixture
def dependencies(monkeypatch):
    monkeypatch.setattr("imsg_agent.diagnostics.MessageReader.check_schema", lambda self: None)
    monkeypatch.setattr(
        "imsg_agent.diagnostics.MessageReader.get_recent_messages",
        lambda *a: pytest.fail("Diagnostics must never read message rows"),
    )
    client = SimpleNamespace(
        list=lambda: SimpleNamespace(models=[SimpleNamespace(model="gemma3:12b")])
    )
    monkeypatch.setattr("imsg_agent.agent.backend.ollama.Client", lambda **kw: client)
    return client


def test_ready_without_writing_configuration_or_data(tmp_path, dependencies):
    config_path = tmp_path / "missing/config.json"
    result = CliRunner().invoke(
        app, ["doctor", "--config", str(config_path), "--contacts", str(FIXTURE)]
    )
    assert result.exit_code == 0, result.output
    assert '"ready": true' in result.output
    assert not config_path.parent.exists()


def test_missing_model_and_default_tag(dependencies):
    assert not check_readiness(AppConfig(ollama_model="absent"), FIXTURE)["ready"]
    dependencies.list = lambda: SimpleNamespace(models=[SimpleNamespace(model="gemma3:latest")])
    assert check_readiness(AppConfig(ollama_model="gemma3"), FIXTURE)["ready"]


def test_independent_failures_and_no_private_error_details(tmp_path, monkeypatch, dependencies):
    def denied(self):
        raise MessageReaderError("Full Disk Access required")

    def stopped():
        raise ConnectionError("connection refused")

    monkeypatch.setattr("imsg_agent.diagnostics.MessageReader.check_schema", denied)
    dependencies.list = stopped
    contacts = tmp_path / "bad.json"
    contacts.write_text('{"contacts":[{"name":"PRIVATE NAME","phone":"invalid"}]}')
    result = check_readiness(AppConfig(), contacts)
    assert not result["ready"]
    assert len(result["checks"]) == 3
    assert all(not check["ok"] for check in result["checks"])
    assert "PRIVATE NAME" not in str(result)


def test_remote_host_is_rejected_before_network(dependencies):
    dependencies.list = lambda: pytest.fail("Remote host must never be contacted")
    result = check_readiness(AppConfig(ollama_host="https://example.test"), FIXTURE)
    assert not result["ready"]
    assert result["checks"][-1]["check"] == "ollama"


def test_cli_reports_bad_config_without_echoing_contents(tmp_path):
    config = tmp_path / "config.json"
    config.write_text("PRIVATE invalid config")
    result = CliRunner().invoke(app, ["doctor", "--config", str(config)])
    assert result.exit_code == 1
    assert "PRIVATE" not in result.output


def test_read_only_config_resolves_relative_data_dir(tmp_path):
    config = tmp_path / "config.json"
    config.write_text('{"data_dir":"data"}')
    assert load_config(config, create=False).data_dir == str(tmp_path / "data")
    assert not (tmp_path / "data").exists()
