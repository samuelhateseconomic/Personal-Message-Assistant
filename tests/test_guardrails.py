from datetime import UTC, datetime, timedelta
from unittest.mock import Mock

import pytest

from imsg_agent.models import GuardrailConfig, SendResult
from imsg_agent.tools.registry import ToolRegistry

NOW = datetime(2026, 9, 22, 19, tzinfo=UTC)


@pytest.fixture
def registry(mock_contacts, tmp_db):
    messenger = Mock(dry_run=False)
    messenger.send.return_value = SendResult(status="submitted", service="iMessage")
    return ToolRegistry(
        mock_contacts,
        tmp_db,
        messenger,
        GuardrailConfig(),
        confirm=Mock(return_value=True),
        now=lambda: NOW,
    )


def test_send_confirms_exact_template_and_logs(registry):
    result = registry.execute("send_message_now", {"to": "Ma", "message": "template:morning"})
    assert result["results"][0]["status"] == "submitted"
    summary = registry.confirm.call_args.args[0]
    assert "+15550109999" in summary and "Good morning!" in summary
    registry.messenger.send.assert_called_once_with(
        "+15550109999", "Good morning!", service="iMessage"
    )
    assert registry.store.count_sends_last_hour() == 1


def test_reject_ambiguous_and_invalid(registry):
    for to in ("John", "+12", "Nobodyzzzz"):
        assert "error" in registry.execute("send_message_now", {"to": to, "message": "hi"})
    registry.confirm.assert_not_called()
    registry.messenger.send.assert_not_called()


def test_decline_and_disabled_config_still_confirm(registry):
    registry.config.require_confirmation = False
    registry.confirm.return_value = False
    assert (
        registry.execute("send_message_now", {"to": "Mom", "message": "hi"})["status"]
        == "cancelled"
    )
    registry.confirm.assert_called_once()
    registry.messenger.send.assert_not_called()


def test_content_and_time_blocks(registry):
    for text in (" ", "x" * 2001, "x\x00y"):
        assert "error" in registry.execute("send_message_now", {"to": "Mom", "message": text})
    assert "error" in registry.execute(
        "schedule_message",
        {"to": "Mom", "message": "hi", "send_at": (NOW - timedelta(days=1)).isoformat()},
    )
    registry.confirm.assert_not_called()


def test_rate_limit_and_warnings(registry):
    registry.config.max_messages_per_hour = 1
    registry.store.log_send("+15550109999", "hi", success=True, sent_at=NOW)
    assert "error" in registry.execute("send_message_now", {"to": "Mom", "message": "hi"})
    registry.config.max_messages_per_hour = 20
    registry.config.max_messages_per_contact_per_hour = 1
    plan = registry._prepare("send_message_now", {"to": "Mom", "message": "hi"})
    gate = registry.guardian.validate("send_message_now", plan)
    warnings = {r.rule for r in gate.results if r.decision == "warn"}
    assert {"PerContactRateLimit", "DuplicateDetection", "ConfirmationGate"} <= warnings


def test_blackout_batch_and_invalid_phone(registry):
    plan = registry._prepare(
        "schedule_message", {"to": "Mom", "message": "hi", "send_at": "2026-09-24T06:00:00+00:00"}
    )
    plan["items"] *= 11
    gate = registry.guardian.validate("schedule_message", plan)
    warnings = {r.rule for r in gate.results if r.decision == "warn"}
    assert {"BlackoutHours", "BatchSizeLimit"} <= warnings
    plan["items"][0]["to"] = "invalid"
    assert registry.guardian.validate("send_message_now", plan).decision == "block"


def test_dry_run_all_mutations(registry):
    registry.dry_run = True
    assert (
        registry.execute("send_message_now", {"to": "Mom", "message": "hi"})["status"] == "dry_run"
    )
    assert (
        registry.execute(
            "schedule_message",
            {"to": "Mom", "message": "hi", "send_at": (NOW + timedelta(days=1)).isoformat()},
        )["status"]
        == "dry_run"
    )
    assert registry.store.get_pending() == []
    registry.messenger.send.assert_not_called()
    registry.confirm.assert_not_called()


def test_schedule_and_cancel(registry):
    result = registry.execute(
        "schedule_message",
        {
            "to": "group:family",
            "message": "template:morning",
            "send_at": (NOW + timedelta(days=1)).isoformat(),
            "cron": "0 8 * * *",
        },
    )
    item = registry.store.get_by_id(result["ids"][0])
    assert item.message == "Good morning!" and item.cron == "0 8 * * *"
    registry.dry_run = True
    assert registry.execute("cancel_scheduled", {"id": item.id})["status"] == "dry_run"
    assert registry.store.get_by_id(item.id).status == "pending"
    registry.dry_run = False
    assert registry.execute("cancel_scheduled", {"id": item.id})["status"] == "cancelled"
    assert "error" in registry.execute("cancel_scheduled", {"id": item.id})


def test_group_missing_template_does_not_partially_write(registry):
    registry.contacts.contacts[1].group.append("family")
    result = registry.execute(
        "schedule_message",
        {
            "to": "group:family",
            "message": "template:morning",
            "send_at": (NOW + timedelta(days=1)).isoformat(),
        },
    )
    assert "error" in result
    assert registry.store.get_pending() == []


def test_evidence_gate(registry):
    result = registry.execute("resolve_contact", {"query": "Mom"})
    assert result["sources"] == ["contacts.json#/contacts/0"]
    assert result["contact"]["name"] == "Mom"
    assert registry.execute("resolve_contact", {"query": "John"})["needs_clarification"]
    assert registry.execute("resolve_contact", {"query": "+442079460123"})["sources"] == []


def test_send_failure_is_not_retried(registry):
    from imsg_agent.messenger import MessengerError

    registry.messenger.send.side_effect = MessengerError("Unknown outcome")
    result = registry.execute("send_message_now", {"to": "Mom", "message": "hi"})
    assert result["results"][0]["status"] == "unknown_or_failed"
    registry.messenger.send.assert_called_once()
    assert registry.store.count_sends_last_hour() == 0


def test_time_rechecked_after_confirmation(registry):
    def confirm(_):
        registry.guardian.now = lambda: NOW + timedelta(days=2)
        return True

    registry.confirm = confirm
    result = registry.execute(
        "schedule_message",
        {"to": "Mom", "message": "hi", "send_at": (NOW + timedelta(days=1)).isoformat()},
    )
    assert "error" in result
    assert registry.store.get_pending() == []
