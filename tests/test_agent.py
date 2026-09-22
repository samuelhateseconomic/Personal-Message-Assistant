"""Agent Tests — Verify orchestrator tool loop and error handling.

Test cases:
- Single tool call (resolve + schedule)
- Multi-turn follow-up (context maintained)
- Max iterations guard (stops at 5)
- Invalid tool call triggers repair
- Repair failure triggers fallback parser
- Blocked guardrail returns error to model
- User cancellation returns error to model
- Context trimming at 10 messages
"""
from __future__ import annotations

# TODO: Implement test cases
