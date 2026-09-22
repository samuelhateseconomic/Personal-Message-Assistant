"""Guardrail Rules — 9 individual validation rule implementations.

Rules:
1. ContactValidation    — Recipient must exist in contacts or be valid E.164
2. BlackoutHours        — Warn if send_at falls in quiet hours
3. GlobalRateLimit      — Block if > N messages/hour globally
4. PerContactRateLimit  — Warn if > N messages/hour to one contact
5. DuplicateDetection   — Warn if same recipient + similar message recently
6. ContentLimits        — Block if message exceeds max length
7. TimeValidation       — Block if scheduling in the past
8. ConfirmationGate     — Require user 'Y' before send/schedule
9. BatchSizeLimit       — Warn if group send exceeds N recipients
"""
from __future__ import annotations

# TODO: Define GuardrailRule base class with check(tool_name, args) -> RuleResult
# TODO: Implement each of the 9 rule classes
