"""Tick-Based Scheduler — 60-second polling loop for message delivery.

Replaces setTimeout (which overflows at 24.8 days) with a reliable
polling approach that also handles macOS sleep/wake recovery.

Every 60 seconds, checks SQLite for due messages and fires them.
Recurring schedules use croniter for next-fire calculation.
Failed sends retry with exponential backoff (30s, 60s, 120s).
"""
from __future__ import annotations

# TODO: Implement TickScheduler class with background thread
# TODO: Implement _tick() — query due one-shots + recurring from store
# TODO: Implement _fire() — send via messenger, update status, handle sleep delay
# TODO: Implement _handle_failure() — retry with exponential backoff
# TODO: Implement _notify() — macOS notification via osascript
