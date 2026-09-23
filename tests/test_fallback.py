import pytest

from imsg_agent.agent.fallback import FallbackParser


@pytest.mark.parametrize(
    "text,name",
    [
        ('send "hello" to Mom', "send_message_now"),
        ('schedule "hello" to Mom at tomorrow 8am', "schedule_message"),
        ("cancel msg-abc", "cancel_scheduled"),
        ("list pending", "list_scheduled"),
        ("what did Sarah say", "get_recent_messages"),
        ("reply to Sarah", "suggest_reply"),
    ],
)
def test_patterns(text, name):
    assert FallbackParser().parse(text).tool_name == name


@pytest.mark.parametrize(
    "text",
    [
        "Please maybe do something",
        'do not send "hi" to Mom',
        'send "hi" to Mom\nthen send "bye" to John',
    ],
)
def test_does_not_guess(text):
    assert FallbackParser().parse(text) is None
