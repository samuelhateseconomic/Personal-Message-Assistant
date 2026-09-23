"""Tool schemas generated from the same models that validate execution."""

from imsg_agent.models import TOOL_ARG_MODELS

DESCRIPTIONS = {
    "get_preferences": "Retrieve approved drafting preferences. Resolve contact first. Only pass overrides explicitly requested in the current user message; they are not saved.",
    "remember_preference": "Save an explicitly requested drafting preference after user confirmation. Never infer lasting preferences from one draft or contact notes.",
    "forget_preference": "Forget a stored preference and linked draft feedback after user confirmation.",
    "send_message_now": "Submit a message now, after confirmation. to accepts a name, phone, or group:NAME.",
    "schedule_message": "Store a schedule after confirmation. Daemon must be running for delivery. Supports group:NAME and template:KEY.",
    "cancel_scheduled": "Cancel a pending schedule after confirmation.",
    "list_scheduled": "List stored schedules.",
    "resolve_contact": "Retrieve a contact with sources; ambiguous matches require clarification.",
    "list_contacts": "List contact names and phone numbers, optionally by group.",
    "get_recent_messages": "Read conversation history (not implemented yet).",
    "suggest_reply": "Suggest a reply (not implemented yet).",
}
TOOL_SCHEMAS = [
    {
        "type": "function",
        "function": {
            "name": name,
            "description": DESCRIPTIONS[name],
            "parameters": model.model_json_schema(),
        },
    }
    for name, model in TOOL_ARG_MODELS.items()
]
