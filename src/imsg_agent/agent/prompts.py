"""System Prompt Builder — Constructs dynamic prompts for each agent turn.

Builds the system prompt with injected runtime context:
- Current datetime and timezone
- Contact list summary (count + group names, NOT full contact data)
- Pending schedule count
- Behavioral rules for the AI agent

The contact list is NOT included in the prompt — the model uses
the resolve_contact tool for lazy on-demand lookups.
"""
from __future__ import annotations

# TODO: Implement build_system_prompt(contact_summary, pending_count, current_time, timezone) -> str
