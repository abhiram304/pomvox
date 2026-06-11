"""Voice activity detection for auto-stop endpointing (Phase 2, webrtcvad).

Pure logic at module level — :class:`FrameSlicer` (float32 blocks → int16
frames, buffered **by samples** so the Silero swap is a constructor arg, not
a rewrite), :class:`EndpointDetector` (hangover state machine; a frame only
counts as voiced when the VAD vote **and** an energy gate agree, because
webrtcvad is trigger-happy on breath and keyboard noise), and
:class:`Endpointer` (per-session composition with a hard session cap).
:class:`WebrtcBackend` is the only piece that imports webrtcvad, deferred.

Threading: ``Endpointer.process`` runs inline in the audio callback —
webrtcvad is a fixed-point GMM costing microseconds per frame against the
100 ms block budget. It must never touch the recorder or the pipeline; it
only returns events for the controller to act on from the main thread.
"""

from __future__ import annotations

import logging
import math
from typing import Protocol

log = logging.getLogger(__name__)

SAMPLERATE = 16000
CAP_WARN_FRACTION = 0.9


class FrameSlicer:
    """float32 blocks in → fixed-size little-endian int16 frames out."""

    def __init__(self, frame_samples: int) -> None:
        self._frame_samples = frame_samples
        self._buf = None

    def add(self, block) -> list[bytes]:
        import numpy as np

        i16 = (np.clip(block, -1.0, 1.0) * 32767).astype("<i2")
        buf = i16 if self._buf is None else np.concatenate([self._buf, i16])
        frames = []
        n = self._frame_samples
        while len(buf) >= n:
            frames.append(buf[:n].tobytes())
            buf = buf[n:]
        self._buf = buf if len(buf) else None
        return frames

    def reset(self) -> None:
        self._buf = None


def frame_dbfs(frame: bytes) -> float:
    """RMS level of an int16 frame in dBFS."""
    import numpy as np

    samples = np.frombuffer(frame, dtype="<i2").astype("float64") / 32768.0
    return 10 * math.log10(float((samples**2).mean()) + 1e-12)


class EndpointDetector:
    """Hangover state machine: consecutive voiced frames start speech,
    a continuous silence run ends it. Fires ``endpoint`` once, then stays
    inert until :meth:`reset`. Never fires before speech started — an armed
    session where the user says nothing waits for a manual stop."""

    def __init__(
        self,
        silence_ms: int,
        min_speech_ms: int,
        frame_ms: int,
        energy_gate_dbfs: float,
    ) -> None:
        self._speech_frames = max(1, math.ceil(min_speech_ms / frame_ms))
        self._silence_frames = max(1, math.ceil(silence_ms / frame_ms))
        self._gate = energy_gate_dbfs
        self.reset()

    def reset(self) -> None:
        self._started = False
        self._fired = False
        self._voiced_run = 0
        self._silent_run = 0

    @property
    def silence_fraction(self) -> float:
        """0..1 progress toward auto-stop (the HUD's countdown affordance)."""
        if not self._started:
            return 0.0
        return min(1.0, self._silent_run / self._silence_frames)

    def feed(self, voiced: bool, energy_dbfs: float) -> str | None:
        if self._fired:
            return None
        effective = voiced and energy_dbfs >= self._gate
        if not self._started:
            self._voiced_run = self._voiced_run + 1 if effective else 0
            if self._voiced_run >= self._speech_frames:
                self._started = True
                self._silent_run = 0
                return "speech_start"
            return None
        if effective:
            self._silent_run = 0
            return None
        self._silent_run += 1
        if self._silent_run >= self._silence_frames:
            self._fired = True
            return "endpoint"
        return None


class VadBackend(Protocol):
    frame_samples: int

    def is_voiced(self, frame: bytes) -> bool: ...


class WebrtcBackend:
    """webrtcvad classifier; 30 ms frames at 16 kHz."""

    frame_samples = 480

    def __init__(self, aggressiveness: int = 2, samplerate: int = SAMPLERATE) -> None:
        import webrtcvad

        self._vad = webrtcvad.Vad(aggressiveness)
        self._rate = samplerate

    def is_voiced(self, frame: bytes) -> bool:
        return self._vad.is_speech(frame, self._rate)


class Endpointer:
    """One armed hands-free session: frames in, at most one endpoint out.

    ``arm(generation)`` stamps the session id the controller checks before
    acting on an endpoint (a stale event queued across sessions must never
    stop the next one). Auto-disarms after firing.
    """

    def __init__(
        self,
        backend: VadBackend,
        detector: EndpointDetector,
        max_session_s: float,
        samplerate: int = SAMPLERATE,
    ) -> None:
        self.backend = backend
        self._detector = detector
        self._slicer = FrameSlicer(backend.frame_samples)
        self._cap_samples = int(max_session_s * samplerate)
        self._warn_samples = int(self._cap_samples * CAP_WARN_FRACTION)
        self.armed = False
        self.generation = 0
        self._samples = 0
        self._cap_warned = False

    def arm(self, generation: int) -> None:
        self.generation = generation
        self._detector.reset()
        self._slicer.reset()
        self._samples = 0
        self._cap_warned = False
        self.armed = True

    def disarm(self) -> None:
        self.armed = False

    def process(self, block) -> tuple[str | None, float | None]:
        """Audio-callback thread. Returns ``(event, silence_fraction)``;
        event ∈ {speech_start, endpoint, cap_warning, None}."""
        if not self.armed:
            return (None, None)
        self._samples += len(block)
        event = None
        for frame in self._slicer.add(block):
            e = self._detector.feed(
                self.backend.is_voiced(frame), frame_dbfs(frame)
            )
            if e is not None:
                event = e
        if event != "endpoint" and self._samples >= self._cap_samples:
            log.warning("vad: session cap reached, forcing endpoint")
            event = "endpoint"
        elif event is None and not self._cap_warned and self._samples >= self._warn_samples:
            self._cap_warned = True
            event = "cap_warning"
        if event == "endpoint":
            self.armed = False
        return (event, self._detector.silence_fraction)
