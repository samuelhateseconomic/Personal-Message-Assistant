"""Schedule Tool Handler — Creates a scheduled message for future delivery.

Resolves the recipient, parses send_at datetime, validates timezone,
and writes the schedule to the SQLite store. Supports both one-time
(send_at only) and recurring (send_at + cron expression) schedules.
"""
from __future__ import annotations

# TODO: Implement handle_schedule(args, store, contacts) -> dict
# TODO: Handle group: prefix for batch scheduling
# TODO: Handle template: prefix for stored message templates
