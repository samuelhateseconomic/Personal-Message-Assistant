"""Bounded, read-only access to one-to-one Messages conversations."""

import re
import sqlite3
from contextlib import contextmanager
from datetime import UTC, datetime, timedelta
from pathlib import Path

import typedstream
from typedstream.archiving import GenericArchivedObject
from typedstream.stream import InvalidTypedStreamError
from typedstream.types.foundation import NSString

from imsg_agent.models import PHONE_PATTERN, ConversationSummary, MessageRecord

APPLE_EPOCH = datetime(2001, 1, 1, tzinfo=UTC)
ACCESS_HELP = (
    "Cannot read Messages history. If macOS denies access, enable Full Disk Access "
    "for the app hosting this command in System Settings > Privacy & Security, "
    "then restart that app. The database is never copied or modified."
)


class MessageReaderError(ValueError):
    pass


def decode_body(blob):
    """Decode only the leading string of supported attributed-string archives."""
    if not isinstance(blob, bytes) or not blob or len(blob) > 2_000_000:
        return None
    try:
        value = typedstream.unarchive_from_data(blob)
        if isinstance(value, NSString):
            return value.value
        if isinstance(value, GenericArchivedObject):
            cls = value.clazz
            classes = set()
            while cls is not None:
                classes.add(cls.name)
                cls = cls.superclass
            if b"NSAttributedString" not in classes and b"NSMutableAttributedString" not in classes:
                return None
            if value.contents:
                first = value.contents[0].values[0]
                if isinstance(first, NSString):
                    return first.value
    except (
        InvalidTypedStreamError,
        ValueError,
        TypeError,
        IndexError,
        EOFError,
        UnicodeError,
        RecursionError,
    ):
        return None
    return None


def apple_time(value):
    try:
        number = int(value)
        seconds = number / 1_000_000_000 if abs(number) >= 100_000_000_000 else number
        return APPLE_EPOCH + timedelta(seconds=seconds)
    except (TypeError, ValueError, OverflowError) as exc:
        raise MessageReaderError("Messages contains an unsupported timestamp") from exc


def normalized_handle(value):
    # Match complete numbers only; never use suffix/fuzzy matches for private history.
    text = re.sub(r"[\s().-]", "", value or "")
    return text.lstrip("+") if re.fullmatch(r"\+?[1-9][0-9]{7,14}", text) else None


class MessageReader:
    def __init__(self, path=None):
        self.path = (
            Path(path).expanduser().resolve() if path else Path.home() / "Library/Messages/chat.db"
        )

    @contextmanager
    def _connection(self):
        db = None
        try:
            if not self.path.is_file():
                raise MessageReaderError(
                    "Messages database is missing. Select an existing database with --messages-db."
                )
            db = sqlite3.connect(self.path.as_uri() + "?mode=ro", uri=True, timeout=3)
            db.row_factory = sqlite3.Row
            db.execute("PRAGMA query_only=ON")
            db.execute("PRAGMA trusted_schema=OFF")
            # Bound expensive/corrupt database queries without changing the source.
            remaining = [10000]

            def progress():
                remaining[0] -= 1
                return int(remaining[0] <= 0)

            db.set_progress_handler(progress, 1000)
            yield db
        except (OSError, sqlite3.Error) as exc:
            raise MessageReaderError(ACCESS_HELP) from exc
        finally:
            if db is not None:
                db.close()

    @staticmethod
    def _schema(db):
        required = {
            "chat": {"style"},
            "message": {"date", "is_from_me", "handle_id"},
            "handle": {"id"},
            "chat_handle_join": {"chat_id", "handle_id"},
            "chat_message_join": {"chat_id", "message_id"},
        }
        schemas = {}
        for table, fields in required.items():
            schemas[table] = {r["name"] for r in db.execute(f"PRAGMA table_info({table})")}
            if not fields <= schemas[table]:
                raise MessageReaderError(f"Unsupported Messages database schema: {table}")
        return schemas["message"]

    def has_access(self):
        try:
            self.check_schema()
            return True
        except MessageReaderError:
            return False

    def check_schema(self):
        """Check permissions and table metadata without reading conversation rows."""
        with self._connection() as db:
            self._schema(db)

    @staticmethod
    def _limit(limit):
        if not isinstance(limit, int) or isinstance(limit, bool) or not 1 <= limit <= 100:
            raise ValueError("Limit must be an integer from 1 to 100")

    def get_recent_messages(self, phone, limit=10):
        self._limit(limit)
        if not re.fullmatch(PHONE_PATTERN, phone):
            raise ValueError("History lookup requires a complete E.164 phone number")
        with self._connection() as db:
            columns = self._schema(db)
            handles = [
                r["ROWID"]
                for r in db.execute("SELECT ROWID,id FROM handle")
                if normalized_handle(r["id"]) == phone[1:]
            ]
            if not handles:
                return []
            slots = ",".join("?" for _ in handles)
            # A group chat containing this person is not their direct conversation.
            chats = [
                r[0]
                for r in db.execute(
                    f"SELECT chat_id FROM chat_handle_join "
                    f"WHERE chat_id IN (SELECT ROWID FROM chat WHERE style=45) GROUP BY chat_id "
                    f"HAVING COUNT(DISTINCT handle_id)=1 AND MAX(handle_id) IN ({slots})",
                    handles,
                )
            ]
            if not chats:
                return []
            optional = ["text", "attributedBody", "cache_has_attachments"]
            selected = ",".join(f'm."{c}"' if c in columns else f'NULL AS "{c}"' for c in optional)
            filters = "".join(
                f' AND COALESCE(m."{c}",0)=0'
                for c in ["associated_message_type", "item_type", "is_deleted", "is_retracted"]
                if c in columns
            )
            # Normalize old seconds and newer nanoseconds for chronological ordering.
            rows = db.execute(
                f"SELECT m.ROWID AS message_id,m.date,m.is_from_me,{selected} FROM message m "
                f"WHERE EXISTS (SELECT 1 FROM chat_message_join cm WHERE cm.message_id=m.ROWID "
                f"AND cm.chat_id IN ({','.join('?' for _ in chats)})) "
                f"AND (m.is_from_me=1 OR m.handle_id IN ({slots})){filters} "
                "ORDER BY CASE WHEN ABS(m.date)>=100000000000 THEN m.date/1000000000.0 ELSE m.date END DESC, "
                "m.ROWID DESC LIMIT ?",
                [*chats, *handles, limit],
            ).fetchall()
        messages = []
        for row in reversed(rows):
            text = row["text"]
            if row["attributedBody"]:
                decoded = decode_body(row["attributedBody"])
                # Prefer attributed body; if decoding fails, avoid using possibly stale text.
                text = decoded
            readable = isinstance(text, str) and bool(text.strip().replace("\ufffc", "").strip())
            state = (
                "text"
                if readable
                else "attachment"
                if row["cache_has_attachments"]
                else "unavailable"
            )
            messages.append(
                MessageRecord(
                    id=str(row["message_id"]),
                    source=f"chat.db#message/{row['message_id']}",
                    text=text[:4000] if readable else "",
                    content_status=state,
                    truncated=readable and len(text) > 4000,
                    sent_at=apple_time(row["date"]),
                    is_from_me=bool(row["is_from_me"]),
                )
            )
        return messages

    def get_conversations(self, limit=20):
        """List direct phone conversations only; email and group threads are excluded."""
        self._limit(limit)
        with self._connection() as db:
            self._schema(db)
            rows = db.execute(
                """SELECT h.id, MAX(CASE WHEN ABS(m.date)>=100000000000
                THEN m.date/1000000000.0 ELSE m.date END) AS latest
                FROM chat_handle_join ch JOIN handle h ON h.ROWID=ch.handle_id
                JOIN chat_message_join cm ON cm.chat_id=ch.chat_id
                JOIN message m ON m.ROWID=cm.message_id
                WHERE ch.chat_id IN (SELECT ROWID FROM chat WHERE style=45)
                AND ch.chat_id IN (SELECT chat_id FROM chat_handle_join GROUP BY chat_id
                    HAVING COUNT(DISTINCT handle_id)=1)
                GROUP BY h.id ORDER BY latest DESC LIMIT ?""",
                (limit,),
            ).fetchall()
        results, seen = [], set()
        for row in rows:
            digits = normalized_handle(row["id"])
            if not digits or digits in seen:
                continue
            seen.add(digits)
            recent = self.get_recent_messages("+" + digits, 1)
            if recent:
                results.append(ConversationSummary(contact="+" + digits, latest_message=recent[-1]))
        return results
