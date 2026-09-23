import sqlite3
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta

import pytest
from pydantic import ValidationError

from imsg_agent.models import ScheduledMessage
from imsg_agent.store import Store

NOW = datetime(2026, 9, 21, 12, tzinfo=UTC)


def message(**kwargs):
    return ScheduledMessage(to="+15550109999", message="Hello", send_at=NOW, **kwargs)


def test_crud_and_due_queries(tmp_db):
    one = tmp_db.add(message())
    recurring = tmp_db.add(message(cron="0 8 * * *"))
    future = tmp_db.add(
        ScheduledMessage(to=one.to, message="Later", send_at=NOW + timedelta(days=1))
    )
    assert tmp_db.get_by_id(one.id) == one
    assert {m.id for m in tmp_db.get_due(NOW)} == {one.id, recurring.id}
    assert tmp_db.get_due_one_shots(NOW) == [one]
    tmp_db.update_status(one.id, "sent", attempts=1)
    assert tmp_db.get_by_id(one.id).attempts == 1
    assert {m.id for m in tmp_db.get_pending()} == {recurring.id, future.id}
    tmp_db.update_status(future.id, "cancelled")
    assert tmp_db.get_by_id("missing") is None
    with pytest.raises(KeyError):
        tmp_db.update_status("missing", "sent")


def test_reject_invalid_update_and_duplicate_id(tmp_db):
    item = tmp_db.add(message())
    with pytest.raises(sqlite3.IntegrityError):
        tmp_db.add(item)
    with pytest.raises(ValidationError):
        tmp_db.update_status(item.id, "bad-status")
    with pytest.raises(ValidationError):
        tmp_db.update_status(item.id, "pending", send_at=NOW.replace(tzinfo=None))
    assert tmp_db.get_by_id(item.id) == item


def test_retry_rescheduling(tmp_db):
    item = tmp_db.add(message())
    tmp_db.update_status(
        item.id,
        "pending",
        attempts=1,
        last_error="Unavailable",
        send_at=NOW + timedelta(seconds=30),
    )
    assert tmp_db.get_due(NOW) == []
    assert tmp_db.get_due(NOW + timedelta(seconds=30))[0].attempts == 1


def test_rate_limits_and_duplicates(tmp_db):
    phone = "+15550109999"
    for when, success, recipient in [
        (NOW - timedelta(minutes=10), True, phone),
        (NOW - timedelta(hours=1), True, phone),
        (NOW, False, phone),
        (NOW, True, "+15550108888"),
        (NOW + timedelta(minutes=5), True, phone),
    ]:
        tmp_db.log_send(recipient, "Hello there!", success=success, sent_at=when)
    assert tmp_db.count_sends_last_hour(now=NOW) == 2
    assert tmp_db.count_sends_last_hour(phone, now=NOW) == 1
    assert tmp_db.find_recent_duplicate(phone, "hello there", now=NOW)
    assert tmp_db.find_recent_duplicate(phone, "Different content", now=NOW) is None


def test_heartbeat_and_audit(tmp_db):
    assert tmp_db.get_heartbeat() is None
    tmp_db.update_heartbeat(123, 2, NOW)
    tmp_db.update_heartbeat(456, 0)
    assert tmp_db.get_heartbeat()["pid"] == 456
    tmp_db.log_audit("send_message_now", {"to": "+15550109999"}, "block", "Rate limit")
    with sqlite3.connect(tmp_db.path) as db:
        assert db.execute("SELECT decision, reason FROM audit_log").fetchone() == (
            "block",
            "Rate limit",
        )


def test_wal_independent_connections_and_concurrent_writes(tmp_db):
    other = Store(tmp_db.path)
    with ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(lambda i: (tmp_db if i % 2 else other).add(message()), range(20)))
    assert len(other.get_pending()) == 20
    with sqlite3.connect(tmp_db.path) as db:
        assert db.execute("PRAGMA journal_mode").fetchone()[0] == "wal"
        db.execute("BEGIN")
        assert db.execute("SELECT COUNT(*) FROM schedules").fetchone()[0] == 20
        tmp_db.add(message())
        assert db.execute("SELECT COUNT(*) FROM schedules").fetchone()[0] == 20
    assert len(other.get_pending()) == 21
    other.close()


def test_memory_store():
    store = Store(":memory:")
    item = store.add(message())
    assert store.get_by_id(item.id) == item
    store.close()


def test_batch_insert_rolls_back_on_conflict(tmp_db):
    first = message()
    with pytest.raises(sqlite3.IntegrityError):
        tmp_db.add_many([first, first])
    assert tmp_db.get_pending() == []
