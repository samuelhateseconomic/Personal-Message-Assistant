"""Fallback Parser Tests — Verify regex pattern matching.

Test cases:
- 'send "hello" to Mom' → send_message_now
- 'schedule "hi" to Mom at 9am' → schedule_message
- 'cancel msg-a1b2c3' → cancel_scheduled
- 'list pending' → list_scheduled
- 'what did Sarah say' → get_recent_messages
- 'reply to Sarah' → suggest_reply
- Unrecognized input returns None
"""
from __future__ import annotations

# TODO: Implement test cases
