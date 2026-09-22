"""Tool Schemas — JSON schema definitions for all 8 tools.

These schemas are passed to Ollama's chat() call so the model
knows what tools are available and their expected arguments.

Tools:
- send_message_now:    Send a message immediately
- schedule_message:    Schedule for future delivery (one-time or recurring)
- cancel_scheduled:    Cancel a pending schedule
- list_scheduled:      List scheduled messages by status
- resolve_contact:     Look up a contact by name/alias/phone
- list_contacts:       List all contacts or filter by group
- get_recent_messages: Read recent messages from chat.db
- suggest_reply:       Read messages + generate a suggested reply
"""
from __future__ import annotations

# TODO: Define TOOL_SCHEMAS list of dicts in Ollama tool format
