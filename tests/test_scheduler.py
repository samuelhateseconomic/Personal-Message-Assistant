"""Delivery tests use fake clocks and mocked Messages; no real messages are sent."""

from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta
from unittest.mock import Mock

import pytest

from imsg_agent.messenger import MessengerError, MessengerUnavailable
from imsg_agent.models import AppConfig, ScheduledMessage, SendResult
from imsg_agent.scheduler import TickScheduler, next_occurrence
from imsg_agent.store import Store

NOW = datetime(2026, 9, 22, 19, tzinfo=UTC)


@pytest.fixture
def scheduler(tmp_db):
    sender = Mock(dry_run=False)
    sender.send.return_value = SendResult(status="submitted", service="iMessage")
    clock = [NOW]
    scheduler = TickScheduler(tmp_db, sender, AppConfig(), now=lambda: clock[0])
    scheduler.clock = clock
    return scheduler


def add(scheduler, **kwargs):
    values = {"to": "+15550109999", "message": "Hello", "send_at": NOW, "delivery_approved": True}
    return scheduler.store.add(ScheduledMessage(**{**values, **kwargs}))


def test_due_once_and_future(scheduler):
    due = add(scheduler)
    future = add(scheduler, send_at=NOW + timedelta(days=1))
    scheduler.tick()
    scheduler.tick()
    scheduler.messenger.send.assert_called_once()
    assert scheduler.store.get_by_id(due.id).status == "sent"
    assert scheduler.store.get_by_id(future.id).status == "pending"
    assert scheduler.store.count_sends_last_hour(now=NOW) == 1


def test_sleep_catchup_skips_missed_cron(scheduler):
    due = add(scheduler, send_at=NOW - timedelta(days=5), cron="0 12 * * *")
    scheduler.tick()
    result = scheduler.store.get_by_id(due.id)
    assert result.status == "pending"
    assert result.send_at == NOW + timedelta(days=1)
    scheduler.messenger.send.assert_called_once()


def test_safe_retries_exhausted(scheduler):
    due = add(scheduler)
    scheduler.messenger.send.side_effect = MessengerUnavailable("not submitted")
    for delay in (30, 60, 120):
        before = scheduler.clock[0]
        scheduler.tick()
        assert scheduler.store.get_by_id(due.id).send_at == before + timedelta(seconds=delay)
        scheduler.tick()
        scheduler.clock[0] += timedelta(seconds=delay)
    scheduler.tick()
    result = scheduler.store.get_by_id(due.id)
    assert result.status == "failed" and result.attempts == 4
    assert scheduler.messenger.send.call_count == 4


def test_unknown_outcome_not_retried(scheduler):
    due = add(scheduler)
    scheduler.messenger.send.side_effect = MessengerError("timeout")
    scheduler.tick()
    scheduler.clock[0] += timedelta(hours=1)
    scheduler.tick()
    assert scheduler.store.get_by_id(due.id).status == "failed"
    scheduler.messenger.send.assert_called_once()


def test_recover_crashed_claim_without_resending(scheduler):
    due = add(scheduler)
    with scheduler.store.mutation_lock():
        assert scheduler.store.claim_due(due.id, NOW)
    scheduler.tick()
    result = scheduler.store.get_by_id(due.id)
    assert result.status == "failed" and "unknown" in result.last_error
    scheduler.messenger.send.assert_not_called()


def test_cancelled_not_sent_and_legacy_not_auto_approved(scheduler):
    due = add(scheduler)
    assert scheduler.store.cancel_pending(due.id)
    legacy = add(scheduler, delivery_approved=False)
    scheduler.tick()
    assert scheduler.store.get_by_id(legacy.id).status == "failed"
    scheduler.messenger.send.assert_not_called()


@pytest.mark.parametrize("restriction", ["global", "per_contact", "duplicate", "quiet"])
def test_delivery_rechecks_and_defers(scheduler, restriction):
    due = add(scheduler)
    if restriction == "global":
        scheduler.config.guardrails.max_messages_per_hour = 1
        scheduler.store.log_send("+15550108888", "other", success=True, sent_at=NOW)
    elif restriction == "per_contact":
        scheduler.config.guardrails.max_messages_per_contact_per_hour = 1
        scheduler.store.log_send(due.to, "other", success=True, sent_at=NOW)
    elif restriction == "duplicate":
        scheduler.store.log_send(due.to, due.message, success=True, sent_at=NOW)
    else:
        scheduler.clock[0] = NOW + timedelta(hours=11)
    assert scheduler.tick()[0]["status"] == "deferred"
    result = scheduler.store.get_by_id(due.id)
    assert result.send_at == scheduler.clock[0] + timedelta(seconds=60)
    assert result.attempts == 0
    scheduler.messenger.send.assert_not_called()


def test_dry_run_preserves_pending_and_claims(scheduler):
    due = add(scheduler)
    claimed = add(scheduler, message="other")
    scheduler.store.claim_due(claimed.id, NOW)
    scheduler.config.guardrails.dry_run_mode = True
    assert scheduler.tick() == [{"id": due.id, "status": "dry_run"}]
    assert scheduler.store.get_by_id(due.id).status == "pending"
    assert scheduler.store.get_by_id(claimed.id).status == "sending"
    scheduler.messenger.send.assert_not_called()


def test_two_workers_only_one_submission(scheduler):
    due = add(scheduler)
    other_store = Store(scheduler.store.path)
    other = TickScheduler(other_store, scheduler.messenger, AppConfig(), now=lambda: NOW)
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = [pool.submit(worker.tick) for worker in (scheduler, other)]
        for result in results:
            result.result(timeout=5)
    scheduler.messenger.send.assert_called_once()
    assert scheduler.store.get_by_id(due.id).status == "sent"
    other_store.close()


def test_persisted_retry_survives_restart(scheduler):
    due = add(scheduler)
    scheduler.messenger.send.side_effect = MessengerUnavailable("not yet")
    scheduler.tick()
    scheduler.messenger.send.side_effect = None
    scheduler.clock[0] += timedelta(seconds=30)
    fresh = TickScheduler(
        Store(scheduler.store.path),
        scheduler.messenger,
        AppConfig(),
        now=lambda: scheduler.clock[0],
    )
    fresh.tick()
    assert fresh.store.get_by_id(due.id).status == "sent"
    fresh.store.close()


def test_cron_dst_gap_and_fold():
    zone = "America/Los_Angeles"
    # 02:30 does not exist on March 14; skip to March 15.
    assert next_occurrence("30 2 * * *", datetime(2027, 3, 14, 8, tzinfo=UTC), zone) == datetime(
        2027, 3, 15, 9, 30, tzinfo=UTC
    )
    # Repeated 01:30 runs only at the first fold, not once for each UTC offset.
    assert next_occurrence("30 1 * * *", datetime(2026, 11, 1, 7, tzinfo=UTC), zone) == datetime(
        2026, 11, 1, 8, 30, tzinfo=UTC
    )
    assert next_occurrence(
        "30 1 * * *", datetime(2026, 11, 1, 8, 31, tzinfo=UTC), zone
    ) == datetime(2026, 11, 2, 9, 30, tzinfo=UTC)


def test_content_failure_and_notification(scheduler):
    due = add(scheduler, message="x" * 2001)
    assert scheduler.tick()[0]["status"] == "failed"
    assert scheduler.store.get_by_id(due.id).attempts == 0
    scheduler.messenger.send.assert_not_called()


def test_contact_blackout_snapshot_overrides_global(scheduler):
    # The contact-specific interval is checked, even if the global window is disabled.
    scheduler.config.guardrails.blackout_hours.start = 0
    scheduler.config.guardrails.blackout_hours.end = 0
    add(scheduler, blackout_hours={"start": 11, "end": 13})
    assert scheduler.tick()[0]["status"] == "deferred"
    scheduler.messenger.send.assert_not_called()


def test_deferral_eventually_delivers(scheduler):
    due = add(scheduler)
    scheduler.config.guardrails.max_messages_per_hour = 1
    scheduler.store.log_send("+15550108888", "other", success=True, sent_at=NOW)
    scheduler.tick()
    scheduler.clock[0] += timedelta(hours=1)
    scheduler.tick()
    assert scheduler.store.get_by_id(due.id).status == "sent"
    scheduler.messenger.send.assert_called_once()


def test_notification_failure_does_not_change_delivery_state(scheduler):
    scheduler.notify = Mock(side_effect=OSError("no notifications"))
    due = add(scheduler)
    scheduler.messenger.send.side_effect = MessengerError("uncertain")
    scheduler.tick()
    assert scheduler.store.get_by_id(due.id).status == "failed"


def test_background_thread_stops(scheduler):
    from threading import Event

    ticked = Event()
    scheduler.tick = Mock(side_effect=lambda: ticked.set())
    scheduler.start()
    assert ticked.wait(timeout=2)
    scheduler.stop()
    assert not scheduler.thread.is_alive()
