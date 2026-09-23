"""Explicit, confirmed preference changes and conservative feedback proposals."""

import json
from uuid import NAMESPACE_URL, uuid5

from imsg_agent.memory.models import Preference
from imsg_agent.memory.repository import MemoryRepository


def contact_identity(contact):
    return contact.id or "contact-" + uuid5(NAMESPACE_URL, "imsg-contact:" + contact.phone).hex


class MemoryService:
    def __init__(self, store, contacts, confirm=None, dry_run=False):
        self.repository = MemoryRepository(store)
        self.contacts = contacts
        self.confirm = confirm or (lambda _: False)
        self.dry_run = dry_run

    def scope(self, contact=None):
        if contact is None:
            return "global", "Global drafting preferences"
        result = self.contacts.resolve(contact)
        if result.status != "resolved" or result.contact not in self.contacts.contacts:
            raise ValueError(
                "Choose one stored contact; unknown or ambiguous recipients cannot receive memory"
            )
        chosen = result.contact
        id = contact_identity(chosen)
        if sum(contact_identity(c) == id for c in self.contacts.contacts) != 1:
            raise ValueError(
                "Contact identity is shared; assign unique contact IDs before saving preferences"
            )
        return id, f"{chosen.name} ({chosen.phone})"

    def label(self, scope):
        if scope == "global":
            return "Global drafting preferences"
        matches = [c for c in self.contacts.contacts if contact_identity(c) == scope]
        return f"{matches[0].name} ({matches[0].phone}) [{scope}]" if len(matches) == 1 else scope

    def _save(self, scope, label, preference, source, feedback_id=None):
        existing = next(
            (p for p in self.repository.list(scope) if p["key"] == preference.key), None
        )
        preview = {
            "scope": label,
            "key": preference.key,
            "old_value": existing["value"] if existing else None,
            "new_value": preference.value,
            "source": source,
            "notice": "Drafting preference only. Does not authorize sending or change guardrails.",
        }
        if existing and existing["value"] != preference.value:
            preview["conflict"] = (
                "Explicit replacement of an existing preference requires approval."
            )
        if self.dry_run:
            return {"status": "dry_run", "proposal": preview}
        if not self.confirm(json.dumps(preview, ensure_ascii=False, indent=2)):
            return {"status": "cancelled"}
        saved = self.repository.save(scope, preference, source, existing, feedback_id)
        return {"status": "saved", "preference": saved}

    def remember(self, key, value, contact=None):
        preference = Preference(key=key, value=value)
        scope, label = self.scope(contact)
        return self._save(scope, label, preference, "explicit")

    def update(self, id, value):
        existing = self.repository.get(id)
        if existing is None:
            raise ValueError("Preference not found")
        preference = Preference(key=existing["key"], value=value)
        return self._save(
            existing["scope"], self.label(existing["scope"]), preference, "explicit_update"
        )

    def forget(self, id):
        existing = self.repository.get(id)
        if existing is None:
            raise ValueError("Preference not found")
        preview = {
            "forget": existing,
            "notice": "Also delete linked draft feedback and pending proposals for this preference.",
        }
        if self.dry_run:
            return {"status": "dry_run", "proposal": preview}
        if not self.confirm(json.dumps(preview, ensure_ascii=False, indent=2)):
            return {"status": "cancelled"}
        self.repository.forget(id, existing)
        return {"status": "forgotten", "id": id}

    def retrieve(self, contact=None, overrides=None):
        # Resolve identity before retrieving even global preferences for a targeted request.
        scope, _ = self.scope(contact)
        records = self.repository.list("global")
        if scope != "global":
            records += self.repository.list(scope)
        effective = {
            p["key"]: {"value": p["value"], "source": p["id"], "scope": p["scope"]}
            for p in records
            if p["approved"]
        }
        for key, value in (overrides or {}).items():
            preference = Preference(key=key, value=value)
            effective[key] = {
                "value": preference.value,
                "source": "current_request",
                "scope": "request",
            }
        return effective

    def record_feedback(self, original, corrected, contact=None):
        if (
            not original.strip()
            or not corrected.strip()
            or max(len(original), len(corrected)) > 10000
        ):
            raise ValueError("Drafts must be nonempty and at most 10000 characters")
        scope, label = self.scope(contact)
        # One correction is evidence for a proposal only, never an automatic preference.
        proposal = None
        if len(original.split()) >= 8 and len(corrected.split()) <= len(original.split()) * 0.6:
            proposal = Preference(key="length", value="short")
        preview = {
            "scope": label,
            "original": original,
            "corrected": corrected,
            "proposal": proposal.model_dump() if proposal else None,
            "notice": "Save these examples locally? Any proposed preference requires separate approval.",
        }
        if self.dry_run:
            return {"status": "dry_run", "feedback": preview}
        if not self.confirm(json.dumps(preview, ensure_ascii=False, indent=2)):
            return {"status": "cancelled"}
        return {
            "status": "recorded",
            "feedback": self.repository.add_feedback(scope, original, corrected, proposal),
        }

    def approve_feedback(self, id):
        feedback = self.repository.feedback(id)
        if not feedback or feedback["status"] != "proposed":
            raise ValueError("No pending preference proposal for this feedback")
        preference = Preference(key=feedback["proposed_key"], value=feedback["proposed_value"])
        return self._save(
            feedback["scope"], self.label(feedback["scope"]), preference, "feedback", id
        )

    def forget_feedback(self, id):
        feedback = self.repository.feedback(id)
        if not feedback:
            raise ValueError("Feedback not found")
        if self.dry_run:
            return {"status": "dry_run", "id": id}
        if not self.confirm(
            "Delete draft feedback "
            + id
            + "? Approved preferences remain until separately forgotten."
        ):
            return {"status": "cancelled"}
        self.repository.delete_feedback(id)
        return {"status": "forgotten", "id": id}
