"""Reply Tool Handlers — Read messages and suggest replies.

Provides handlers for:
- get_recent_messages: Read from chat.db (local only, never shared)
- suggest_reply: Read recent messages + pass to Ollama for reply suggestion

Message content NEVER leaves the local machine.
"""

from __future__ import annotations

# TODO: Implement handle_get_recent(args, reader, contacts) -> dict
# TODO: Implement handle_suggest_reply(args, reader, contacts, backend) -> dict
