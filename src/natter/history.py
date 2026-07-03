"""Local dictation history: sqlite, transcripts only, bounded retention.

Privacy posture is the design: no audio is ever stored; rows auto-expire
after ``retention_days`` (0 = keep nothing); the file is user-only (0600)
and inspectable with any sqlite client; ``enabled=false`` writes nothing.
Wispr Flow keeps transcript text in their cloud permanently — bounded
local retention is the counter-feature, stated in the UI.

:class:`HistoryStore` is pure SQL/retention/search (Linux-tested). Writes
happen on the STT worker *after* insertion and ``machine.done()`` — a
single-row INSERT on an idle thread, strictly off the latency path, and
every store error is log-and-continue (history must never cost a word).

The history UI now lives in the native Hub (Natter.app, M3), which reads this
same file read-only; the old PyObjC ``HistoryWindow`` was retired with it.
"""

from __future__ import annotations

import logging
import os
import sqlite3
import threading
from dataclasses import dataclass
from pathlib import Path

log = logging.getLogger(__name__)

DEFAULT_PATH = Path.home() / ".natter" / "history.db"

_SCHEMA = """
CREATE TABLE IF NOT EXISTS history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts REAL NOT NULL,
    raw_text TEXT NOT NULL,
    final_text TEXT NOT NULL,
    cleanup_status TEXT NOT NULL,
    app_hint TEXT,             -- NULL until Phase 4 context.py lands
    duration_s REAL,
    timings_json TEXT
);
CREATE INDEX IF NOT EXISTS idx_history_ts ON history(ts);
"""


@dataclass(frozen=True)
class HistoryRow:
    id: int
    ts: float
    raw_text: str
    final_text: str
    cleanup_status: str
    app_hint: str | None
    duration_s: float | None


class HistoryStore:
    """All SQL and retention math; one connection, serialized by a lock
    (writes come from the STT worker, reads from the main thread)."""

    def __init__(self, path: Path | str = DEFAULT_PATH, retention_days: int = 7):
        self._path = Path(path)
        self.retention_days = retention_days
        self._lock = threading.Lock()
        self._path.parent.mkdir(parents=True, exist_ok=True)
        existed = self._path.exists()
        self._db = sqlite3.connect(self._path, check_same_thread=False)
        self._db.execute("PRAGMA journal_mode=WAL")
        # Schema-contract version for the native Hub, which reads this DB in a
        # separate process (Natter.app, M1). Bump only with a coordinated change
        # on both sides; the columns the Hub reads are frozen at v1.
        self._db.execute("PRAGMA user_version=1")
        self._db.executescript(_SCHEMA)
        self._db.commit()
        if not existed:
            os.chmod(self._path, 0o600)

    def add(
        self,
        ts: float,
        raw_text: str,
        final_text: str,
        cleanup_status: str,
        duration_s: float | None = None,
        timings_json: str = "",
        app_hint: str | None = None,
    ) -> None:
        with self._lock:
            self._db.execute(
                "INSERT INTO history "
                "(ts, raw_text, final_text, cleanup_status, app_hint, duration_s, timings_json) "
                "VALUES (?, ?, ?, ?, ?, ?, ?)",
                (ts, raw_text, final_text, cleanup_status, app_hint, duration_s, timings_json),
            )
            self._db.commit()

    def list(self, query: str = "", limit: int = 200) -> list[HistoryRow]:
        sql = (
            "SELECT id, ts, raw_text, final_text, cleanup_status, app_hint, duration_s "
            "FROM history"
        )
        args: tuple = ()
        if query:
            sql += " WHERE raw_text LIKE ? COLLATE NOCASE OR final_text LIKE ? COLLATE NOCASE"
            like = f"%{query}%"
            args = (like, like)
        sql += " ORDER BY ts DESC LIMIT ?"
        with self._lock:
            rows = self._db.execute(sql, args + (limit,)).fetchall()
        return [HistoryRow(*r) for r in rows]

    def purge(self, now: float) -> int:
        """Delete rows older than the retention window; returns the count."""
        cutoff = now - self.retention_days * 86400
        with self._lock:
            cur = self._db.execute("DELETE FROM history WHERE ts < ?", (cutoff,))
            self._db.commit()
        if cur.rowcount:
            log.info("history: purged %d rows past %dd retention",
                     cur.rowcount, self.retention_days)
        return cur.rowcount

    def delete(self, row_id: int) -> None:
        with self._lock:
            self._db.execute("DELETE FROM history WHERE id = ?", (row_id,))
            self._db.commit()

    def delete_all(self) -> None:
        with self._lock:
            self._db.execute("DELETE FROM history")
            self._db.commit()
        log.info("history: cleared")

    def close(self) -> None:
        with self._lock:
            self._db.close()
