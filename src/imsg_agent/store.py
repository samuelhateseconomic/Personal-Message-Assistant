"""SQLite persistence. Each operation owns a connection for thread-safe use."""

from __future__ import annotations

import json
import sqlite3
from contextlib import contextmanager
from datetime import UTC, datetime, timedelta
from pathlib import Path
from threading import RLock

from imsg_agent.models import ScheduledMessage, ScheduleStatus, utc_now


def timestamp(value: datetime) -> str:
    if value.tzinfo is None or value.utcoffset() is None:
        raise ValueError("Timestamp must include a timezone")
    return value.astimezone(UTC).isoformat(timespec="microseconds")


class Store:
    def __init__(self, path: str | Path):
        self.path = str(Path(path).expanduser()) if str(path) != ":memory:" else ":memory:"
        self._lock = RLock()
        self._memory = None
        if self.path == ":memory:":
            self._memory = sqlite3.connect(":memory:", check_same_thread=False)
        else:
            Path(self.path).parent.mkdir(parents=True, exist_ok=True)
        self._migrate()

    @contextmanager
    def _connection(self):
        with self._lock:
            connection = self._memory or sqlite3.connect(self.path, timeout=10)
            connection.row_factory = sqlite3.Row
            try:
                with connection:
                    yield connection
            finally:
                if connection is not self._memory:
                    connection.close()

    def close(self) -> None:
        with self._lock:
            if self._memory:
                self._memory.close()
                self._memory = None

    def _migrate(self) -> None:
        with self._connection() as db:
            db.execute("PRAGMA journal_mode=WAL")
            db.executescript("""
                CREATE TABLE IF NOT EXISTS schedules (
                    id TEXT PRIMARY KEY, status TEXT NOT NULL, send_at TEXT NOT NULL,
                    payload TEXT NOT NULL);
                CREATE INDEX IF NOT EXISTS schedules_due ON schedules(status, send_at);
                CREATE TABLE IF NOT EXISTS send_log (
                    id INTEGER PRIMARY KEY, recipient TEXT NOT NULL, message TEXT NOT NULL,
                    success INTEGER NOT NULL, sent_at TEXT NOT NULL, error TEXT,
                    schedule_id TEXT);
                CREATE INDEX IF NOT EXISTS sends_time ON send_log(sent_at, recipient);
                CREATE TABLE IF NOT EXISTS audit_log (
                    id INTEGER PRIMARY KEY, tool_name TEXT NOT NULL, args TEXT NOT NULL,
                    decision TEXT NOT NULL, reason TEXT NOT NULL, created_at TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS heartbeat (
                    id INTEGER PRIMARY KEY CHECK (id=1), payload TEXT NOT NULL);
            """)

    def add(self, message: ScheduledMessage) -> ScheduledMessage:
        with self._connection() as db:
            db.execute(
                "INSERT INTO schedules VALUES (?, ?, ?, ?)",
                (message.id, message.status, timestamp(message.send_at), message.model_dump_json()),
            )
        return message

    def get_by_id(self, schedule_id: str) -> ScheduledMessage | None:
        with self._connection() as db:
            row = db.execute("SELECT payload FROM schedules WHERE id=?", (schedule_id,)).fetchone()
        return ScheduledMessage.model_validate_json(row[0]) if row else None

    def list_schedules(self, status: ScheduleStatus | None = None) -> list[ScheduledMessage]:
        with self._connection() as db:
            query = "SELECT payload FROM schedules"
            params = ()
            if status is not None:
                query += " WHERE status=?"
                params = (status,)
            rows = db.execute(query + " ORDER BY send_at, id", params).fetchall()
        return [ScheduledMessage.model_validate_json(row[0]) for row in rows]

    def get_pending(self) -> list[ScheduledMessage]:
        return self.list_schedules("pending")

    def get_due(self, now: datetime | None = None) -> list[ScheduledMessage]:
        with self._connection() as db:
            rows = db.execute(
                "SELECT payload FROM schedules WHERE status='pending' AND send_at<=? "
                "ORDER BY send_at, id",
                (timestamp(now or utc_now()),),
            ).fetchall()
        return [ScheduledMessage.model_validate_json(row[0]) for row in rows]

    def get_due_one_shots(self, now: datetime | None = None) -> list[ScheduledMessage]:
        return [message for message in self.get_due(now) if message.cron is None]

    def update_status(
        self, schedule_id: str, status: ScheduleStatus, **changes
    ) -> ScheduledMessage:
        allowed = {"send_at", "attempts", "last_error"}
        if changes.keys() - allowed:
            raise ValueError("Only send_at, attempts and last_error can be updated")
        with self._connection() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT payload FROM schedules WHERE id=?", (schedule_id,)).fetchone()
            if row is None:
                raise KeyError(schedule_id)
            original = ScheduledMessage.model_validate_json(row[0])
            updated = ScheduledMessage.model_validate(
                {**original.model_dump(), **changes, "status": status}
            )
            db.execute(
                "UPDATE schedules SET status=?, send_at=?, payload=? WHERE id=?",
                (
                    updated.status,
                    timestamp(updated.send_at),
                    updated.model_dump_json(),
                    schedule_id,
                ),
            )
        return updated

    def log_send(
        self,
        recipient: str,
        message: str,
        *,
        success: bool,
        error: str | None = None,
        schedule_id: str | None = None,
        sent_at: datetime | None = None,
    ) -> None:
        with self._connection() as db:
            db.execute(
                "INSERT INTO send_log (recipient,message,success,sent_at,error,schedule_id) "
                "VALUES (?,?,?,?,?,?)",
                (
                    recipient,
                    message,
                    int(success),
                    timestamp(sent_at or utc_now()),
                    error,
                    schedule_id,
                ),
            )

    def count_sends_last_hour(
        self, recipient: str | None = None, now: datetime | None = None
    ) -> int:
        now = now or utc_now()
        query = "SELECT COUNT(*) FROM send_log WHERE success=1 AND sent_at>? AND sent_at<=?"
        params = [timestamp(now - timedelta(hours=1)), timestamp(now)]
        if recipient is not None:
            query += " AND recipient=?"
            params.append(recipient)
        with self._connection() as db:
            return db.execute(query, params).fetchone()[0]

    def find_recent_duplicate(
        self, recipient: str, message: str, window_minutes: int = 60, now: datetime | None = None
    ) -> dict | None:
        from rapidfuzz.fuzz import ratio

        now = now or utc_now()
        with self._connection() as db:
            rows = db.execute(
                "SELECT * FROM send_log WHERE recipient=? AND success=1 "
                "AND sent_at>? AND sent_at<=? ORDER BY sent_at DESC",
                (recipient, timestamp(now - timedelta(minutes=window_minutes)), timestamp(now)),
            ).fetchall()
        normalized = " ".join(message.casefold().split())
        for row in rows:
            if ratio(normalized, " ".join(row["message"].casefold().split())) >= 90:
                return dict(row)
        return None

    def log_audit(self, tool_name: str, args: dict, decision: str, reason: str = "") -> None:
        with self._connection() as db:
            db.execute(
                "INSERT INTO audit_log (tool_name,args,decision,reason,created_at) "
                "VALUES (?,?,?,?,?)",
                (tool_name, json.dumps(args, default=str), decision, reason, timestamp(utc_now())),
            )

    def update_heartbeat(
        self, pid: int, pending_count: int, next_fire_time: datetime | None = None
    ) -> None:
        payload = {
            "pid": pid,
            "pending_count": pending_count,
            "next_fire_time": timestamp(next_fire_time) if next_fire_time else None,
            "updated_at": timestamp(utc_now()),
        }
        with self._connection() as db:
            db.execute(
                "INSERT INTO heartbeat VALUES (1,?) ON CONFLICT(id) "
                "DO UPDATE SET payload=excluded.payload",
                (json.dumps(payload),),
            )

    def get_heartbeat(self) -> dict | None:
        with self._connection() as db:
            row = db.execute("SELECT payload FROM heartbeat WHERE id=1").fetchone()
        return json.loads(row[0]) if row else None
