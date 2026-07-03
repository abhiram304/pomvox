"""Watch ``~/.pomvox/config.toml`` for edits and hot-reload (M2a).

The native Hub writes config.toml; this watcher is the other half of the
cross-process contract — a ~1 Hz mtime poll that re-runs the existing
``Controller._reload_config`` path when the file changes. No IPC.

:class:`ConfigWatcher` is pure debounce logic (platform-free, unit-tested).
:class:`ConfigWatchThread` is the thin polling thread; it never touches the
pipeline. The ``on_change`` callback is responsible for any thread marshaling
(``_reload_config`` touches the rumps UI, so app.py hops to the main thread).

Polling beats fsevents/watchdog here: one ``os.stat`` per second is cheaper
than a framework dependency, and the Hub's atomic save (temp + rename) means
a poll never sees a half-written file.
"""

from __future__ import annotations

import logging
import threading
from pathlib import Path

log = logging.getLogger(__name__)


class ConfigWatcher:
    """Tracks the last seen mtime; :meth:`poll` decides when to fire.

    Fires once per distinct, non-``None`` mtime. A deletion (``None``) is not
    a reload — the running config stays — but it updates the baseline so a
    later recreation fires.
    """

    def __init__(self, mtime: float | None) -> None:
        self._last = mtime

    def poll(self, mtime: float | None) -> bool:
        if mtime != self._last:
            self._last = mtime
            return mtime is not None
        return False


def _mtime(path: Path) -> float | None:
    try:
        return path.stat().st_mtime
    except OSError:
        return None


class ConfigWatchThread:
    """Daemon thread polling *path*'s mtime, calling *on_change* on edits."""

    def __init__(self, path: Path, on_change, interval: float = 1.0) -> None:
        self._path = path
        self._on_change = on_change
        self._interval = interval
        self._watcher = ConfigWatcher(_mtime(path))
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        if self._thread is not None:
            return
        self._thread = threading.Thread(
            target=self._run, name="config-watcher", daemon=True
        )
        self._thread.start()
        log.info("config: watching %s for edits", self._path)

    def _run(self) -> None:
        # stop.wait doubles as the sleep, so stop() interrupts it immediately.
        while not self._stop.wait(self._interval):
            if self._watcher.poll(_mtime(self._path)):
                try:
                    self._on_change()
                except Exception:
                    log.exception("config: watcher callback failed")

    def stop(self) -> None:
        self._stop.set()
        thread, self._thread = self._thread, None
        if thread is not None:
            thread.join(timeout=2.0)
