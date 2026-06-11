"""Coalescer/Throttle/MainThreadBus logic — pure, runs anywhere."""

from __future__ import annotations

import threading

from murmur.uibus import Coalescer, Throttle, UiEvent, MainThreadBus


class TestCoalescer:
    def test_first_post_reports_dirty(self):
        c = Coalescer()
        assert c.post(UiEvent.DRAFT, "hello") is True

    def test_posts_while_dirty_do_not_reschedule(self):
        c = Coalescer()
        c.post(UiEvent.DRAFT, "one")
        assert c.post(UiEvent.DRAFT, "two") is False
        assert c.post(UiEvent.STATE, "recording") is False

    def test_latest_payload_wins_per_event(self):
        c = Coalescer()
        c.post(UiEvent.DRAFT, "one")
        c.post(UiEvent.DRAFT, "two")
        assert c.drain() == {UiEvent.DRAFT: "two"}

    def test_distinct_events_all_survive_a_burst(self):
        # A STATE change must never be lost behind a DRAFT (per-channel mailbox).
        c = Coalescer()
        c.post(UiEvent.DRAFT, "words")
        c.post(UiEvent.STATE, "transcribing")
        c.post(UiEvent.LEVEL, 0.5)
        assert c.drain() == {
            UiEvent.DRAFT: "words",
            UiEvent.STATE: "transcribing",
            UiEvent.LEVEL: 0.5,
        }

    def test_drain_clears_and_rearms(self):
        c = Coalescer()
        c.post(UiEvent.DRAFT, "one")
        c.drain()
        assert c.drain() == {}
        assert c.post(UiEvent.DRAFT, "two") is True

    def test_none_payload_is_a_valid_value(self):
        c = Coalescer()
        c.post(UiEvent.RESULT, None)
        assert c.drain() == {UiEvent.RESULT: None}

    def test_concurrent_posts_never_lose_the_wakeup(self):
        # However threads interleave, a burst yields >=1 True and after one
        # drain every event type posted is present.
        c = Coalescer()
        wakeups = []

        def worker(i: int) -> None:
            wakeups.append(c.post(UiEvent.LEVEL, i))

        threads = [threading.Thread(target=worker, args=(i,)) for i in range(32)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        assert wakeups.count(True) == 1
        assert UiEvent.LEVEL in c.drain()


class TestThrottle:
    def test_first_call_is_ready(self):
        clock = FakeClock()
        t = Throttle(0.1, clock=clock)
        assert t.ready() is True

    def test_blocks_within_interval(self):
        clock = FakeClock()
        t = Throttle(0.1, clock=clock)
        t.ready()
        clock.advance(0.05)
        assert t.ready() is False

    def test_reopens_after_interval(self):
        clock = FakeClock()
        t = Throttle(0.1, clock=clock)
        t.ready()
        clock.advance(0.05)
        t.ready()  # denied; must not reset the window
        clock.advance(0.06)
        assert t.ready() is True


class FakeClock:
    def __init__(self) -> None:
        self.now = 100.0

    def __call__(self) -> float:
        return self.now

    def advance(self, s: float) -> None:
        self.now += s


class TestMainThreadBus:
    def make_bus(self):
        scheduled: list = []
        rendered: list = []
        bus = MainThreadBus(rendered.append, schedule=scheduled.append)
        return bus, scheduled, rendered

    def test_burst_schedules_exactly_one_dispatch(self):
        bus, scheduled, rendered = self.make_bus()
        for i in range(10):
            bus.post(UiEvent.DRAFT, f"draft {i}")
        bus.post(UiEvent.STATE, "recording")
        assert len(scheduled) == 1
        scheduled[0]()
        assert rendered == [
            {UiEvent.DRAFT: "draft 9", UiEvent.STATE: "recording"}
        ]

    def test_reschedules_after_drain(self):
        bus, scheduled, rendered = self.make_bus()
        bus.post(UiEvent.DRAFT, "one")
        scheduled[0]()
        bus.post(UiEvent.DRAFT, "two")
        assert len(scheduled) == 2

    def test_render_exception_kills_the_bus_not_the_caller(self):
        scheduled: list = []

        def bad_render(_payloads) -> None:
            raise RuntimeError("HUD broke")

        bus = MainThreadBus(bad_render, schedule=scheduled.append)
        bus.post(UiEvent.DRAFT, "one")
        scheduled[0]()  # must swallow the exception
        bus.post(UiEvent.DRAFT, "two")  # dead bus: no-op
        assert len(scheduled) == 1

    def test_schedule_exception_kills_the_bus_not_the_caller(self):
        def bad_schedule(_fn) -> None:
            raise RuntimeError("no run loop")

        bus = MainThreadBus(lambda p: None, schedule=bad_schedule)
        bus.post(UiEvent.DRAFT, "one")  # must not raise
        bus.post(UiEvent.DRAFT, "two")  # dead bus: no-op
