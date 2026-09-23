"""Nine deterministic checks on resolved, expanded actions."""

import re
from datetime import datetime
from zoneinfo import ZoneInfo

from imsg_agent.models import PHONE_PATTERN, RuleResult


class GuardrailRule:
    def result(self, decision="approve", reason=""):
        return RuleResult(rule=type(self).__name__, decision=decision, reason=reason)


class ContactValidation(GuardrailRule):
    def check(self, tool, args, config, store, now):
        if any(not re.fullmatch(PHONE_PATTERN, i["to"]) for i in args.get("items", [])):
            return self.result("block", "Invalid recipient phone number")
        return self.result()


class BlackoutHours(GuardrailRule):
    def check(self, tool, args, config, store, now):
        for item in args.get("items", []):
            hours = item.get("blackout_hours") or config.blackout_hours.model_dump()
            at = datetime.fromisoformat(item["send_at"]) if item.get("send_at") else now
            hour = at.astimezone(ZoneInfo(item["timezone"])).hour
            start, end = hours["start"], hours["end"]
            quiet = start <= hour < end if start < end else hour >= start or hour < end
            if start != end and quiet:
                return self.result(
                    "warn",
                    "Delivery time falls within quiet hours; recurring occurrences must be checked at delivery",
                )
        return self.result()


class GlobalRateLimit(GuardrailRule):
    def check(self, tool, args, config, store, now):
        if (
            tool == "send_message_now"
            and store.count_sends_last_hour(now=now) + len(args["items"])
            > config.max_messages_per_hour
        ):
            return self.result("block", "Global hourly send limit reached")
        return self.result()


class PerContactRateLimit(GuardrailRule):
    def check(self, tool, args, config, store, now):
        if tool == "send_message_now" and any(
            store.count_sends_last_hour(i["to"], now=now)
            >= config.max_messages_per_contact_per_hour
            for i in args["items"]
        ):
            return self.result("warn", "Recipient hourly send limit reached")
        return self.result()


class DuplicateDetection(GuardrailRule):
    def check(self, tool, args, config, store, now):
        if any(
            store.find_recent_duplicate(i["to"], i["message"], config.duplicate_window_minutes, now)
            for i in args.get("items", [])
        ):
            return self.result("warn", "A similar message was recently submitted to this recipient")
        return self.result()


class ContentLimits(GuardrailRule):
    def check(self, tool, args, config, store, now):
        if any(
            not i["message"].strip()
            or "\x00" in i["message"]
            or len(i["message"]) > config.max_message_length
            for i in args.get("items", [])
        ):
            return self.result(
                "block", "Message is empty, contains NUL, or exceeds the length limit"
            )
        return self.result()


class TimeValidation(GuardrailRule):
    def check(self, tool, args, config, store, now):
        if tool == "schedule_message" and any(
            datetime.fromisoformat(i["send_at"]) <= now for i in args["items"]
        ):
            return self.result("block", "Scheduled time must be in the future")
        return self.result()


class ConfirmationGate(GuardrailRule):
    def check(self, tool, args, config, store, now):
        return self.result("warn", "Explicit confirmation required for this action")


class BatchSizeLimit(GuardrailRule):
    def check(self, tool, args, config, store, now):
        if len(args.get("items", [])) > config.max_batch_size:
            return self.result("warn", "Batch exceeds the configured warning threshold")
        return self.result()


RULES = [
    ContactValidation,
    BlackoutHours,
    GlobalRateLimit,
    PerContactRateLimit,
    DuplicateDetection,
    ContentLimits,
    TimeValidation,
    ConfirmationGate,
    BatchSizeLimit,
]
