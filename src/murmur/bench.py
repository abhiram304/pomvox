"""Per-utterance stage timing collection (SPEC §6).

Phase 1 collects and logs; the full `--bench` report is Phase 6. Stages are
measured from recording stop (the moment the user releases the hotkey).
"""

from __future__ import annotations

import json
import logging
import time

log = logging.getLogger(__name__)


class Timings:
    """Stamps named stages for one utterance, relative to recording stop."""

    def __init__(self, clock=time.perf_counter) -> None:
        self._clock = clock
        self._t0: float | None = None
        self._stamps: list[tuple[str, float]] = []

    def start(self) -> None:
        """Mark t0 = recording stop."""
        self._t0 = self._clock()
        self._stamps = []

    def stamp(self, name: str) -> None:
        self._stamps.append((name, self._clock()))

    def stages_ms(self) -> dict[str, float]:
        """Per-stage durations (each relative to the previous stamp) + total."""
        if self._t0 is None:
            return {}
        out: dict[str, float] = {}
        prev = self._t0
        for name, t in self._stamps:
            out[name] = (t - prev) * 1000.0
            prev = t
        if self._stamps:
            out["total"] = (self._stamps[-1][1] - self._t0) * 1000.0
        return out

    def summary(self) -> str:
        return " ".join(f"{name}={ms:.0f}ms" for name, ms in self.stages_ms().items())


class BenchLog:
    """Accumulates utterance records; JSON-exportable for the Phase 6 report."""

    def __init__(self) -> None:
        self.records: list[dict[str, float]] = []

    def add(self, timings: Timings) -> None:
        stages = timings.stages_ms()
        if not stages:
            return
        self.records.append(stages)
        log.info("bench: %s", timings.summary())

    def export_json(self) -> str:
        return json.dumps(self.records, indent=2)
