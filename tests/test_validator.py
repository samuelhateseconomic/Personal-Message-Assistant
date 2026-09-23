from datetime import UTC, datetime

import pytest

from imsg_agent.agent.validator import ToolCallValidator


@pytest.fixture
def validator():
    return ToolCallValidator(now=lambda: datetime(2026, 9, 22, 17, tzinfo=UTC))


def test_repair_and_parse(validator):
    result = validator.validate(
        "schedule_message", {"to": "Mom", "mesage": "hi", "send_at": "tomorrow 8am"}
    )
    assert result.valid
    assert result.args["message"] == "hi"
    assert result.args["send_at"] == "2026-09-23T15:00:00Z"
    assert (
        validator.validate("get_recent_messages", {"contact": "Mom", "limit": "3"}).args["limit"]
        == 3
    )


@pytest.mark.parametrize(
    "name,args",
    [
        ("unknown", {}),
        ("send_message_now", []),
        ("send_message_now", {"to": "Mom", "message": "hi", "confirmed": True}),
        ("schedule_message", {"to": "Mom", "message": "hi", "send_at": "not a time"}),
        ("schedule_message", {"to": "Mom", "message": "hi", "send_at": "2026-11-01T01:30:00"}),
        ("schedule_message", {"to": "Mom", "message": "hi", "send_at": "2027-03-14T02:30:00"}),
    ],
)
def test_invalid(validator, name, args):
    assert not validator.validate(name, args).valid


def test_explicit_dst_offset(validator):
    assert validator.validate(
        "schedule_message", {"to": "Mom", "message": "hi", "send_at": "2026-11-01T01:30:00-07:00"}
    ).valid
