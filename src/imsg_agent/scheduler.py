"""Persistent polling scheduler with serialized claims and conservative crash recovery."""

import subprocess
from datetime import UTC, datetime, timedelta
from threading import Event, Thread
from zoneinfo import ZoneInfo

from croniter import croniter

from imsg_agent.guardrails.rules import RULES, ConfirmationGate, TimeValidation
from imsg_agent.logger import get_logger
from imsg_agent.messenger import MessengerError, MessengerUnavailable
from imsg_agent.models import utc_now


def next_occurrence(expression: str, after: datetime, timezone: str) -> datetime:
    """Local-wall-time cron; skip nonexistent times, use first fold on repeated times."""
    zone = ZoneInfo(timezone)
    base = after.astimezone(zone).replace(tzinfo=None)
    iterator = croniter(expression, base)
    for _ in range(1500):
        wall = iterator.get_next(datetime)
        candidate = wall.replace(tzinfo=zone, fold=0)
        utc = candidate.astimezone(UTC)
        if utc.astimezone(zone).replace(tzinfo=None) == wall and utc > after:
            return utc
    raise ValueError("No valid cron occurrence found")


class TickScheduler:
    def __init__(self, store, messenger, config, now=utc_now, interval=1, notify=None):
        self.store, self.messenger, self.config, self.now = store, messenger, config, now
        # One-second wakeups allow persisted 30/60/120-second retries without long timers.
        self.interval = interval
        self.stop_event = Event()
        self.thread = None
        self.logger = get_logger("imsg_agent.scheduler")
        self.notify = notify or (lambda title, message: None)

    def start(self):
        if self.thread and self.thread.is_alive():
            raise RuntimeError("Scheduler is already running")
        self.stop_event.clear()
        self.thread = Thread(target=self.run, name="imsg-scheduler", daemon=True)
        self.thread.start()

    def stop(self):
        self.stop_event.set()
        if self.thread:
            self.thread.join()

    def run(self):
        while not self.stop_event.is_set():
            self.tick()
            self.stop_event.wait(self.interval)

    def _notify(self, title, message):
        try:
            self.notify(title, message)
        except (OSError, subprocess.SubprocessError):
            self.logger.warning("Desktop notification failed")

    def tick(self):
        # A dry-run daemon never claims, recovers, or consumes schedules.
        if self.config.guardrails.dry_run_mode or self.messenger.dry_run:
            return [{"id": m.id, "status": "dry_run"} for m in self.store.get_due(self.now())]
        receipts = []
        with self.store.mutation_lock():
            recovered = self.store.recover_interrupted()
            if recovered:
                self._notify(
                    "Delivery needs review",
                    f"{recovered} interrupted submissions were not retried.",
                )
            for due in self.store.get_due(self.now()):
                if self.stop_event.is_set():
                    break
                receipts.append(self._fire(due))
        return receipts

    def _fire(self, message):
        now = self.now()
        if not message.delivery_approved:
            self.store.update_status(
                message.id,
                "failed",
                last_error="Legacy schedule lacks background-delivery approval; recreate it with confirmation.",
            )
            return {"id": message.id, "status": "failed"}
        item = {
            "to": message.to,
            "message": message.message,
            "timezone": message.timezone,
            "service": message.service,
            "blackout_hours": message.blackout_hours.model_dump()
            if message.blackout_hours
            else None,
        }
        checks = [
            rule().check(
                "send_message_now", {"items": [item]}, self.config.guardrails, self.store, now
            )
            for rule in RULES
            if rule not in (ConfirmationGate, TimeValidation)
        ]
        failures = [r for r in checks if r.decision != "approve"]
        if failures:
            fatal = any(r.rule in ("ContentLimits", "ContactValidation") for r in failures)
            reason = "; ".join(r.reason for r in failures)
            self.store.log_audit(
                "scheduled_delivery", {"id": message.id}, "block" if fatal else "defer", reason
            )
            self.store.update_status(
                message.id,
                "failed" if fatal else "pending",
                last_error=reason,
                **({} if fatal else {"send_at": now + timedelta(seconds=60)}),
            )
            return {"id": message.id, "status": "failed" if fatal else "deferred"}
        claimed = self.store.claim_due(message.id, now)
        if claimed is None:
            return {"id": message.id, "status": "skipped"}
        self.store.log_audit(
            "scheduled_delivery",
            {"id": message.id},
            "approved",
            f"Due by {(now - message.send_at).total_seconds():.0f} seconds",
        )
        try:
            result = self.messenger.send(claimed.to, claimed.message, claimed.service)
            if result.status != "submitted":
                raise MessengerError("Unexpected send result; review before retrying")
        except MessengerUnavailable as exc:
            claimed.last_error = str(exc)
            if claimed.attempts <= self.config.max_retries:
                claimed.status = "pending"
                claimed.send_at = now + timedelta(seconds=30 * 2 ** (claimed.attempts - 1))
            else:
                claimed.status = "failed"
            self.store.finish_submission(claimed, success=False, now=self.now(), error=str(exc))
        except MessengerError as exc:
            claimed.status = "failed"
            claimed.last_error = (
                "Unknown or failed submission; check Messages before recreating. " + str(exc)
            )
            self.store.finish_submission(
                claimed, success=False, now=self.now(), error=claimed.last_error
            )
        else:
            completed = self.now()
            claimed.last_error = None
            claimed.status = "sent"
            if claimed.cron:
                try:
                    claimed.send_at = next_occurrence(claimed.cron, completed, claimed.timezone)
                    claimed.status = "pending"
                    claimed.attempts = 0
                except ValueError as exc:
                    claimed.status = "failed"
                    claimed.last_error = f"Submitted, but recurrence failed: {exc}"
            self.store.finish_submission(claimed, success=True, now=completed)
        if claimed.status == "failed":
            self._notify(
                "Scheduled delivery needs review",
                f"Schedule {claimed.id} failed; inspect the send log.",
            )
        return {"id": claimed.id, "status": claimed.status}
