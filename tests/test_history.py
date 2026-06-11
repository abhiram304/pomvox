"""HistoryStore — pure SQL/retention/search, runs anywhere."""

from __future__ import annotations

from murmur.history import HistoryStore


def store(tmp_path, **kw):
    defaults = dict(retention_days=7)
    defaults.update(kw)
    return HistoryStore(tmp_path / "history.db", **defaults)


def add(s, ts, raw="raw words", final="Final words.", status="ok"):
    s.add(ts=ts, raw_text=raw, final_text=final, cleanup_status=status,
          duration_s=2.5, timings_json="{}")


def test_add_and_list_newest_first(tmp_path):
    s = store(tmp_path)
    add(s, ts=1000.0, final="first")
    add(s, ts=2000.0, final="second")
    rows = s.list()
    assert [r.final_text for r in rows] == ["second", "first"]
    assert rows[0].raw_text == "raw words"
    assert rows[0].cleanup_status == "ok"


def test_search_matches_raw_and_final(tmp_path):
    s = store(tmp_path)
    add(s, ts=1.0, raw="buy some flour", final="Buy flour.")
    add(s, ts=2.0, raw="unrelated", final="Unrelated.")
    assert [r.ts for r in s.list(query="flour")] == [1.0]
    assert s.list(query="FLOUR")  # case-insensitive
    assert s.list(query="nothing-matches") == []


def test_purge_removes_rows_older_than_retention(tmp_path):
    s = store(tmp_path, retention_days=7)
    now = 1_000_000.0
    week = 7 * 86400
    add(s, ts=now - week - 60)   # just past retention
    add(s, ts=now - 3600)        # recent
    s.purge(now=now)
    assert len(s.list()) == 1


def test_retention_zero_keeps_nothing(tmp_path):
    s = store(tmp_path, retention_days=0)
    add(s, ts=999.0)
    s.purge(now=1000.0)
    assert s.list() == []


def test_delete_one_and_delete_all(tmp_path):
    s = store(tmp_path)
    add(s, ts=1.0)
    add(s, ts=2.0)
    rows = s.list()
    s.delete(rows[0].id)
    assert len(s.list()) == 1
    s.delete_all()
    assert s.list() == []


def test_list_is_bounded(tmp_path):
    s = store(tmp_path)
    for i in range(250):
        add(s, ts=float(i))
    assert len(s.list(limit=200)) == 200


def test_db_file_is_user_only(tmp_path):
    s = store(tmp_path)
    add(s, ts=1.0)
    mode = (tmp_path / "history.db").stat().st_mode & 0o777
    assert mode == 0o600
