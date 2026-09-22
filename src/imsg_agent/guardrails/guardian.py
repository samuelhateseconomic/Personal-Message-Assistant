"""Guardian Middleware — Deterministic rule engine for action validation.

Every mutating tool call (send, schedule, cancel) passes through this
middleware BEFORE execution. Rules are deterministic code, not AI —
they cannot be prompt-injected or hallucinated around.

Rule execution:
- Rules run sequentially
- First 'block' stops evaluation immediately
- All 'warn' results are collected and shown together
- Every action (approved, warned, blocked) is logged to the audit table
"""
from __future__ import annotations

# TODO: Implement Guardian class
# TODO: Implement validate(tool_name, args) -> GuardrailResult
# TODO: Implement _build_summary() for confirmation prompts
