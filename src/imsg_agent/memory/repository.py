"""Persistence separate from delivery logs; forgetting removes linked draft examples."""

from uuid import uuid4

from imsg_agent.models import utc_now


class MemoryRepository:
    def __init__(self, store):
        self.store = store
        with store._connection() as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS memory_revision (
                    id INTEGER PRIMARY KEY CHECK (id=1), version INTEGER NOT NULL);
                INSERT OR IGNORE INTO memory_revision VALUES (1,0);
                CREATE TABLE IF NOT EXISTS preferences (
                    id TEXT PRIMARY KEY, scope TEXT NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL,
                    source TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
                    approved INTEGER NOT NULL CHECK (approved IN (0,1)),
                    UNIQUE(scope,key));
                CREATE TABLE IF NOT EXISTS preference_feedback (
                    id TEXT PRIMARY KEY, scope TEXT NOT NULL, original TEXT NOT NULL,
                    corrected TEXT NOT NULL, proposed_key TEXT, proposed_value TEXT,
                    preference_id TEXT, status TEXT NOT NULL, created_at TEXT NOT NULL);
                CREATE INDEX IF NOT EXISTS feedback_preference ON preference_feedback(preference_id);
            """)

    def revision(self):
        with self.store._connection() as db:
            return db.execute("SELECT version FROM memory_revision WHERE id=1").fetchone()[0]

    def list(self, scope=None):
        with self.store._connection() as db:
            rows = db.execute(
                "SELECT * FROM preferences"
                + (" WHERE scope=?" if scope else "")
                + " ORDER BY scope,key",
                (scope,) if scope else (),
            ).fetchall()
        return [dict(row) for row in rows]

    def get(self, id):
        with self.store._connection() as db:
            row = db.execute("SELECT * FROM preferences WHERE id=?", (id,)).fetchone()
        return dict(row) if row else None

    def save(self, scope, preference, source="explicit", expected=None, feedback_id=None):
        """Compare the confirmed old row under transaction to prevent silent overwrites."""
        now = utc_now().isoformat()
        with self.store._connection() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute(
                "SELECT * FROM preferences WHERE scope=? AND key=?", (scope, preference.key)
            ).fetchone()
            actual = dict(row) if row else None
            if actual != expected:
                raise ValueError("Preference changed while you were confirming; review it again")
            id = actual["id"] if actual else "pref-" + uuid4().hex
            if feedback_id:
                feedback = db.execute(
                    "SELECT * FROM preference_feedback WHERE id=?", (feedback_id,)
                ).fetchone()
                if (
                    not feedback
                    or feedback["status"] != "proposed"
                    or feedback["scope"] != scope
                    or feedback["proposed_key"] != preference.key
                    or feedback["proposed_value"] != preference.value
                ):
                    raise ValueError("Feedback proposal is missing, changed, or already resolved")
            if actual:
                db.execute(
                    "UPDATE preferences SET value=?,source=?,updated_at=?,approved=1 WHERE id=?",
                    (preference.value, source, now, id),
                )
            else:
                db.execute(
                    "INSERT INTO preferences VALUES (?,?,?,?,?,?,?,1)",
                    (id, scope, preference.key, preference.value, source, now, now),
                )
            if feedback_id:
                db.execute(
                    "UPDATE preference_feedback SET preference_id=?,status='approved' WHERE id=?",
                    (id, feedback_id),
                )
            db.execute("UPDATE memory_revision SET version=version+1 WHERE id=1")
        return self.get(id)

    def forget(self, id, expected):
        with self.store._connection() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT * FROM preferences WHERE id=?", (id,)).fetchone()
            if row is None or dict(row) != expected:
                raise ValueError("Preference changed; review it again")
            # Remove both linked examples and pending examples for the same preference slot.
            db.execute(
                "DELETE FROM preference_feedback WHERE preference_id=? OR (scope=? AND proposed_key=?)",
                (id, row["scope"], row["key"]),
            )
            db.execute("DELETE FROM preferences WHERE id=?", (id,))
            db.execute("UPDATE memory_revision SET version=version+1 WHERE id=1")

    def add_feedback(self, scope, original, corrected, proposal):
        id = "feedback-" + uuid4().hex
        with self.store._connection() as db:
            db.execute(
                "INSERT INTO preference_feedback VALUES (?,?,?,?,?,?,NULL,?,?)",
                (
                    id,
                    scope,
                    original,
                    corrected,
                    proposal.key if proposal else None,
                    proposal.value if proposal else None,
                    "proposed" if proposal else "recorded",
                    utc_now().isoformat(),
                ),
            )
        return self.feedback(id)

    def feedback(self, id=None):
        with self.store._connection() as db:
            rows = db.execute(
                "SELECT * FROM preference_feedback"
                + (" WHERE id=?" if id else "")
                + " ORDER BY created_at",
                (id,) if id else (),
            ).fetchall()
        results = [dict(r) for r in rows]
        return (results[0] if results else None) if id else results

    def delete_feedback(self, id):
        with self.store._connection() as db:
            db.execute("DELETE FROM preference_feedback WHERE id=?", (id,))
