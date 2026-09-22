"""Regex Fallback Parser — Catches common patterns when the AI model fails.

Local 12B models fail at structured tool calling ~15-20% of the time.
This deterministic parser matches common command patterns via regex:
- 'send "hello" to Mom' → send_message_now
- 'schedule "hi" to Mom at 9am' → schedule_message
- 'cancel msg-a1b2c3' → cancel_scheduled
- 'list pending' → list_scheduled
- 'what did Sarah say' → get_recent_messages
- 'reply to Sarah' → suggest_reply

All extracted arguments are validated through Pydantic before execution.
"""
from __future__ import annotations

# TODO: Implement FallbackParser class
# TODO: Define PATTERNS list of (regex, tool_name, extractor) tuples
# TODO: Implement parse(user_input) -> FallbackResult | None
