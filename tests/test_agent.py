import json
from unittest.mock import Mock

import pytest

from imsg_agent.agent.backend import BackendUnavailable, OllamaBackend
from imsg_agent.agent.orchestrator import Agent
from imsg_agent.models import GuardrailConfig
from imsg_agent.tools.registry import ToolRegistry


@pytest.fixture
def agent(mock_contacts, tmp_db):
    registry = ToolRegistry(
        mock_contacts, tmp_db, Mock(dry_run=False), GuardrailConfig(), dry_run=True
    )
    return Agent(Mock(), registry)


def test_read_then_mutation_ends_turn(agent):
    agent.backend.chat.side_effect = [
        {"tool_calls": [{"name": "resolve_contact", "arguments": {"query": "Mom"}}]},
        {"tool_calls": [{"name": "send_message_now", "arguments": {"to": "Mom", "message": "hi"}}]},
    ]
    result = json.loads(agent.process_input("Send hi to Mom"))
    assert result["status"] == "dry_run"
    assert agent.backend.chat.call_count == 2
    agent.registry.messenger.send.assert_not_called()


def test_unavailable_model_fallback(agent):
    agent.backend.chat.side_effect = BackendUnavailable()
    assert json.loads(agent.process_input('send "hi" to Mom'))["status"] == "dry_run"
    assert "unavailable" in agent.process_input("what is the weather?")


def test_max_iterations(agent):
    agent.backend.chat.return_value = {"tool_calls": [{"name": "list_scheduled", "arguments": {}}]}
    assert "five-step" in agent.process_input("list schedules")
    assert agent.backend.chat.call_count == 5


def test_history_reset(agent):
    agent.backend.chat.return_value = {"content": "Hello", "tool_calls": []}
    for _ in range(8):
        agent.process_input("hello")
    assert len(agent.history) == 10
    assert agent.history[0]["role"] == "user"
    agent.reset()
    assert not agent.history


def test_multiple_mutations_rejected(agent):
    agent.backend.chat.return_value = {
        "tool_calls": [{"name": "send_message_now", "arguments": {"to": "Mom", "message": "hi"}}]
        * 2
    }
    assert "No action" in agent.process_input("send hi to Mom")
    agent.registry.messenger.send.assert_not_called()


@pytest.mark.parametrize(
    "host",
    [
        "https://example.com",
        "http://192.168.1.2:11434",
        "http://localhost.evil.com",
        "http://user:pass@localhost",
    ],
)
def test_backend_rejects_remote_hosts(host):
    with pytest.raises(ValueError):
        OllamaBackend(host=host)


def test_backend_structured_json(agent):
    client = Mock()
    client.chat.return_value.message.content = '{"content":"hello", "tool_calls":[]}'
    backend = OllamaBackend(client=client)
    messages = [{"role": "system", "content": "test"}]
    assert backend.chat(messages, agent.registry.get_schemas())["content"] == "hello"
    assert "format" in client.chat.call_args.kwargs
    assert messages[0]["content"] == "test"


def test_backend_timeout_and_malformed_response(agent):
    import httpx

    client = Mock()
    backend = OllamaBackend(client=client)
    client.chat.side_effect = httpx.ReadTimeout("timeout")
    with pytest.raises(BackendUnavailable):
        backend.chat([{"role": "system", "content": "test"}], agent.registry.get_schemas())
    client.chat.side_effect = None
    client.chat.return_value.message.content = "[]"
    with pytest.raises(BackendUnavailable):
        backend.chat([{"role": "system", "content": "test"}], agent.registry.get_schemas())


def test_invalid_tool_name_is_not_executed(agent):
    agent.backend.chat.return_value = {"tool_calls": [{"name": [], "arguments": {}}]}
    assert "five-step" in agent.process_input("Hello")
    agent.registry.messenger.send.assert_not_called()


def test_cli_chat_dry_run(tmp_path, monkeypatch):
    from pathlib import Path

    from typer.testing import CliRunner

    from imsg_agent.cli import app
    from imsg_agent.store import Store

    monkeypatch.setattr(OllamaBackend, "chat", Mock(side_effect=BackendUnavailable()))
    monkeypatch.setattr(
        "imsg_agent.messenger.Messenger.send", Mock(side_effect=AssertionError("Must not send"))
    )
    path = tmp_path / "config.json"
    path.write_text(json.dumps({"data_dir": str(tmp_path)}))
    contacts = Path(__file__).parent / "fixtures/contacts.example.json"
    result = CliRunner().invoke(
        app,
        ["chat", "--config", str(path), "--contacts", str(contacts), "--dry-run"],
        input='send "hello" to Mom\n/quit\n',
    )
    assert result.exit_code == 0, result.output
    assert "dry_run" in result.output
    store = Store(tmp_path / "imsg_agent.db")
    assert store.get_pending() == []
    assert store.count_sends_last_hour() == 0
    store.close()
