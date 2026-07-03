"""Cross-thread UI event spine: coalesce on any thread, render on the main one.

Producers (the STT worker, the audio callback, the event tap) call
``MainThreadBus.post`` — a dict assignment plus, at most, one main-thread
wake-up per burst. They never block and never touch AppKit. The main thread
drains the mailbox and renders. A failure anywhere in the UI path flips the
bus dead and dictation continues without it: the pipeline never waits on,
and can never be broken by, the UI.

Everything except ``MainThreadBus``'s default scheduler is pure logic,
unit-tested on any platform.
"""

from __future__ import annotations

import enum
import logging
import threading
import time
from typing import Any, Callable

log = logging.getLogger(__name__)


class UiEvent(enum.Enum):
    STATE = "state"
    DRAFT = "draft"
    LEVEL = "level"
    ENDPOINT_PROGRESS = "endpoint_progress"
    RESULT = "result"
    ERROR = "error"


class Coalescer:
    """Latest-wins mailbox per event type, with a dirty flag.

    ``post`` returns True only when a main-thread wake-up must be scheduled,
    so a burst of N posts costs exactly one dispatch; payloads posted while
    dirty overwrite their channel and ride the pending wake-up.
    """

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._pending: dict[UiEvent, Any] = {}
        self._dirty = False

    def post(self, event: UiEvent, payload: Any) -> bool:
        with self._lock:
            self._pending[event] = payload
            was_dirty, self._dirty = self._dirty, True
            return not was_dirty

    def drain(self) -> dict[UiEvent, Any]:
        with self._lock:
            pending, self._pending = self._pending, {}
            self._dirty = False
            return pending


class Throttle:
    """Minimum-interval gate on a monotonic clock (injectable for tests)."""

    def __init__(self, min_interval_s: float, clock: Callable[[], float] = time.monotonic):
        self._min_interval_s = min_interval_s
        self._clock = clock
        self._last: float | None = None

    def ready(self) -> bool:
        now = self._clock()
        if self._last is not None and now - self._last < self._min_interval_s:
            return False
        self._last = now
        return True


def _call_after(fn: Callable[[], None]) -> None:
    from PyObjCTools import AppHelper

    AppHelper.callAfter(fn)


class MainThreadBus:
    """Fire-and-forget bridge from worker threads to a main-thread renderer.

    ``render`` receives the drained ``{UiEvent: payload}`` dict on the main
    thread. The first exception in scheduling or rendering logs once and
    kills the bus (every later ``post`` is a no-op) — a broken UI must
    degrade to nothing, not into the dictation path.
    """

    def __init__(
        self,
        render: Callable[[dict[UiEvent, Any]], None],
        schedule: Callable[[Callable[[], None]], None] | None = None,
    ) -> None:
        self._coalescer = Coalescer()
        self._render = render
        self._schedule = schedule or _call_after
        self._dead = False

    def post(self, event: UiEvent, payload: Any) -> None:
        if self._dead:
            return
        try:
            if self._coalescer.post(event, payload):
                self._schedule(self._drain_and_render)
        except Exception:
            self._die()

    def _drain_and_render(self) -> None:
        if self._dead:
            return
        try:
            self._render(self._coalescer.drain())
        except Exception:
            self._die()

    def _die(self) -> None:
        self._dead = True
        log.exception("uibus: UI render path failed — HUD disabled, dictation unaffected")
