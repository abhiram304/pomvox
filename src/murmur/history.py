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
The window (``HistoryWindow``) is a dumb renderer, main thread only.
"""

from __future__ import annotations

import logging
import os
import sqlite3
import threading
from dataclasses import dataclass
from pathlib import Path

log = logging.getLogger(__name__)

DEFAULT_PATH = Path.home() / ".murmur" / "history.db"

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
        # separate process (Murmur.app, M1). Bump only with a coordinated change
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


def format_ts(ts: float) -> str:
    """Row timestamp for the table, local time."""
    from datetime import datetime

    return datetime.fromtimestamp(ts).strftime("%b %d  %H:%M")


_DS_CLS = None


def _datasource_class():
    """Table datasource + button actions need an NSObject; register once."""
    global _DS_CLS
    if _DS_CLS is None:
        from Foundation import NSObject

        class _HistoryDS(NSObject):
            def numberOfRowsInTableView_(self, _tv):
                return len(self.owner.rows)

            def tableView_objectValueForTableColumn_row_(self, _tv, col, i):
                r = self.owner.rows[i]
                key = str(col.identifier())
                if key == "when":
                    return format_ts(r.ts)
                if key == "final":
                    return r.final_text
                if key == "raw":
                    return r.raw_text
                return r.cleanup_status

            def search_(self, sender):
                self.owner._search(str(sender.stringValue()))

            def copyRow_(self, _s):
                self.owner._copy_selected()

            def reinsertRow_(self, _s):
                self.owner._reinsert_selected()

            def deleteRow_(self, _s):
                self.owner._delete_selected()

            def deleteAll_(self, _s):
                self.owner._delete_all()

        _DS_CLS = _HistoryDS
    return _DS_CLS


class HistoryWindow:
    """Dumb renderer over :class:`HistoryStore`. Main thread only; opened
    from the menu bar, gated on dictation being idle (it activates us)."""

    WIDTH, HEIGHT = 760.0, 440.0

    def __init__(self, store: HistoryStore, on_reinsert) -> None:
        # on_reinsert(text): controller schedules the countdown + insert.
        self._store = store
        self._on_reinsert = on_reinsert
        self._window = None
        self._table = None
        self._status_label = None
        self._query = ""
        self.rows: list[HistoryRow] = []

    def show(self) -> None:
        from AppKit import NSApp

        if self._window is None:
            self._build()
        self.reload()
        self._window.makeKeyAndOrderFront_(None)
        NSApp.activateIgnoringOtherApps_(True)

    def reload(self) -> None:
        self.rows = self._store.list(query=self._query)
        self._table.reloadData()
        self._status_label.setStringValue_(
            f"{len(self.rows)} dictations · auto-deletes after "
            f"{self._store.retention_days} days · audio is never stored"
        )

    # -- actions -----------------------------------------------------------

    def _search(self, query: str) -> None:
        self._query = query
        self.reload()

    def _selected(self) -> HistoryRow | None:
        i = self._table.selectedRow()
        return self.rows[i] if 0 <= i < len(self.rows) else None

    def _copy_selected(self) -> None:
        row = self._selected()
        if row is None:
            return
        from AppKit import NSPasteboard, NSPasteboardTypeString

        pb = NSPasteboard.generalPasteboard()
        pb.clearContents()
        pb.setString_forType_(row.final_text, NSPasteboardTypeString)
        log.info("history: copied row %d", row.id)

    def _reinsert_selected(self) -> None:
        row = self._selected()
        if row is None:
            return
        self._status_label.setStringValue_(
            "Click into your target text field — inserting in 3 s…"
        )
        self._on_reinsert(row.final_text)

    def _delete_selected(self) -> None:
        row = self._selected()
        if row is None:
            return
        self._store.delete(row.id)
        self.reload()

    def _delete_all(self) -> None:
        from AppKit import NSAlert

        alert = NSAlert.alloc().init()
        alert.setMessageText_("Delete all dictation history?")
        alert.setInformativeText_("This cannot be undone.")
        alert.addButtonWithTitle_("Delete All")
        alert.addButtonWithTitle_("Cancel")
        if alert.runModal() == 1000:  # NSAlertFirstButtonReturn
            self._store.delete_all()
            self.reload()

    # -- construction ------------------------------------------------------

    def _build(self) -> None:
        from AppKit import (
            NSBackingStoreBuffered,
            NSButton,
            NSScrollView,
            NSSearchField,
            NSTableColumn,
            NSTableView,
            NSTextField,
            NSWindow,
            NSWindowStyleMaskClosable,
            NSWindowStyleMaskResizable,
            NSWindowStyleMaskTitled,
        )
        from Foundation import NSMakeRect

        w, h = self.WIDTH, self.HEIGHT
        window = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            NSMakeRect(0, 0, w, h),
            NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable,
            NSBackingStoreBuffered,
            False,
        )
        window.setTitle_("Murmur History")
        window.setReleasedWhenClosed_(False)
        window.center()
        content = window.contentView()

        self._ds = _datasource_class().alloc().init()
        self._ds.owner = self

        search = NSSearchField.alloc().initWithFrame_(NSMakeRect(16, h - 44, 300, 28))
        search.setTarget_(self._ds)
        search.setAction_("search:")
        search.setPlaceholderString_("Search dictations")
        content.addSubview_(search)

        table = NSTableView.alloc().initWithFrame_(NSMakeRect(0, 0, w - 32, h - 140))
        for key, title, width in (
            ("when", "When", 110),
            ("final", "Cleaned", 280),
            ("raw", "Raw", 230),
            ("status", "Cleanup", 60),
        ):
            col = NSTableColumn.alloc().initWithIdentifier_(key)
            col.setTitle_(title)
            col.setWidth_(width)
            table.addTableColumn_(col)
        table.setDataSource_(self._ds)
        table.setUsesAlternatingRowBackgroundColors_(True)
        scroll = NSScrollView.alloc().initWithFrame_(NSMakeRect(16, 92, w - 32, h - 148))
        scroll.setDocumentView_(table)
        scroll.setHasVerticalScroller_(True)
        scroll.setAutoresizingMask_(18)  # width + height sizable
        content.addSubview_(scroll)
        self._table = table

        x = 16.0
        for title, action in (
            ("Copy", "copyRow:"),
            ("Re-insert", "reinsertRow:"),
            ("Delete", "deleteRow:"),
            ("Delete All", "deleteAll:"),
        ):
            btn = NSButton.buttonWithTitle_target_action_(title, self._ds, action)
            btn.setFrame_(NSMakeRect(x, 48, 110, 30))
            content.addSubview_(btn)
            x += 120

        label = NSTextField.labelWithString_("")
        label.setFrame_(NSMakeRect(16, 16, w - 32, 18))
        from AppKit import NSColor, NSFont

        label.setFont_(NSFont.systemFontOfSize_(11.0))
        label.setTextColor_(NSColor.secondaryLabelColor())
        content.addSubview_(label)
        self._status_label = label

        self._window = window
