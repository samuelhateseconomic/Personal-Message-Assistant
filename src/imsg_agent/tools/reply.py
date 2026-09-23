"""Read-only history and draft-only reply tools with deterministic evidence checks."""

from imsg_agent.agent.backend import BackendUnavailable
from imsg_agent.reader import MessageReaderError


def resolve_target(query, contacts):
    resolved = contacts.resolve(query)
    if resolved.status != "resolved":
        return None, {
            "status": resolved.status,
            "needs_clarification": True,
            "candidates": [{"name": c.name, "phone": c.phone} for c in resolved.candidates],
        }
    return resolved.contact, None


def handle_get_recent(args, reader, contacts):
    contact, error = resolve_target(args["contact"], contacts)
    if error:
        return error
    try:
        messages = reader.get_recent_messages(contact.phone, args.get("limit", 10))
    except MessageReaderError as exc:
        return {"error": str(exc), "status": "unavailable"}
    return {
        "status": "ok" if messages else "no_history",
        "contact": {"name": contact.name, "phone": contact.phone},
        "messages": [m.model_dump(mode="json") for m in messages],
        "sources": [m.source for m in messages],
        "warnings": [
            "Some messages contain unsupported text or attachments; their content was not inferred."
        ]
        if any(m.content_status != "text" or m.truncated for m in messages)
        else [],
    }


def handle_suggest_reply(args, reader, contacts, backend, memory, max_length=2000):
    history = handle_get_recent(args, reader, contacts)
    if history.get("status") != "ok":
        return {**history, "needs_clarification": True, "draft": None}
    messages = history["messages"]
    incoming = [m for m in messages if not m["is_from_me"]]
    if not incoming:
        return {
            "status": "insufficient_evidence",
            "draft": None,
            "needs_clarification": True,
            "reason": "No incoming message in the selected history. Increase the limit or provide context.",
        }
    latest = incoming[-1]
    if any(m["content_status"] != "text" or m["truncated"] for m in (latest, messages[-1])):
        return {
            "status": "insufficient_evidence",
            "draft": None,
            "needs_clarification": True,
            "reason": "The latest message is unreadable, attachment-only, or truncated. Provide its context explicitly.",
        }
    if messages[-1]["is_from_me"] and not args.get("instruction"):
        return {
            "status": "needs_clarification",
            "draft": None,
            "needs_clarification": True,
            "reason": "The latest message is yours. Give an instruction if you want a follow-up draft.",
        }
    # Only selected-message text enters this bounded context; archived bodies are never passed on.
    selected, total = [], 0
    for message in reversed(messages):
        if total + len(message["text"]) > 20000:
            break
        selected.append(message)
        total += len(message["text"])
    selected.reverse()
    if latest["id"] not in {m["id"] for m in selected}:
        return {
            "status": "insufficient_evidence",
            "draft": None,
            "needs_clarification": True,
            "reason": "Latest incoming message falls outside the bounded context.",
        }
    contact, _ = resolve_target(args["contact"], contacts)
    # Raw phone numbers can be read explicitly, but cannot inherit another person's memory.
    preferences = (
        memory.retrieve(args["contact"], args.get("overrides"))
        if contact in contacts.contacts
        else memory.retrieve(overrides=args.get("overrides"))
    )
    try:
        generated = backend.draft_reply(selected, args.get("instruction", ""), preferences)
    except BackendUnavailable as exc:
        return {"status": "unavailable", "error": str(exc), "draft": None}
    draft = generated.get("draft") if isinstance(generated, dict) else None
    ids = generated.get("source_ids") if isinstance(generated, dict) else None
    available = {m["id"]: m["source"] for m in selected if m["content_status"] == "text"}
    if (
        not isinstance(draft, str)
        or not draft.strip()
        or len(draft) > max_length
        or "\x00" in draft
        or not isinstance(ids, list)
        or not ids
        or any(not isinstance(i, str) or i not in available for i in ids)
        or latest["id"] not in ids
    ):
        return {
            "status": "invalid_draft",
            "draft": None,
            "error": "Model returned an invalid draft or unsupported source IDs.",
        }
    return {
        "status": "draft",
        "draft": draft.strip(),
        "contact": history["contact"],
        "sources": list(dict.fromkeys(available[i] for i in ids)),
        "preferences": preferences,
        "warnings": history["warnings"],
        "notice": "Suggestion only; nothing was sent or saved as feedback. Source IDs identify input messages, not verified factual support.",
    }
