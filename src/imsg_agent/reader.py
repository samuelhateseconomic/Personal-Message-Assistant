"""Message Reader — Reads conversation history from macOS Messages database.

Opens ~/Library/Messages/chat.db in read-only mode via sqlite3.
Used by the smart-reply feature to fetch recent messages for a contact.
Message data NEVER leaves the local machine — it is processed in-memory only.

Requires Full Disk Access permission for Terminal.
"""
from __future__ import annotations

# TODO: Implement MessageReader class
# TODO: Implement get_recent_messages(phone, limit) -> list[MessageRecord]
# TODO: Implement get_conversations(limit) -> list[ConversationSummary]
# TODO: Implement has_access() permission check
# TODO: Guide user to enable Full Disk Access if missing
