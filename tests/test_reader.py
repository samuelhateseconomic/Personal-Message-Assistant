"""Synthetic Messages schema and archives; never opens the user's Messages database."""

import sqlite3
from datetime import UTC, datetime
from pathlib import Path

import pytest

from imsg_agent.reader import MessageReader, MessageReaderError, apple_time, decode_body


def archive(text):
    data = text.encode("utf-8")
    assert len(data) < 128
    return (
        b"\x04\x0bstreamtyped\x81\xe8\x03"
        b"\x84\x01@\x84\x84\x84\x12NSAttributedString\x00\x84\x84\x08NSObject\x00\x85"
        b"\x84\x01@\x84\x84\x84\x08NSString\x01\x84\x84\x08NSObject\x00\x85\x84\x01+"
        + bytes([len(data)])
        + data
        + b"\x86\x86"
    )


@pytest.fixture
def messages_db(tmp_path):
    path = tmp_path / "chat.db"
    with sqlite3.connect(path) as db:
        db.executescript("""
        CREATE TABLE handle (id TEXT);
        CREATE TABLE chat (style INTEGER);
        INSERT INTO chat VALUES (45),(45),(43),(45),(45);
        CREATE TABLE message (date INTEGER,is_from_me INTEGER,handle_id INTEGER,text TEXT,
          attributedBody BLOB,cache_has_attachments INTEGER,associated_message_type INTEGER,
          item_type INTEGER,is_deleted INTEGER,is_retracted INTEGER);
        CREATE TABLE chat_handle_join (chat_id INTEGER,handle_id INTEGER);
        CREATE TABLE chat_message_join (chat_id INTEGER,message_id INTEGER);
        INSERT INTO handle VALUES ('+15550109999'),('+15550108888'),('5550109999'),('person@example.test');
        INSERT INTO chat_handle_join VALUES (1,1),(2,2),(3,1),(3,2),(4,3),(5,4);
        """)

    def add(
        text,
        date,
        *,
        chat=1,
        handle=1,
        outgoing=0,
        blob=None,
        attachment=0,
        reaction=0,
        item_type=0,
        deleted=0,
        retracted=0,
    ):
        with sqlite3.connect(path) as db:
            cursor = db.execute(
                "INSERT INTO message VALUES (?,?,?,?,?,?,?,?,?,?)",
                (
                    date,
                    outgoing,
                    handle,
                    text,
                    blob,
                    attachment,
                    reaction,
                    item_type,
                    deleted,
                    retracted,
                ),
            )
            id = cursor.lastrowid
            db.execute("INSERT INTO chat_message_join VALUES (?,?)", (chat, id))
            return id

    return path, add


def test_direct_conversation_includes_outgoing_and_excludes_groups(messages_db):
    path, add = messages_db
    one = add("Hi", 800000000)
    two = add("Hello", 800000001000000000, outgoing=1, handle=0)
    add("Group secret", 800000002000000000, chat=3)
    add("Someone else", 800000003000000000, chat=2, handle=2)
    add("Local suffix match must not count", 800000004000000000, chat=4, handle=3)
    with sqlite3.connect(path) as db:
        db.execute("INSERT INTO chat_message_join VALUES (1,?)", (one,))
    records = MessageReader(path).get_recent_messages("+15550109999")
    assert [r.id for r in records] == [str(one), str(two)]
    assert [r.text for r in records] == ["Hi", "Hello"]
    assert records[-1].is_from_me
    assert records[-1].source == f"chat.db#message/{two}"


def test_archived_text_and_unsupported_content(messages_db):
    path, add = messages_db
    add(None, 800000000, blob=archive("Chào mẹ 😊"))
    add("stale text", 800000001, blob=b"unsupported archive")
    add(None, 800000002, attachment=1)
    records = MessageReader(path).get_recent_messages("+15550109999")
    assert records[0].text == "Chào mẹ 😊"
    assert records[1].text == "" and records[1].content_status == "unavailable"
    assert records[2].content_status == "attachment"
    assert decode_body(b"bad") is None
    assert decode_body(b"x" * 2000001) is None


def test_reactions_service_deleted_retracted_excluded(messages_db):
    path, add = messages_db
    add("Keep", 800000000)
    add("Liked", 800000001, reaction=2000)
    add("Service", 800000002, item_type=1)
    add("Deleted", 800000003, deleted=1)
    add("Unsent", 800000004, retracted=1)
    assert [m.text for m in MessageReader(path).get_recent_messages("+15550109999")] == ["Keep"]


def test_limit_and_truncation(messages_db):
    path, add = messages_db
    add("old", 800000000)
    add("x" * 5000, 800000001)
    records = MessageReader(path).get_recent_messages("+15550109999", 1)
    assert len(records) == 1 and len(records[0].text) == 4000 and records[0].truncated
    for limit in (0, 101, True):
        with pytest.raises(ValueError):
            MessageReader(path).get_recent_messages("+15550109999", limit)


def test_read_only_and_missing_db(messages_db, tmp_path):
    path, add = messages_db
    add("Test", 800000000)
    before = path.read_bytes()
    reader = MessageReader(path)
    assert reader.has_access()
    reader.get_recent_messages("+15550109999")
    assert path.read_bytes() == before
    with pytest.raises(MessageReaderError), reader._connection() as db:
        db.execute("DELETE FROM message")
    missing = tmp_path / "does-not-exist.db"
    assert not MessageReader(missing).has_access()
    assert not missing.exists()


def test_unsupported_schema_and_permission_error(tmp_path, monkeypatch):
    path = tmp_path / "chat.db"
    with sqlite3.connect(path) as db:
        db.execute("CREATE TABLE unrelated (value TEXT)")
    with pytest.raises(MessageReaderError, match="schema"):
        MessageReader(path).get_recent_messages("+15550109999")

    def denied(*args, **kwargs):
        raise sqlite3.OperationalError("permission denied")

    monkeypatch.setattr("imsg_agent.reader.sqlite3.connect", denied)
    with pytest.raises(MessageReaderError, match="Full Disk Access"):
        MessageReader(path).get_recent_messages("+15550109999")


def test_older_schema_without_optional_columns(tmp_path):
    path = tmp_path / "old.db"
    with sqlite3.connect(path) as db:
        db.executescript("""CREATE TABLE message(date INTEGER,is_from_me INTEGER,handle_id INTEGER,text TEXT);
            CREATE TABLE chat(style INTEGER); INSERT INTO chat VALUES (45);
            CREATE TABLE handle(id TEXT); CREATE TABLE chat_handle_join(chat_id INTEGER,handle_id INTEGER);
            CREATE TABLE chat_message_join(chat_id INTEGER,message_id INTEGER);
            INSERT INTO handle VALUES ('+15550109999'); INSERT INTO chat_handle_join VALUES (1,1);
            INSERT INTO message VALUES (800000000,0,1,'Old schema'); INSERT INTO chat_message_join VALUES (1,1);""")
    assert MessageReader(path).get_recent_messages("+15550109999")[0].text == "Old schema"


def test_timestamps():
    assert apple_time(0) == datetime(2001, 1, 1, tzinfo=UTC)
    assert apple_time(800000000) == apple_time(800000000000000000)
    with pytest.raises(MessageReaderError):
        apple_time("invalid")


def test_conversations_only_direct_phones(messages_db):
    path, add = messages_db
    add("Mom", 800000000)
    add("John", 800000001, chat=2, handle=2)
    add("Email", 800000002, chat=5, handle=4)
    summaries = MessageReader(path).get_conversations()
    assert [c.contact for c in summaries] == ["+15550108888", "+15550109999"]


def test_live_wal_rows_read_without_ignoring_wal(messages_db):
    path, _ = messages_db
    db = sqlite3.connect(path)
    try:
        db.execute("PRAGMA journal_mode=WAL")
        db.execute(
            'INSERT INTO message(date,is_from_me,handle_id,text) VALUES (800000000,0,1,"WAL message")'
        )
        db.execute("INSERT INTO chat_message_join VALUES (1,1)")
        db.commit()
        assert Path(str(path) + "-wal").exists()
        assert MessageReader(path).get_recent_messages("+15550109999")[0].text == "WAL message"
    finally:
        db.close()


def test_malformed_archives_fail_without_inventing_text():
    for data in (b"", b"not an archive", archive("hi")[:-3], b"\x04\x0bstreamtyped", b"\x00\x00"):
        assert decode_body(data) is None


def test_history_invalid_phone_never_opens_db(messages_db, monkeypatch):
    reader = MessageReader(messages_db[0])

    def fail():
        raise AssertionError("Should not open")

    monkeypatch.setattr(reader, "_connection", fail)
    with pytest.raises(ValueError):
        reader.get_recent_messages("+1' OR 1=1 --")


@pytest.mark.parametrize("style", [43, 999, None])
def test_single_participant_is_not_enough_to_identify_direct_chat(messages_db, style):
    path, add = messages_db
    add("Must not enter a direct reply", 800000000)
    with sqlite3.connect(path) as db:
        db.execute("UPDATE chat SET style=? WHERE ROWID=1", (style,))
    reader = MessageReader(path)
    assert reader.get_recent_messages("+15550109999") == []
    assert reader.get_conversations() == []


def test_missing_chat_type_fails_closed(messages_db):
    path, add = messages_db
    add("Unknown chat type", 800000000)
    with sqlite3.connect(path) as db:
        db.execute("DROP TABLE chat")
    with pytest.raises(MessageReaderError, match="schema: chat"):
        MessageReader(path).get_recent_messages("+15550109999")
