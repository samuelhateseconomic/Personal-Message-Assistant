"""Shared validation, preparation, guardrails and confirmation for all tool execution."""

from copy import deepcopy

from imsg_agent.agent.validator import ToolCallValidator
from imsg_agent.guardrails.guardian import Guardian
from imsg_agent.memory.service import MemoryService
from imsg_agent.models import utc_now
from imsg_agent.tools.contacts import handle_list_contacts, handle_resolve
from imsg_agent.tools.manage import handle_cancel, handle_list
from imsg_agent.tools.schedule import handle_schedule
from imsg_agent.tools.schemas import TOOL_SCHEMAS
from imsg_agent.tools.send import handle_send

MUTATIONS = {
    "send_message_now",
    "schedule_message",
    "cancel_scheduled",
    "remember_preference",
    "forget_preference",
}


class ToolRegistry:
    def __init__(
        self,
        contacts,
        store,
        messenger,
        config,
        confirm=None,
        dry_run=False,
        timezone="America/Los_Angeles",
        now=utc_now,
    ):
        self.contacts, self.store, self.messenger = contacts, store, messenger
        self.config, self.now = config, now
        self.confirm = confirm or (lambda summary: False)
        self.dry_run = dry_run or config.dry_run_mode or bool(getattr(messenger, "dry_run", False))
        self.validator = ToolCallValidator(timezone, now)
        self.guardian = Guardian(config, store, now)
        self.memory = MemoryService(store, contacts, self.confirm, self.dry_run)
        self.handlers = {
            "get_preferences": lambda a: {
                "preferences": self.memory.retrieve(a.get("contact"), a.get("overrides"))
            },
            "remember_preference": lambda a: self.memory.remember(
                a["key"], a["value"], a.get("contact")
            ),
            "forget_preference": lambda a: self.memory.forget(a["id"]),
            "resolve_contact": self._resolve_with_memory,
            "list_contacts": lambda a: handle_list_contacts(a, contacts),
            "list_scheduled": lambda a: handle_list(a, store),
            "send_message_now": lambda a: handle_send(a, messenger, store),
            "schedule_message": lambda a: handle_schedule(a, store),
            "cancel_scheduled": lambda a: handle_cancel(a, store),
        }

    def _resolve_with_memory(self, args):
        result = handle_resolve(args, self.contacts)
        if result.get("status") == "resolved" and result.get("sources"):
            try:
                result["approved_preferences"] = self.memory.retrieve(args["query"])
            except ValueError as exc:
                result["memory_error"] = str(exc)
        return result

    def register(self, name, handler):
        from imsg_agent.models import TOOL_ARG_MODELS

        if name not in TOOL_ARG_MODELS:
            raise ValueError("A registered tool must have a validated argument schema")
        self.handlers[name] = handler

    def get_schemas(self):
        return [deepcopy(t) for t in TOOL_SCHEMAS if t["function"]["name"] in self.handlers]

    def _prepare(self, name, args):
        if name == "cancel_scheduled":
            message = self.store.get_by_id(args["id"])
            if message is None or message.status != "pending":
                raise ValueError("Schedule is missing or is no longer pending")
            return {"id": message.id, "schedule": message.model_dump(mode="json")}
        query = args["to"]
        if query.startswith("group:"):
            contacts = self.contacts.get_group(query[6:])
            if not contacts:
                raise ValueError("Group is empty or unknown")
        else:
            result = self.contacts.resolve(query)
            if result.status != "resolved":
                choices = ", ".join(f"{c.name} ({c.phone})" for c in result.candidates)
                raise ValueError(f"Recipient {result.status}. Specify a phone number. {choices}")
            contacts = [result.contact]
        items, phones = [], set()
        for contact in contacts:
            if contact.phone in phones:
                continue
            phones.add(contact.phone)
            message = args["message"]
            if message.startswith("template:"):
                key = message[9:]
                if key not in contact.templates:
                    raise ValueError(f"Missing template {key!r} for {contact.name}")
                message = contact.templates[key]
            item = {
                "name": contact.name,
                "to": contact.phone,
                "message": message,
                "service": contact.service,
                "timezone": contact.timezone,
                "blackout_hours": contact.blackout_hours.model_dump()
                if contact.blackout_hours
                else None,
            }
            if contact.metadata.get("timezone_verified") is False:
                item["timezone_note"] = "Contact timezone unverified; default is shown"
            if contact.metadata.get("service_verified") is False:
                item["service_note"] = "Messaging service unverified; default is shown"
            if name == "schedule_message":
                item.update(send_at=args["send_at"], cron=args.get("cron"))
            items.append(item)
        plan = {"items": items}
        if name == "schedule_message":
            plan["delivery_policy"] = (
                "Approve automatic delivery when the daemon runs, including future cron occurrences. "
                "First delivery uses send_at; later occurrences use cron in the shown timezone. "
                "Quiet hours and rate limits defer delivery. After sleep, send at most one overdue "
                "occurrence and skip missed repeats. Retry only failures known to precede submission; "
                "uncertain outcomes require manual review. Cancel the schedule to stop future sends."
            )
        return plan

    def execute(self, name, args):
        # Serialize confirmation and submission across app processes sharing a database.
        if isinstance(name, str) and name in MUTATIONS:
            with self.store.mutation_lock():
                return self._execute(name, args)
        return self._execute(name, args)

    def _execute(self, name, args):
        checked = self.validator.validate(name, args)
        if not checked.valid:
            return {"error": "Invalid tool arguments", "details": checked.errors}
        if name not in self.handlers:
            return {"error": "This tool is not implemented yet"}
        if name not in MUTATIONS or name in ("remember_preference", "forget_preference"):
            try:
                # Memory has its own exact-change confirmation, with no delivery permissions.
                self.memory.dry_run = self.dry_run
                return self.handlers[name](checked.args)
            except ValueError as exc:
                return {"error": str(exc), "needs_clarification": True}
        try:
            plan = self._prepare(name, checked.args)
        except ValueError as exc:
            self.store.log_audit(name, checked.args, "block", str(exc))
            return {"error": str(exc), "needs_clarification": True}
        gate = self.guardian.validate(name, plan)
        if gate.decision == "block":
            return {
                "error": "Action blocked",
                "reasons": [r.reason for r in gate.results if r.decision == "block"],
            }
        if self.dry_run:
            return {
                "status": "dry_run",
                "action": name,
                "plan": plan,
                "warnings": [r.reason for r in gate.results if r.decision == "warn"],
            }
        if not self.confirm(gate.summary):
            self.store.log_audit(name, plan, "cancelled", "User declined confirmation")
            return {"status": "cancelled", "reason": "User declined confirmation"}
        # Recheck time/rates after a potentially long confirmation prompt.
        gate = self.guardian.validate(name, plan)
        if gate.decision == "block":
            return {
                "error": "Action blocked after confirmation",
                "reasons": [r.reason for r in gate.results if r.decision == "block"],
            }
        self.store.log_audit(name, plan, "confirmed", "User approved the displayed plan")
        return self.handlers[name](plan)
