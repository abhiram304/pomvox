"""The config.toml mtime watcher (M2a).

``ConfigWatcher`` is pure debounce logic — platform-free, unit-tested here.
``ConfigWatchThread`` is the thin polling thread; one integration test pins
that an edit actually fires the callback. Both are Linux-safe (os.stat only).
"""

import threading
from pathlib import Path

from pomvox.watcher import ConfigWatcher, ConfigWatchThread


def test_unchanged_mtime_never_fires():
    w = ConfigWatcher(100.0)
    assert w.poll(100.0) is False
    assert w.poll(100.0) is False


def test_changed_mtime_fires_once():
    w = ConfigWatcher(100.0)
    assert w.poll(101.0) is True
    assert w.poll(101.0) is False  # same new value — debounced


def test_file_created_fires():
    w = ConfigWatcher(None)  # file absent at startup
    assert w.poll(50.0) is True


def test_deletion_does_not_fire_but_recreation_does():
    w = ConfigWatcher(100.0)
    assert w.poll(None) is False  # deleted — keep current config
    assert w.poll(100.0) is True  # recreated — apply again


def test_successive_edits_each_fire():
    w = ConfigWatcher(100.0)
    assert w.poll(101.0) is True
    assert w.poll(102.0) is True
    assert w.poll(102.0) is False


def test_watch_thread_fires_on_real_edit(tmp_path: Path):
    cfg = tmp_path / "config.toml"
    cfg.write_text("[cleanup]\nstyle = \"polish\"\n")
    fired = threading.Event()

    thread = ConfigWatchThread(cfg, on_change=fired.set, interval=0.02)
    thread.start()
    try:
        # Bump mtime well past the starting value, then edit.
        import os
        import time

        time.sleep(0.05)
        os.utime(cfg, (time.time() + 5, time.time() + 5))
        assert fired.wait(timeout=2.0), "watcher did not fire on edit"
    finally:
        thread.stop()


def test_watch_thread_stop_is_idempotent(tmp_path: Path):
    cfg = tmp_path / "config.toml"
    cfg.write_text("x = 1\n")
    thread = ConfigWatchThread(cfg, on_change=lambda: None, interval=0.02)
    thread.start()
    thread.stop()
    thread.stop()  # must not raise
